################################################################################
# LibreSpeed — browser-based speedtest at speed.<ingress_domain>.
#
# Throwaway diagnostic tool for measuring upload/download/ping/jitter through
# the Ingress + Cilium + upstream path. Standalone mode (no DB), single
# replica, no persistence. Swap the ingress annotations / class here to
# A/B-test networking tweaks without touching anything else.
################################################################################

resource "kubernetes_namespace_v1" "librespeed" {
  metadata {
    name = "librespeed"
  }
}

resource "kubernetes_deployment_v1" "librespeed" {
  metadata {
    name      = "librespeed"
    namespace = kubernetes_namespace_v1.librespeed.metadata[0].name
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "librespeed"
      }
    }
    template {
      metadata {
        labels = {
          app = "librespeed"
        }
      }
      spec {
        container {
          name  = "librespeed"
          image = "ghcr.io/librespeed/speedtest:6.1.0"
          port {
            container_port = 8080
            name           = "http"
          }
          env {
            name  = "MODE"
            value = "standalone"
          }
          env {
            name  = "TITLE"
            value = "Nova speedtest"
          }
          # Tell the JS client to trust the upstream IP — without this, the
          # "Your IP" display shows the cluster-internal Envoy IP instead of
          # the real client. Cosmetic; doesn't affect the actual measurement.
          env {
            name  = "IPINFO_APIKEY"
            value = ""
          }
          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
          readiness_probe {
            http_get {
              path = "/"
              port = "http"
            }
            initial_delay_seconds = 3
            period_seconds        = 10
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "librespeed" {
  metadata {
    name      = "librespeed"
    namespace = kubernetes_namespace_v1.librespeed.metadata[0].name
  }
  spec {
    selector = {
      app = "librespeed"
    }
    port {
      name        = "http"
      port        = 80
      target_port = "http"
    }
  }
}

resource "kubernetes_ingress_v1" "librespeed" {
  metadata {
    name      = "librespeed"
    namespace = kubernetes_namespace_v1.librespeed.metadata[0].name
    annotations = {
      "cert-manager.io/cluster-issuer" = var.cluster_issuer_name
      # Generous timeout so the longer "Multi-Connection" runs don't get
      # killed by the default 15s Envoy listener timeout.
      "ingress.cilium.io/request-timeout" = "600s"
    }
  }

  spec {
    ingress_class_name = var.ingress_class_name

    tls {
      hosts       = ["speed.${var.ingress_domain}"]
      secret_name = "librespeed-tls"
    }

    rule {
      host = "speed.${var.ingress_domain}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.librespeed.metadata[0].name
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
