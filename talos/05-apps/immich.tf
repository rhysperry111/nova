################################################################################
# Immich — self-hosted photo/video backup.
#
# What lives here:
#   1. The Postgres database, run under the CloudNativePG operator (installed
#      in stage 03). The Cluster uses the official `standard` CNPG operand
#      image, which bundles pgvector — the only vector extension Immich needs
#      now we're off the VectorChord fork. CNPG gives us managed minor-version
#      rolling upgrades (bump immich_db_image) and declarative major upgrades,
#      which the old hand-rolled StatefulSet never did.
#   2. A pre-created `immich-library` PVC mounted at /usr/src/app/upload via
#      the chart's persistence.data globalMounts. The chart only accepts an
#      existingClaim — it won't create one for you.
#   3. The official immich-app chart (OCI, since the HTTP repo is being
#      retired) with the bundled valkey enabled.
#
# Media restore is manual after first apply — see the rclone-from-R2 pattern
# alongside vaultwarden.tf.
#
# --- StatefulSet -> CNPG migration runbook -----------------------------------
# The legacy StatefulSet (gated by var.immich_legacy_postgres_enabled) and the
# CNPG Cluster coexist during cutover; var.immich_db_use_cnpg selects which one
# Immich talks to. Migrate in order:
#   0. `make platformservices` to install the CNPG operator + CRDs.
#   1. `make apps` with defaults (legacy on, use_cnpg=false). This also sets
#      DB_VECTOR_EXTENSION=pgvector on the legacy DB, so Immich drops the
#      VectorChord indexes and rebuilds pgvector ones ("Reindexing clip_index /
#      face_index" in the logs — embeddings are preserved, no ML recompute).
#      It also creates the empty CNPG Cluster ready to receive data.
#   2. After reindex completes, drop the now-unused extension on the legacy DB:
#        DROP EXTENSION IF EXISTS vchord CASCADE;   (run as the postgres user)
#   3. Scale Immich to 0, then dump legacy -> restore into CNPG:
#        kubectl exec immich-postgres-0 -- pg_dump -U postgres -d immich -Fc \
#          --no-owner --no-acl > immich.dump
#        kubectl exec -i immich-postgres-1 -- pg_restore --no-owner \
#          --role=immich -d immich < immich.dump
#      (extensions are pre-created by postInitApplicationSQL, so the dump's
#      CREATE EXTENSION IF NOT EXISTS lines no-op under the non-superuser
#      restore. If you hit empty-search_path / "type vector does not exist",
#      restore as the superuser from the immich-postgres-superuser secret.)
#   4. Set immich_db_use_cnpg=true, `make apps` — Immich repoints to CNPG.
#   5. Verify, then set immich_legacy_postgres_enabled=false, `make apps` to
#      retire the StatefulSet. Its data PVC survives for cold rollback; delete
#      `data-immich-postgres-0` by hand once you're confident.
################################################################################

resource "kubernetes_namespace_v1" "immich" {
  metadata {
    name = var.immich_namespace
  }
}

# DB connection env handed to immich-server. Selects the legacy StatefulSet or
# the CNPG cluster based on var.immich_db_use_cnpg. DB_VECTOR_EXTENSION is
# pgvector in both branches — we switch the legacy DB off VectorChord before
# the cutover, and CNPG only ever speaks pgvector.
locals {
  immich_db_env = {
    DB_HOSTNAME         = "immich-postgres-rw"
    DB_DATABASE_NAME    = "immich"
    DB_VECTOR_EXTENSION = "pgvector"
    DB_USERNAME = {
      valueFrom = {
        secretKeyRef = {
          name = kubernetes_secret_v1.immich_db_app.metadata[0].name
          key  = "username"
        }
      }
    }
    DB_PASSWORD = {
      valueFrom = {
        secretKeyRef = {
          name = kubernetes_secret_v1.immich_db_app.metadata[0].name
          key  = "password"
        }
      }
    }
  }
}

# CNPG app-user credentials. basic-auth secret consumed both as the Cluster's
# initdb owner secret and by immich-server (DB_USERNAME/DB_PASSWORD) once
# migrated. Reuses the same password var as the legacy DB.
resource "kubernetes_secret_v1" "immich_db_app" {
  metadata {
    name      = "immich-db-app"
    namespace = kubernetes_namespace_v1.immich.metadata[0].name
  }
  data = {
    username = "immich"
    password = var.immich_postgres_password
  }
  type = "kubernetes.io/basic-auth"
}

resource "kubernetes_persistent_volume_claim_v1" "immich_library" {
  metadata {
    name      = "immich-library"
    namespace = kubernetes_namespace_v1.immich.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.immich_library_storage_class
    resources {
      requests = {
        storage = var.immich_library_size
      }
    }
  }
  # Library data is irreplaceable — let the resource leak in TF state rather
  # than have a misplaced destroy nuke the PVC.
  lifecycle {
    prevent_destroy = true
  }
  # PVC immutability after creation: changing storage_class or shrinking the
  # request would force replacement, which would lose data. Ignore drift so a
  # var bump doesn't surprise you.
  # Bumping size up is fine — apply manually with `kubectl edit pvc` and
  # ceph-csi expands the volume in place.
}

################################################################################
# Postgres — CloudNativePG cluster (migration target).
#
# Rendered via the cloudnative-pg/cluster Helm chart so it follows the repo's
# all-helm_release pattern and doesn't trip the kubernetes_manifest "CRD must
# exist at plan time" trap — the operator (stage 03) installs the CRDs before
# this stage runs.
#
# fullnameOverride pins the Cluster + Service names: immich-server connects to
# the immich-postgres-rw Service. Single instance to match the old setup; Ceph
# already replicates the storage. Bump to instances=3 later for HA failover.
#
# pgvector needs no shared_preload_libraries (unlike vchord), so postgresql
# config stays at defaults. Extensions are pre-created in the application DB via
# postInitApplicationSQL (runs as superuser against the `immich` database).
################################################################################

resource "helm_release" "immich_db" {
  name      = "immich-postgres"
  namespace = kubernetes_namespace_v1.immich.metadata[0].name

  repository = "https://cloudnative-pg.github.io/charts"
  chart      = "cluster"
  version    = var.cnpg_cluster_chart_version

  values = [
    yamlencode({
      type             = "postgresql"
      version          = { postgresql = "18" }
      mode             = "standalone"
      fullnameOverride = "immich-postgres"

      cluster = {
        instances = 1
        imageName = var.immich_db_image

        storage = {
          size         = var.immich_postgres_storage_size
          storageClass = var.immich_postgres_storage_class
        }

        # Auto-creates the immich-postgres-superuser secret — needed for the
        # one-off restore and any future CREATE EXTENSION as superuser.
        enableSuperuserAccess = true
        roles = [
          {
            name           = "immich"
            ensure         = "present"
            login          = true
            superuser      = true
            passwordSecret = { name = kubernetes_secret_v1.immich_db_app.metadata[0].name }
          }
        ]

        # A PDB on a single-instance cluster blocks node drains/upgrades; the
        # chart explicitly recommends disabling it for single instances.
        enablePDB = false
        primaryUpdateMethod = "restart"

        resources = {
          requests = {
            memory = "512Mi"
            cpu    = "250m"
          }
          limits = {
            memory = "2Gi"
          }
        }

        monitoring = {
          enabled    = true
          podMonitor = { enabled = true }
        }

        initdb = {
          database = "immich"
          owner    = "immich"
          secret   = { name = kubernetes_secret_v1.immich_db_app.metadata[0].name }
          # Runs against the `immich` database as superuser, so a non-superuser
          # pg_restore can run afterwards (its CREATE EXTENSION IF NOT EXISTS
          # lines no-op against these).
          postInitApplicationSQL = [
            "CREATE EXTENSION IF NOT EXISTS vector;",
            "CREATE EXTENSION IF NOT EXISTS cube;",
            "CREATE EXTENSION IF NOT EXISTS earthdistance;",
            "CREATE EXTENSION IF NOT EXISTS pg_trgm;",
            "CREATE EXTENSION IF NOT EXISTS unaccent;",
            "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";",
          ]
        }
      }
    }),
  ]
}

################################################################################
# Helm release
################################################################################

resource "helm_release" "immich" {
  depends_on = [
    helm_release.immich_db,
    kubernetes_persistent_volume_claim_v1.immich_library,
  ]

  name       = "immich"
  namespace  = kubernetes_namespace_v1.immich.metadata[0].name
  repository = "https://immich-app.github.io/immich-charts"
  chart      = "immich"
  version    = var.immich_chart_version

  values = compact([
    yamlencode(merge(
      {
        # Bundled valkey (Redis-compatible) — chart defaults are fine.
        valkey = {
          enabled = true
        }

        immich = {
          #metrics = {
          #  enabled = true
          #}
          persistence = {
            library = {
              existingClaim = kubernetes_persistent_volume_claim_v1.immich_library.metadata[0].name
            }
          }
        }

        # Server-specific values: DB connection + ingress + library mount path.
        server = {
          # The chart's hardcodedValues set persistence.data.enabled=true and
          # existingClaim from immich.persistence.library, but does NOT set
          # globalMounts. Without this the PVC is created but never mounted
          # into the container.
          persistence = {
            data = {
              globalMounts = [{
                path = "/usr/src/app/upload"
              }]
            }
          }

          controllers = {
            main = {
              containers = {
                main = {
                  env = local.immich_db_env
                }
              }
            }
          }

          ingress = {
            main = {
              enabled = true
              annotations = {
                "cert-manager.io/cluster-issuer" = var.cluster_issuer_name
                # Without this, the nginx-ingress-style annotation defaulted
                # by the chart is meaningless on Cilium AND Cilium's ingress
                # will reject uploads larger than its default body limit.
                # Cilium honours `ingress.cilium.io/request-body-size` for
                # this; tuning to 0 disables the limit.
                "ingress.cilium.io/request-body-size" = "0"
                "ingress.cilium.io/request-timeout"   = "600s"
              }
              className = var.ingress_class_name
              hosts = [{
                host = "pics.${var.ingress_domain}"
                paths = [{
                  path = "/"
                  service = {
                    identifier = "main"
                    port       = "http"
                  }
                }]
              }]
              tls = [{
                secretName = "immich-tls"
                hosts      = ["pics.${var.ingress_domain}"]
              }]
            }
          }
        }
        
        controllers = {
          main = {
            containers = {
              main = {
                image = { tag = var.immich_image_tag }
              }
            }
          }
        }

        machine-learning = {
          controllers = {
            main = {
              containers = {
                main = {
                  resources = {
                    limits = {
                      memory = "6Gi"
                      cpu    = "2000m"
                    }
                  }
                }
              }
            }
          }
        }
      }
    )),
    var.immich_values_override,
  ])
}
