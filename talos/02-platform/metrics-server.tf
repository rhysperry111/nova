################################################################################
# metrics-server — provides resource metrics for kubectl top, HPA, VPA, etc.
#
# Runs as a normal pod on the cluster network — Cilium kubeProxyReplacement
# handles routing from the pod CIDR to each node's :10250 just fine, no
# hostNetwork trick required.
#
# --kubelet-insecure-tls skips verification of the kubelet serving cert.
# Talos auto-approves kubelet serving CSRs against the cluster CA, so
# verification *can* work, but wiring metrics-server's --kubelet-certificate-
# authority to the right CA bundle is fiddly across chart versions. For a
# homelab, skipping verification is the standard pattern.
################################################################################

resource "helm_release" "metrics_server" {
  depends_on = [helm_release.cilium]

  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.metrics_server_version
  namespace  = "kube-system"

  values = compact([
    yamlencode({
      args = [
        "--kubelet-insecure-tls",
        "--kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP",
        "--metric-resolution=15s",
      ]

      replicas = 2

      # Anti-affinity so the two replicas don't both land on the same node.
      affinity = {
        podAntiAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = [{
            labelSelector = {
              matchLabels = {
                "app.kubernetes.io/name"     = "metrics-server"
                "app.kubernetes.io/instance" = "metrics-server"
              }
            }
            topologyKey = "kubernetes.io/hostname"
          }]
        }
      }
    }),
    var.metrics_server_values_override,
  ])
}
