################################################################################
# CloudNativePG — PostgreSQL operator.
#
# Installs the operator + its CRDs (Cluster, Pooler, Backup, ScheduledBackup,
# ImageCatalog, ...). App databases are then declared as `Cluster` CRs in
# stage 05 instead of hand-rolled StatefulSets, which gets us:
#   - rolling minor-version upgrades (bump the operand image tag, operator
#     restarts the instances in place);
#   - declarative major-version upgrades via pg_upgrade (operator >= 1.26);
#   - managed roles, extensions, and config without bespoke entrypoints.
#
# The chart ships CRDs by default (crds.create=true). The operator must exist
# before stage 05 applies, so the Cluster CRs there have their CRDs present.
#
# PodMonitor: the kube-prometheus-stack Prometheus selects PodMonitors
# cluster-wide (podMonitorSelectorNilUsesHelmValues=false), so per-Cluster
# `monitoring.enablePodMonitor` in stage 05 is scraped without extra wiring.
################################################################################

resource "kubernetes_namespace_v1" "cnpg_system" {
  metadata {
    name = "cnpg-system"
  }
}

resource "helm_release" "cnpg" {
  depends_on = [kubernetes_namespace_v1.cnpg_system]

  name       = "cloudnative-pg"
  repository = "https://cloudnative-pg.github.io/charts"
  chart      = "cloudnative-pg"
  version    = var.cnpg_operator_version
  namespace  = kubernetes_namespace_v1.cnpg_system.metadata[0].name

  values = compact([
    yamlencode({
      # Single operator replica is plenty for a homelab; it only orchestrates,
      # the data path is the Postgres pods themselves.
      replicaCount = 1

      # Surface the operator's own metrics to the existing Prometheus. The
      # per-Cluster PodMonitors (instance metrics) are enabled in stage 05.
      monitoring = {
        podMonitorEnabled = true
      }
    }),
    var.cnpg_operator_values_override,
  ])
}
