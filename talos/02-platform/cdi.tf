################################################################################
# CDI — Containerized Data Importer.
#
# Companion to KubeVirt. CDI is what actually downloads disk images into PVCs
# when a VirtualMachine declares `dataVolumeTemplates` — without it the
# admission webhook (`cdi-api.cdi.svc`) doesn't exist and DataVolume creation
# fails. Same two-bundle install shape as KubeVirt:
#
#   - cdi-operator.yaml  — Namespace, CRDs, operator Deployment, RBAC
#   - cdi-cr.yaml        — the CDI CR that tells the operator to actually
#                          create the api/uploadproxy/deployment workloads
#
# Both are fetched at plan time and applied with server-side apply so the
# operator can later take ownership of the fields it mutates.
################################################################################

data "http" "cdi_operator" {
  url = "https://github.com/kubevirt/containerized-data-importer/releases/download/${var.cdi_version}/cdi-operator.yaml"
}

data "kubectl_file_documents" "cdi_operator" {
  content = data.http.cdi_operator.response_body
}

resource "kubectl_manifest" "cdi_operator" {
  depends_on = [helm_release.cilium]

  for_each = data.kubectl_file_documents.cdi_operator.manifests

  yaml_body         = each.value
  server_side_apply = true
  # The cdi-operator pod patches the CRDs it ships with (conversion webhooks,
  # served versions, etc.), so it ends up co-owning fields that originated in
  # this manifest. Force-take them back on each apply.
  force_conflicts = true
  wait            = true
}

data "http" "cdi_cr" {
  url = "https://github.com/kubevirt/containerized-data-importer/releases/download/${var.cdi_version}/cdi-cr.yaml"
}

data "kubectl_file_documents" "cdi_cr" {
  content = data.http.cdi_cr.response_body
}

resource "kubectl_manifest" "cdi_cr" {
  depends_on = [kubectl_manifest.cdi_operator]

  for_each = data.kubectl_file_documents.cdi_cr.manifests

  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true
  wait              = true
}
