################################################################################
# kube-prometheus-stack — Prometheus Operator + Prometheus + Grafana +
# Alertmanager + node-exporter + kube-state-metrics.
#
# Workloads ship their own scrape targets and alert rules as ServiceMonitor /
# PodMonitor / PrometheusRule resources; the operator reconciles those into
# Prometheus config. The operator's default selector picks up CRs with the
# label `release: kube-prometheus-stack`, so add that label on any new
# ServiceMonitor you want this Prometheus to scrape.
#
# Talos compatibility: kubeControllerManager / kubeScheduler / kubeEtcd are
# disabled because Talos's static control-plane pods aren't labelled in a
# way the chart's default Service selectors find — leaving them on produces
# permanently-red targets without adding signal. kubelet, node-exporter,
# kube-state-metrics, apiserver, and coredns all scrape fine out of the
# box and cover the meaningful kube-* metrics.
#
# Prometheus stays cluster-internal — no Ingress, because it ships no auth.
# Grafana queries it via the in-cluster Service. To poke at PromQL directly,
# port-forward the prometheus-operated Service in the monitoring namespace.
################################################################################

resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
    # node-exporter (DaemonSet) needs hostNetwork/hostPID/hostPath/hostPort to
    # read /proc, /sys, and / off the node — that's its whole job. Talos sets
    # `baseline` as the default PodSecurity enforce level on new namespaces,
    # which forbids all of those. Bump this namespace to `privileged` so the
    # node-level workloads (node-exporter today, Alloy DaemonSet next) are
    # admitted. Higher-level workloads (Prometheus, Grafana, Alertmanager) in
    # the same namespace don't request anything privileged, so this is no
    # weaker than baseline for them in practice.
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }
}

resource "helm_release" "kube_prometheus_stack" {
  depends_on = [kubernetes_namespace_v1.monitoring]

  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_version
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  values = compact([
    yamlencode({
      grafana = {
        adminPassword = var.grafana_admin_password

        persistence = {
          enabled          = true
          type             = "pvc"
          storageClassName = var.prometheus_storage_class
          size             = var.grafana_storage_size
        }

        ingress = {
          enabled          = true
          ingressClassName = var.ingress_class_name
          annotations = {
            "cert-manager.io/cluster-issuer" = var.cluster_issuer_name
          }
          hosts = ["grafana.${var.ingress_domain}"]
          tls = [{
            secretName = "grafana-tls"
            hosts      = ["grafana.${var.ingress_domain}"]
          }]
        }
      }

      prometheus = {
        prometheusSpec = {
          retention = var.prometheus_retention
          enableRemoteWriteReciever = true
          podMonitorNamespaceSelector = {
            matchLabels = {}
          }
          podMonitorSelectorNilUsesHelmValues = false
          serviceMonitorNamespaceSelector = {
            matchLabels = {}
          }
          serviceMonitorSelectorNilUsesHelmValues = false
          ruleNamespaceSelector = {
            matchLabels = {}
          }
          ruleSelectorNilUsesHelmValues = false
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = var.prometheus_storage_class
                accessModes      = ["ReadWriteOnce"]
                resources = {
                  requests = {
                    storage = var.prometheus_storage_size
                  }
                }
              }
            }
          }
        }
      }

      prometheus-node-exporter = {
        prometheusSpec = {
          scrapeInterval = "30s"
        }
      }

      defaultRules = {
        disabled = {
          InfoInhibitor = true
        }
      }

      # Default Alertmanager config (no notifiers wired). Sits ready to take
      # routes/receivers later via the override variable.
      alertmanager = {
        enabled = true
        config = {
          route = {
            receiver = "rhys-discord"
            group_by = [ "alertname", "namespace" ]
            group_wait = "10s"
            group_interval = "1m"
            repeat_interval = "30m"
            routes = [
              {
                receiver = "null"
                matchers = [ "alertname = Watchdog" ]
              },
              {
                receiver = "null"
                matchers = [ "alertname = KubeClientCertificateExpiration" ]
              },
              {
                receiver = "null"
                matchers = [ "alertname = KubeProxyDown" ]
              },
              {
                receiver = "null"
                matchers = [ "alertname = KubeVirtNoAvailableNodesToRunVMs" ]
              },
              {
                receiver = "null"
                matchers = [
                  "alertname = GuestFilesystemAlmostOutOfSpace",
                  "disk_name = vda3",
                  "kubernetes_vmi_label_app = home-assistant"
                ]
              },
              {
                receiver = "null"
                matchers = [
                  "alertname = GuestFilesystemAlmostOutOfSpace",
                  "disk_name = vda5",
                  "kubernetes_vmi_label_app = home-assistant"
                ]
              },
              {
                receiver = "null"
                matchers = [
                  "alertname = CNPGClusterHACritical",
                  "cnpg_cluster = immich-postgres"
                ]
              },
              {
                receiver = "null"
                matchers = [
                  "alertname = CNPGClusterHAWarning",
                  "cnpg_cluster = immich-postgres"
                ]
              }
            ]
          }
          receivers = [
            {
              name = "null"
            },
            {
              name = "rhys-discord"
              discord_configs = [
                {
                  webhook_url = var.alertmanager_discord_webhook
                }
              ]
            }
          ]
        }
      }

      # Talos-incompatible scrape targets. Re-enable via override if/when the
      # Talos machine config is patched to expose them.
      kubeControllerManager = { enabled = false }
      kubeScheduler         = { enabled = false }
      kubeEtcd              = { enabled = false }
    }),
    var.kube_prometheus_stack_values_override,
  ])
}
