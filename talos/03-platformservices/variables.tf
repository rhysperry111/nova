variable "kubeconfig_path" {
  description = "Path to the kubeconfig written by the cluster stage."
  type        = string
  default     = "../01-cluster/kubeconfig"
}

variable "ingress_domain" {
  description = "Domain suffix for service hostnames (e.g. `argocd.<ingress_domain>`)."
  type        = string
  default     = "rhysperry.com"
}

variable "ingress_class_name" {
  description = "IngressClass used on every Ingress created by this stage."
  type        = string
  default     = "cilium"
}

################################################################################
# Cloudflare — shared by cert-manager (DNS-01 solver) and external-dns
# (DNS record management). Both expect the same API token, scoped to:
#   - Zone:Zone:Read         (all zones being managed)
#   - Zone:DNS:Edit          (all zones being managed)
################################################################################

variable "cloudflare_api_token" {
  description = "Cloudflare API token used by cert-manager (DNS-01) and external-dns."
  type        = string
  sensitive   = true
}


variable "external_dns_unifi_webhook_version" {
  type = string
}

variable "unifi_api_url" {
  type = string
}

variable "unifi_api_key" {
  type      = string
  sensitive = true
}

################################################################################
# cert-manager
################################################################################

variable "cert_manager_version" {
  description = "cert-manager Helm chart version."
  type        = string
  default     = "v1.20.2"
}

variable "cert_manager_values_override" {
  description = "Extra YAML appended to the cert-manager Helm values."
  type        = string
  default     = ""
}

variable "acme_email" {
  description = "Contact email registered with Let's Encrypt for the ClusterIssuer."
  type        = string
}

variable "acme_server" {
  description = "ACME directory URL. Defaults to Let's Encrypt production."
  type        = string
  default     = "https://acme-v02.api.letsencrypt.org/directory"
}

variable "acme_profile" {
  description = "ACME Certificate profile."
  type        = string
  default     = "shortlived"
}

variable "cluster_issuer_name" {
  description = "Name of the ClusterIssuer that cert-manager will create."
  type        = string
  default     = "letsencrypt"
}

################################################################################
# external-dns
################################################################################

variable "external_dns_version" {
  description = "external-dns Helm chart version."
  type        = string
  default     = "1.21.1"
}

variable "external_dns_values_override" {
  description = "Extra YAML appended to the external-dns Helm values."
  type        = string
  default     = ""
}

variable "external_dns_domain_filters" {
  description = "Domains external-dns is allowed to manage records in. Empty list means all zones the token can see."
  type        = list(string)
  default     = []
}

variable "external_dns_txt_owner_id" {
  description = "Owner ID written into the TXT registry records, so multiple external-dns instances don't fight over the same zone."
  type        = string
  default     = "nova"
}

variable "external_dns_policy" {
  description = "external-dns reconciliation policy. `sync` deletes records it no longer owns; `upsert-only` never deletes."
  type        = string
  default     = "sync"
}

################################################################################
# ArgoCD
################################################################################

variable "argocd_version" {
  description = "argo-cd Helm chart version."
  type        = string
  default     = "9.5.21"
}

variable "argocd_values_override" {
  description = "Extra YAML appended to the argo-cd Helm values."
  type        = string
  default     = ""
}

variable "argocd_ha" {
  description = "Run ArgoCD in HA mode (3-replica repo-server, redis-ha, etc)."
  type        = bool
  default     = false
}

################################################################################
# CloudNativePG — Postgres operator. Manages Postgres Clusters (failover,
# rolling minor upgrades, declarative major upgrades, backups) so app DBs
# aren't hand-rolled StatefulSets. Apps in stage 05 create Cluster CRs against
# the CRDs this operator installs.
################################################################################

variable "cnpg_operator_version" {
  description = "cloudnative-pg operator Helm chart version. Chart 0.28.x installs operator appVersion 1.29.x (>=1.26 needed for declarative major upgrades)."
  type        = string
  default     = "0.28.3"
}

variable "cnpg_operator_values_override" {
  description = "Extra YAML appended to the cloudnative-pg Helm values."
  type        = string
  default     = ""
}

################################################################################
# kube-prometheus-stack — Prometheus Operator + Prometheus + Grafana +
# Alertmanager + node-exporter + kube-state-metrics. The operator is what
# makes ServiceMonitor / PrometheusRule resources useful — workloads add
# their own scrape configs by shipping those CRs alongside their manifests.
################################################################################

variable "kube_prometheus_stack_version" {
  description = "kube-prometheus-stack Helm chart version."
  type        = string
  default     = "86.2.3"
}

variable "kube_prometheus_stack_values_override" {
  description = "Extra YAML appended to the kube-prometheus-stack Helm values."
  type        = string
  default     = ""
}

variable "prometheus_storage_size" {
  description = "PVC size for the Prometheus tsdb."
  type        = string
  default     = "50Gi"
}

variable "prometheus_storage_class" {
  description = "StorageClass for the Prometheus and Grafana PVCs."
  type        = string
  default     = "ceph-block"
}

variable "prometheus_retention" {
  description = "How long Prometheus retains samples on disk before they age out. Use Prometheus duration units (e.g. `15d`, `30d`)."
  type        = string
  default     = "9999d"
}

variable "grafana_storage_size" {
  description = "PVC size for Grafana's /var/lib/grafana (dashboards-as-data, plugin state)."
  type        = string
  default     = "10Gi"
}

variable "grafana_admin_password" {
  description = "Initial admin password for the Grafana UI. Sensitive."
  type        = string
  sensitive   = true
}

################################################################################
# Registry — CNCF Distribution (the reference OCI image registry).
################################################################################

variable "registry_namespace" {
  description = "Namespace the image registry runs in."
  type        = string
  default     = "registry"
}

variable "registry_image_tag" {
  description = "Tag of the docker.io/library/registry (CNCF Distribution) image."
  type        = string
  default     = "3.1.1"
}

variable "registry_storage_size" {
  description = "PVC size for the registry's blob store (/var/lib/registry)."
  type        = string
  default     = "50Gi"
}

variable "registry_storage_class" {
  description = "StorageClass for the registry PVC."
  type        = string
  default     = "ceph-block"
}

variable "alertmanager_discord_webhook" {
  description = "Discord webhook URL for alertmanager"
  type        = string
  sensitive   = true
}
