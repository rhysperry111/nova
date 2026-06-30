################################################################################
# Vaultwarden — Bitwarden-compatible password manager.
#
# Deployed via the community guerzon/vaultwarden Helm chart. SQLite backend
# (the chart's default), single PVC at /data holding:
#   - db.sqlite3 (+ -wal / -shm journal files)
#   - rsa_key.* — RSA keypair used for client token signing. Losing these
#     forces every client to re-login.
#   - attachments/, sends/, icon_cache/, config.json
#
# `storage.data.keepPvc = true` so `helm uninstall` (and a destroy of the
# kubectl_manifest in error) leaves the PVC intact. Pair that with the
# Delete reclaim policy on ceph-block by NOT relying on chart deletion to
# clean up — destroy the PVC manually if you mean it.
#
# Admin panel: enabled only when var.vaultwarden_admin_token is non-empty.
# Generate the argon2id hash via the upstream CLI:
#   docker run --rm vaultwarden/server /vaultwarden hash
################################################################################

resource "kubernetes_namespace_v1" "vaultwarden" {
  metadata {
    name = var.vaultwarden_namespace
  }
}

resource "helm_release" "vaultwarden" {
  name       = "vaultwarden"
  namespace  = kubernetes_namespace_v1.vaultwarden.metadata[0].name
  repository = "https://guerzon.github.io/vaultwarden"
  chart      = "vaultwarden"
  version    = var.vaultwarden_chart_version

  values = compact([
    yamlencode({
      image = {
        tag = var.vaultwarden_image_tag
      }

      # `domain` MUST be the externally reachable URL — Vaultwarden uses it
      # to build invite links, WebAuthn challenges, and the websocket URL.
      # Mismatched scheme/host breaks logins.
      domain = "https://vault.${var.ingress_domain}"

      signupsAllowed     = var.vaultwarden_signups_allowed
      invitationsAllowed = true

      database = {
        type = "default"
      }

      storage = {
        data = {
          name        = "vaultwarden-data"
          size        = var.vaultwarden_disk_size
          class       = var.vaultwarden_storage_class
          path        = "/data"
          accessMode  = "ReadWriteOnce"
          keepPvc     = true
        }
      }

      adminToken = var.vaultwarden_admin_token != "" ? {
        value = var.vaultwarden_admin_token
      } : {}

      ingress = {
        enabled                = true
        class                  = var.ingress_class_name
        hostname               = "vault.${var.ingress_domain}"
        # Chart defaults add nginx-ingress-specific annotations; we run on
        # Cilium, so suppress those and supply the cert-manager annotation
        # ourselves.
        nginxIngressAnnotations = false
        additionalAnnotations = {
          "cert-manager.io/cluster-issuer" = var.cluster_issuer_name
        }
        tls       = true
        tlsSecret = "vaultwarden-tls"
        path      = "/"
        pathType  = "Prefix"
      }
    }),
    var.vaultwarden_values_override,
  ])
}
