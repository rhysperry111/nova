################################################################################
# your_spotify — self-hosted Spotify listening stats (Yooooomi/your_spotify).
#
# Three raw resources, modelled on jellyfin.tf rather than a Helm chart (there
# is no maintained upstream chart):
#   1. Mongo — the datastore. Single pod, RWO PVC at /data/db. The listening
#      history is only partially re-syncable from Spotify (the API replays just
#      the last ~50 plays), so the PVC is prevent_destroy.
#   2. server — the yooooomi/your_spotify_server API (:8080). Talks to Mongo and
#      handles the Spotify OAuth dance.
#   3. web — the yooooomi/your_spotify_client static frontend (:3000). It calls
#      the API directly from the browser, so it needs the API's public URL.
#
# Two hostnames because the yooooomi images don't serve the API under a
# sub-path, and Cilium's Ingress can't rewrite/strip one:
#   - web  -> spotify.<ingress_domain>
#   - API  -> api-spotify.<ingress_domain>
#
# One-time Spotify setup: create an app at https://developer.spotify.com, put
# its Client ID/Secret in secrets.auto.tfvars (your_spotify_public /
# your_spotify_secret), and add this Redirect URI to the app:
#   https://api-spotify.<ingress_domain>/oauth/spotify/callback
################################################################################

resource "kubernetes_namespace_v1" "your_spotify" {
  metadata {
    name = var.your_spotify_namespace
  }
}

locals {
  your_spotify_api_host    = "api-spotify.${var.ingress_domain}"
  your_spotify_client_host = "spotify.${var.ingress_domain}"
  # In-cluster Mongo connection string. Service name below must match.
  your_spotify_mongo_endpoint = "mongodb://your-spotify-mongo:27017/your_spotify"
}

# Spotify OAuth app credentials. SPOTIFY_PUBLIC (Client ID) isn't strictly
# secret, but it's paired with the secret here so both come from one place.
resource "kubernetes_secret_v1" "your_spotify_spotify" {
  metadata {
    name      = "your-spotify-spotify"
    namespace = kubernetes_namespace_v1.your_spotify.metadata[0].name
  }
  data = {
    SPOTIFY_PUBLIC = var.your_spotify_public
    SPOTIFY_SECRET = var.your_spotify_secret
  }
}

################################################################################
# Mongo
################################################################################

resource "kubernetes_persistent_volume_claim_v1" "your_spotify_mongo" {
  metadata {
    name      = "your-spotify-mongo"
    namespace = kubernetes_namespace_v1.your_spotify.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.your_spotify_mongo_storage_class
    resources {
      requests = {
        storage = var.your_spotify_mongo_size
      }
    }
  }
  # History is only partially re-syncable from Spotify — let the resource leak
  # in TF state rather than have a misplaced destroy nuke it. Grow in place by
  # bumping the size var + `kubectl edit pvc` (ceph-csi expands online).
  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_deployment_v1" "your_spotify_mongo" {
  metadata {
    name      = "your-spotify-mongo"
    namespace = kubernetes_namespace_v1.your_spotify.metadata[0].name
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "your-spotify-mongo"
      }
    }
    # RWO volume — a rolling update can't mount the PVC twice, so it would hang
    # waiting for the old pod to detach. Recreate tears the old pod down first.
    strategy {
      type = "Recreate"
    }
    template {
      metadata {
        labels = {
          app = "your-spotify-mongo"
        }
      }
      spec {
        container {
          name  = "mongo"
          image = var.your_spotify_mongo_image
          port {
            container_port = 27017
            name           = "mongo"
          }
          volume_mount {
            name       = "data"
            mount_path = "/data/db"
          }
          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              memory = "2Gi"
            }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.your_spotify_mongo.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "your_spotify_mongo" {
  metadata {
    name      = "your-spotify-mongo"
    namespace = kubernetes_namespace_v1.your_spotify.metadata[0].name
  }
  spec {
    selector = {
      app = "your-spotify-mongo"
    }
    port {
      name        = "mongo"
      port        = 27017
      target_port = "mongo"
    }
  }
}

################################################################################
# Server (API)
################################################################################

resource "kubernetes_deployment_v1" "your_spotify_server" {
  metadata {
    name      = "your-spotify-server"
    namespace = kubernetes_namespace_v1.your_spotify.metadata[0].name
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "your-spotify-server"
      }
    }
    template {
      metadata {
        labels = {
          app = "your-spotify-server"
        }
      }
      spec {
        container {
          name  = "server"
          image = "yooooomi/your_spotify_server:${var.your_spotify_image_tag}"
          port {
            container_port = 8080
            name           = "http"
          }

          # API_ENDPOINT MUST be the externally reachable API URL — the server
          # builds the Spotify OAuth redirect URI from it, and the browser is
          # sent there. CLIENT_ENDPOINT is used for post-login redirects + CORS.
          env {
            name  = "API_ENDPOINT"
            value = "https://${local.your_spotify_api_host}"
          }
          env {
            name  = "CLIENT_ENDPOINT"
            value = "https://${local.your_spotify_client_host}"
          }
          env {
            name  = "MONGO_ENDPOINT"
            value = local.your_spotify_mongo_endpoint
          }
          env {
            name  = "TIMEZONE"
            value = var.your_spotify_timezone
          }
          env {
            name = "SPOTIFY_PUBLIC"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.your_spotify_spotify.metadata[0].name
                key  = "SPOTIFY_PUBLIC"
              }
            }
          }
          env {
            name = "SPOTIFY_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.your_spotify_spotify.metadata[0].name
                key  = "SPOTIFY_SECRET"
              }
            }
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              memory = "1Gi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "your_spotify_server" {
  metadata {
    name      = "your-spotify-server"
    namespace = kubernetes_namespace_v1.your_spotify.metadata[0].name
  }
  spec {
    selector = {
      app = "your-spotify-server"
    }
    port {
      name        = "http"
      port        = 80
      target_port = "http"
    }
  }
}

resource "kubernetes_ingress_v1" "your_spotify_server" {
  metadata {
    name      = "your-spotify-server"
    namespace = kubernetes_namespace_v1.your_spotify.metadata[0].name
    annotations = {
      "cert-manager.io/cluster-issuer" = var.cluster_issuer_name
    }
  }

  spec {
    ingress_class_name = var.ingress_class_name

    tls {
      hosts       = [local.your_spotify_api_host]
      secret_name = "your-spotify-server-tls"
    }

    rule {
      host = local.your_spotify_api_host
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.your_spotify_server.metadata[0].name
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

################################################################################
# Web client
################################################################################

resource "kubernetes_deployment_v1" "your_spotify_web" {
  metadata {
    name      = "your-spotify-web"
    namespace = kubernetes_namespace_v1.your_spotify.metadata[0].name
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "your-spotify-web"
      }
    }
    template {
      metadata {
        labels = {
          app = "your-spotify-web"
        }
      }
      spec {
        container {
          name  = "web"
          image = "yooooomi/your_spotify_client:${var.your_spotify_image_tag}"
          port {
            container_port = 3000
            name           = "http"
          }
          # The frontend calls the API from the browser, so this must be the
          # public API URL, not the in-cluster Service name.
          env {
            name  = "API_ENDPOINT"
            value = "https://${local.your_spotify_api_host}"
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
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "your_spotify_web" {
  metadata {
    name      = "your-spotify-web"
    namespace = kubernetes_namespace_v1.your_spotify.metadata[0].name
  }
  spec {
    selector = {
      app = "your-spotify-web"
    }
    port {
      name        = "http"
      port        = 80
      target_port = "http"
    }
  }
}

resource "kubernetes_ingress_v1" "your_spotify_web" {
  metadata {
    name      = "your-spotify-web"
    namespace = kubernetes_namespace_v1.your_spotify.metadata[0].name
    annotations = {
      "cert-manager.io/cluster-issuer" = var.cluster_issuer_name
    }
  }

  spec {
    ingress_class_name = var.ingress_class_name

    tls {
      hosts       = [local.your_spotify_client_host]
      secret_name = "your-spotify-web-tls"
    }

    rule {
      host = local.your_spotify_client_host
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.your_spotify_web.metadata[0].name
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
