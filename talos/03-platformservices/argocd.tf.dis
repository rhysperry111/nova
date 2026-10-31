################################################################################
# ArgoCD — GitOps controller.
#
# HA topology when var.argocd_ha is true: 3 redis-ha replicas, 2 repo-server
# replicas, 2 application-controller shards, 2 server replicas. Off by
# default for dev clusters via the variable.
#
# No Ingress/Route is created here — that's expected to come from a
# downstream ArgoCD Application once the controller is up, so we don't have
# to know about cert-manager ClusterIssuer / external-dns hostname wiring at
# bootstrap time.
################################################################################

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "helm_release" "argocd" {
  depends_on = [kubernetes_namespace_v1.argocd]

  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_version
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name

  values = compact([
    yamlencode({
      # `global.domain` is the single source of truth for argocd-server's
      # external hostname — server URL, redirect URIs, and the default
      # ingress hostname all derive from it.
      global = {
        domain = "argocd.${var.ingress_domain}"
        networkPolicy = {
          create = false
        }
      }

      # argocd-server serves both UI and gRPC on a single port. When TLS is
      # terminated at the ingress we want the upstream to be plain HTTP, so
      # turn off the server's own TLS. Without this you get a 308 redirect
      # loop between argocd-server and the ingress.
      configs = {
        params = {
          "server.insecure" = true
        }
      }

      "redis-ha" = {
        enabled = var.argocd_ha
      }

      controller = {
        replicas = var.argocd_ha ? 2 : 1
      }

      server = {
        replicas = var.argocd_ha ? 2 : 1

        ingress = {
          enabled          = true
          ingressClassName = var.ingress_class_name
          annotations = {
            "cert-manager.io/cluster-issuer" = var.cluster_issuer_name
          }
          # `tls: true` makes the chart auto-render a tls block from
          # global.domain with secretName `<domain>-tls`. cert-manager will
          # populate that secret once the ClusterIssuer's DNS-01 challenge
          # succeeds.
          tls = true
        }
      }

      repoServer = {
        replicas = var.argocd_ha ? 2 : 1
      }

      applicationSet = {
        replicas = var.argocd_ha ? 2 : 1
      }
    }),
    var.argocd_values_override,
  ])
}
