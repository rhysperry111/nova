################################################################################
# external-dns — keeps Cloudflare DNS in sync with Service/Ingress objects.
#
# Watches the cluster for resources annotated with
# `external-dns.alpha.kubernetes.io/hostname` (and Ingress hosts) and
# creates/updates/deletes matching records in Cloudflare. A TXT registry
# record is written alongside each managed record so external-dns can tell
# the records it owns from records you (or another tool) made by hand —
# `txtOwnerId` is the key.
#
# Token lives in a Secret in the external-dns namespace; the chart wires
# `CF_API_TOKEN` from that secret into the controller pod.
################################################################################

resource "kubernetes_namespace_v1" "external_dns" {
  metadata {
    name = "external-dns"
  }
}

resource "kubernetes_secret_v1" "unifi_api_token_external_dns" {
  metadata {
    name      = "unifi-api-token"
    namespace = kubernetes_namespace_v1.external_dns.metadata[0].name
  }

  data = {
    "UNIFI_API_KEY" = var.unifi_api_key
  }

  type = "Opaque"
}

resource "helm_release" "external_dns" {
  depends_on = [kubernetes_secret_v1.unifi_api_token_external_dns]

  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = var.external_dns_version
  namespace  = kubernetes_namespace_v1.external_dns.metadata[0].name

  values = compact([
    yamlencode({
      provider = {
        name = "webhook"
        webhook = {
          image = {
            repository = "ghcr.io/home-operations/external-dns-unifi-webhook"
            tag = var.external_dns_unifi_webhook_version
          }
          env = [
            {
              name = "UNIFI_HOST"
              value = var.unifi_api_url
            },
            {
              name = "UNIFI_API_KEY"
              valueFrom = {
                secretKeyRef = {
                  name = kubernetes_secret_v1.unifi_api_token_external_dns.metadata[0].name
                  key  = "UNIFI_API_KEY"
                }
              }
            }
          ]
          livenessProbe = {
            httpGet = {
              path = "/healthz"
              port = "http-webhook"
            }
            initialDelaySeconds = 10
            timeoutSeconds = 5
          }
          readinessProbe = {
            httpGet = {
              path = "/readyz"
              port = "http-webhook"
            }
            initialDelaySeconds = 10
            timeoutSeconds = 5
          }
        }
      }

      domainFilters = var.external_dns_domain_filters
      policy        = var.external_dns_policy

      registry   = "txt"
      txtOwnerId = var.external_dns_txt_owner_id

      sources = ["service", "ingress"]
    }),
    var.external_dns_values_override,
  ])
}
