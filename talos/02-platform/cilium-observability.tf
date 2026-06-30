################################################################################
# Cilium Observability
################################################################################

resource "kubectl_manifest" "inspect_dns" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2"
    kind       = "CiliumClusterwideNetworkPolicy"
    metadata   = { name = "inspect-dns" }
    spec = {
      endpointSelector = {}
      egress = [{
        toEndpoints = [{
          matchLabels = {
            "io.kubernetes.pod.namespace" = "kube-system"
            "k8s-app"                     = "kube-dns"
          }
        }]
        toPorts = [{
          ports = [{ port = "53", protocol = "UDP" }]
          rules = { dns = [{ matchPattern = "*" }] }
        }]
      }]
    }
  })
}

resource "kubectl_manifest" "allow_all_egress" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2"
    kind       = "CiliumClusterwideNetworkPolicy"
    metadata   = { name = "allow-all-egress" }
    spec = {
      endpointSelector = {}
      egress = [
        { toEntities = ["cluster"] },
        { toEntities = ["world"] },
      ]
    }
  })
}
