################################################################################
# cert-manager — issues and renews TLS certs via ACME.
#
# We run a single ClusterIssuer backed by Let's Encrypt and the DNS-01
# challenge against Cloudflare. DNS-01 is the only path that supports wildcard
# certs, and it doesn't require the cluster to be reachable from the public
# internet — which matters here because the Nova network is internal-only.
#
# The chart's `installCRDs: true` ships cert-manager's CRDs alongside the
# operator. The ClusterIssuer is applied after the release so the CRD exists
# when the kubectl_manifest is rendered.
################################################################################

resource "kubernetes_namespace_v1" "cert_manager" {
  metadata {
    name = "cert-manager"
  }
}

resource "kubernetes_secret_v1" "cloudflare_api_token_cert_manager" {
  metadata {
    name      = "cloudflare-api-token"
    namespace = kubernetes_namespace_v1.cert_manager.metadata[0].name
  }

  data = {
    "api-token" = var.cloudflare_api_token
  }

  type = "Opaque"
}

resource "helm_release" "cert_manager" {
  depends_on = [kubernetes_namespace_v1.cert_manager]

  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = var.cert_manager_version
  namespace  = kubernetes_namespace_v1.cert_manager.metadata[0].name

  values = compact([
    yamlencode({
      # `keep: true` leaves CRDs (and the Certificate/Issuer/etc. resources
      # backed by them) in place if the release is ever uninstalled.
      crds = {
        enabled = true
        keep    = true
      }

      replicaCount = 2

      prometheus = {
        enabled = true
        servicemonitor = {
          enabled = true
        }
      }

      # Anti-affinity so the two controller replicas don't both land on the
      # same node — same reasoning as metrics-server.
      affinity = {
        podAntiAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = [{
            labelSelector = {
              matchLabels = {
                "app.kubernetes.io/name"     = "cert-manager"
                "app.kubernetes.io/instance" = "cert-manager"
              }
            }
            topologyKey = "kubernetes.io/hostname"
          }]
        }
      }
    }),
    var.cert_manager_values_override,
  ])
}

resource "kubectl_manifest" "cluster_issuer" {
  depends_on = [
    helm_release.cert_manager,
    kubernetes_secret_v1.cloudflare_api_token_cert_manager,
  ]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = var.cluster_issuer_name
    }
    spec = {
      acme = {
        server  = var.acme_server
        email   = var.acme_email
        profile = var.acme_profile
        privateKeySecretRef = {
          name = "${var.cluster_issuer_name}-account-key"
        }
        solvers = [{
          dns01 = {
            cloudflare = {
              apiTokenSecretRef = {
                name = kubernetes_secret_v1.cloudflare_api_token_cert_manager.metadata[0].name
                key  = "api-token"
              }
            }
          }
        }]
      }
    }
  })

  server_side_apply = true
}
