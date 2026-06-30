################################################################################
# Registry — CNCF Distribution, the reference OCI/Docker image registry.
#
# This is about as minimal as a registry gets: a single `registry` container
# backed by one PVC (filesystem storage driver, default /var/lib/registry).
# No Postgres, no object store, no auth front-end — just blob storage on Ceph.
# Distribution is the same codebase Docker Hub / GHCR / Harbor build on, so
# `docker`/`podman`/`nerdctl`/`crane` all talk to it without ceremony.
#
# Two ways in:
#   - Cluster-internal:  registry.<namespace>.svc.cluster.local:5000
#                        (use this as the pull/push target from in-cluster
#                        workloads and image builders — no TLS round-trip)
#   - External:          https://registry.<ingress_domain>
#                        (Cilium Ingress terminates TLS; cert-manager mints the
#                        cert and external-dns publishes the record)
#
# No authentication: the Nova network is internal-only (same assumption the
# cert-manager DNS-01 setup leans on), so the registry trusts anyone who can
# reach it. Add htpasswd / token auth here if that assumption ever changes.
################################################################################

resource "kubernetes_namespace_v1" "registry" {
  metadata {
    name = var.registry_namespace
  }
}

resource "kubernetes_persistent_volume_claim_v1" "registry" {
  metadata {
    name      = "registry-data"
    namespace = kubernetes_namespace_v1.registry.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.registry_storage_class
    resources {
      requests = {
        storage = var.registry_storage_size
      }
    }
  }
  # The blobs here may be the only copy of an image — don't let a stray destroy
  # take them out. Bump size up with `kubectl edit pvc` (ceph-csi expands in
  # place); shrinking or changing class would force a data-losing replace.
  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_deployment_v1" "registry" {
  metadata {
    name      = "registry"
    namespace = kubernetes_namespace_v1.registry.metadata[0].name
  }

  spec {
    # Single replica: the filesystem driver on a ReadWriteOnce PVC can't be
    # shared across pods. Scaling out needs a shared object-store backend.
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "registry"
      }
    }
    template {
      metadata {
        labels = {
          app = "registry"
        }
      }
      spec {
        container {
          name  = "registry"
          image = "registry:${var.registry_image_tag}"
          port {
            container_port = 5000
            name           = "http"
          }
          # Leave REGISTRY_HTTP_HOST unset so Distribution builds blob-upload
          # redirect URLs from the incoming Host / X-Forwarded-* headers. That
          # keeps both the internal service name and the external hostname
          # working against the same pod.
          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/registry"
          }
          readiness_probe {
            http_get {
              path = "/v2/"
              port = "http"
            }
            initial_delay_seconds = 3
            period_seconds        = 10
          }
          liveness_probe {
            http_get {
              path = "/v2/"
              port = "http"
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.registry.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "registry" {
  metadata {
    name      = "registry"
    namespace = kubernetes_namespace_v1.registry.metadata[0].name
  }
  spec {
    selector = {
      app = "registry"
    }
    # Cluster-internal endpoint: registry.<namespace>.svc.cluster.local:5000
    port {
      name        = "http"
      port        = 5000
      target_port = "http"
    }
  }
}

resource "kubernetes_ingress_v1" "registry" {
  metadata {
    name      = "registry"
    namespace = kubernetes_namespace_v1.registry.metadata[0].name
    annotations = {
      "cert-manager.io/cluster-issuer" = var.cluster_issuer_name
      # Image layers can be large and slow to push; give uploads plenty of
      # headroom past Envoy's default 15s listener timeout.
      "ingress.cilium.io/request-timeout" = "600s"
    }
  }

  spec {
    ingress_class_name = var.ingress_class_name

    tls {
      hosts       = ["registry.${var.ingress_domain}"]
      secret_name = "registry-tls"
    }

    rule {
      host = "registry.${var.ingress_domain}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.registry.metadata[0].name
              port {
                number = 5000
              }
            }
          }
        }
      }
    }
  }
}
