################################################################################
# Jellyfin — self-hosted media server at watch.<ingress_domain>.
#
# Single container (no DB — Jellyfin keeps everything in its /config SQLite +
# metadata tree), modelled on librespeed.tf's raw-resource style rather than a
# Helm chart. Two PVCs:
#   1. jellyfin-config (/config) — server settings, user accounts, watch
#      history, and the scraped metadata/artwork cache. Regenerable in theory
#      (re-scan, re-add users) but annoying to lose, so prevent_destroy.
#   2. jellyfin-media (/media) — the actual library. Irreplaceable; the big
#      RWO volume you drop old media into. prevent_destroy.
#
# Both PVCs are ReadWriteOnce on ceph-block, so only one pod can mount the
# media volume at a time. Two consequences baked in below:
#   - strategy = Recreate. A RollingUpdate would deadlock: the new pod can't
#     mount the RWO volume until the old pod releases it.
#   - The media-import workflow is "scale to 0, mount from a throwaway pod,
#     scale back up" (see below) — you can't attach the importer while
#     Jellyfin holds the volume.
#
# ── Importing old media ──────────────────────────────────────────────────────
# 1. Free the media volume:
#      set jellyfin_replicas = 0 (tfvars) && terraform apply
#    or, ad hoc: kubectl -n jellyfin scale deploy/jellyfin --replicas=0
# 2. Spin up an importer pod that mounts the same PVC. For a bulk pull from
#    R2 use the resilient rclone manifest alongside this file:
#      kubectl apply -f jellyfin-media-import.yaml   # fill in the Secret first
#    For a quick one-off from your laptop instead:
#      kubectl -n jellyfin run media-import --restart=Never --image=rclone/rclone:latest \
#        --overrides='{"spec":{"containers":[{"name":"media-import","image":"rclone/rclone:latest",
#          "command":["sleep","infinity"],"volumeMounts":[{"name":"media","mountPath":"/media"}]}],
#          "volumes":[{"name":"media","persistentVolumeClaim":{"claimName":"jellyfin-media"}}]}}'
#      kubectl cp ./local-media jellyfin/media-import:/media/
# 3. Tidy up and bring Jellyfin back:
#      kubectl -n jellyfin delete pod media-import
#      set jellyfin_replicas = 1 (or scale back up) && terraform apply
# 4. In the Jellyfin UI: Dashboard → Libraries → Scan All Libraries.
################################################################################

resource "kubernetes_namespace_v1" "jellyfin" {
  metadata {
    name = var.jellyfin_namespace
  }
}

resource "kubernetes_persistent_volume_claim_v1" "jellyfin_config" {
  metadata {
    name      = "jellyfin-config"
    namespace = kubernetes_namespace_v1.jellyfin.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.jellyfin_config_storage_class
    resources {
      requests = {
        storage = var.jellyfin_config_size
      }
    }
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_persistent_volume_claim_v1" "jellyfin_media" {
  metadata {
    name      = "jellyfin-media"
    namespace = kubernetes_namespace_v1.jellyfin.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.jellyfin_media_storage_class
    resources {
      requests = {
        storage = var.jellyfin_media_size
      }
    }
  }
  # The library is irreplaceable — let the resource leak in TF state rather
  # than have a misplaced destroy nuke it. Growing it is fine: bump
  # jellyfin_media_size, `kubectl edit pvc`, and ceph-csi expands in place.
  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_deployment_v1" "jellyfin" {
  metadata {
    name      = "jellyfin"
    namespace = kubernetes_namespace_v1.jellyfin.metadata[0].name
  }

  spec {
    replicas = var.jellyfin_replicas

    selector {
      match_labels = {
        app = "jellyfin"
      }
    }

    # RWO volume — a rolling update can't mount the PVC twice, so it would
    # hang waiting for the old pod to detach. Recreate tears the old pod down
    # first.
    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = {
          app = "jellyfin"
        }
      }
      spec {
        container {
          name  = "jellyfin"
          image = var.jellyfin_image

          port {
            container_port = 8096
            name           = "http"
          }

          # Jellyfin builds absolute URLs (e.g. for the web client and
          # DLNA) from the request, but pinning the published base URL keeps
          # generated links correct behind the ingress TLS terminator.
          env {
            name  = "JELLYFIN_PublishedServerUrl"
            value = "https://jelly.${var.ingress_domain}"
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "media"
            mount_path = "/media"
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "512Mi"
            }
            # No CPU limit — let software transcodes burst across cores.
            limits = {
              memory = "4Gi"
            }
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }
        }

        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.jellyfin_config.metadata[0].name
          }
        }
        volume {
          name = "media"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.jellyfin_media.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "jellyfin" {
  metadata {
    name      = "jellyfin"
    namespace = kubernetes_namespace_v1.jellyfin.metadata[0].name
  }
  spec {
    selector = {
      app = "jellyfin"
    }
    port {
      name        = "http"
      port        = 80
      target_port = "http"
    }
  }
}

resource "kubernetes_ingress_v1" "jellyfin" {
  metadata {
    name      = "jellyfin"
    namespace = kubernetes_namespace_v1.jellyfin.metadata[0].name
    annotations = {
      "cert-manager.io/cluster-issuer" = var.cluster_issuer_name
      # Generous timeout so long-lived streaming connections aren't cut by
      # Envoy's default 15s listener timeout. Uploads (e.g. subtitle files)
      # are small, so no body-size override needed.
      "ingress.cilium.io/request-timeout" = "600s"
    }
  }

  spec {
    ingress_class_name = var.ingress_class_name

    tls {
      hosts       = ["jelly.${var.ingress_domain}"]
      secret_name = "jellyfin-tls"
    }

    rule {
      host = "jelly.${var.ingress_domain}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.jellyfin.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}
