################################################################################
# KubeVirt — virtualization on Kubernetes.
#
# KubeVirt doesn't ship as a Helm chart; the upstream release is two YAML
# bundles per version:
#   - kubevirt-operator.yaml  — Namespace, CRDs, operator Deployment, RBAC
#   - kubevirt-cr.yaml        — the KubeVirt CR that tells the operator to
#                               actually create virt-{api,controller,handler}
#
# Both are fetched at plan time over HTTPS, split into individual documents,
# and applied with server-side apply so the operator's own field manager can
# keep ownership of the bits it later mutates (image tags, status, etc.).
#
# Cilium has to be up before any of this — the operator pod won't network
# otherwise — hence the depends_on on the Cilium release.
################################################################################

data "http" "kubevirt_operator" {
  url = "https://github.com/kubevirt/kubevirt/releases/download/${var.kubevirt_version}/kubevirt-operator.yaml"
}

data "kubectl_file_documents" "kubevirt_operator" {
  content = data.http.kubevirt_operator.response_body
}

resource "kubectl_manifest" "kubevirt_operator" {
  depends_on = [helm_release.cilium]

  for_each = data.kubectl_file_documents.kubevirt_operator.manifests

  yaml_body         = each.value
  server_side_apply = true
  wait              = true
}

# The CR lives in the `kubevirt` namespace that the operator bundle creates.
# It's a single document, so build it inline rather than pulling kubevirt-cr.yaml
# — that keeps the feature gates / workload-update strategy / overrides as
# first-class Terraform inputs.
resource "kubectl_manifest" "kubevirt_cr" {
  depends_on = [kubectl_manifest.kubevirt_operator]

  yaml_body = yamlencode({
    apiVersion = "kubevirt.io/v1"
    kind       = "KubeVirt"
    metadata = {
      name      = "kubevirt"
      namespace = "kubevirt"
    }
    spec = {
      monitorAccount = "kube-prometheus-stack-prometheus"
      monitorNamespace = "monitoring"
      serviceMonitorNamespace = "kubevirt"
      certificateRotateStrategy = {}
      configuration = {
        developerConfiguration = {
          # `HostDevices` is required for USB passthrough; auto-add it when
          # any USB devices are declared so the operator's allowlist below
          # actually takes effect.
          featureGates = concat(
            var.kubevirt_feature_gates,
            ["HostDevices"],
          )
        }
        permittedHostDevices = {
          usb = [for d in var.kubevirt_permitted_usb_devices : {
            resourceName = d.resource_name
            selectors = [{
              vendor  = d.vendor
              product = d.product
            }]
          }]
        }
      }
      customizeComponents = {}
      imagePullPolicy     = "IfNotPresent"
      workloadUpdateStrategy = {
        workloadUpdateMethods = ["LiveMigrate"]
      }
    }
  })

  server_side_apply = true
  wait              = true
}
