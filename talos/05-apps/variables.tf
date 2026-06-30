variable "kubeconfig_path" {
  description = "Path to the kubeconfig written by the cluster stage."
  type        = string
  default     = "../01-cluster/kubeconfig"
}

variable "ingress_domain" {
  description = "Domain suffix for service hostnames (e.g. `hass.<ingress_domain>`)."
  type        = string
  default     = "rhysperry.com"
}

variable "ingress_class_name" {
  description = "IngressClass used on every Ingress created by this stage."
  type        = string
  default     = "cilium"
}

variable "cluster_issuer_name" {
  description = "Name of the cert-manager ClusterIssuer referenced in Ingress annotations."
  type        = string
  default     = "letsencrypt"
}

################################################################################
# Home Assistant
################################################################################

variable "home_assistant_namespace" {
  description = "Namespace the Home Assistant VM and its supporting objects live in."
  type        = string
  default     = "home-assistant"
}

variable "home_assistant_os_version" {
  description = "Home Assistant OS release tag. The qcow2.xz disk image is fetched from the matching github.com/home-assistant/operating-system release."
  type        = string
  default     = "17.3"
}

variable "home_assistant_disk_size" {
  description = "PVC size for the Home Assistant root disk. The HAOS image is ~1 GiB; the rest is for snapshots, addons, and local data."
  type        = string
  default     = "64Gi"
}

variable "home_assistant_storage_class" {
  description = "StorageClass for the Home Assistant root disk."
  type        = string
  default     = "ceph-block"
}

variable "home_assistant_cpu_cores" {
  description = "vCPU cores for the Home Assistant VM."
  type        = number
  default     = 4
}

variable "home_assistant_memory" {
  description = "Memory request for the Home Assistant VM."
  type        = string
  default     = "8Gi"
}

################################################################################
# Immich
################################################################################

variable "immich_namespace" {
  description = "Namespace the Immich release lives in."
  type        = string
  default     = "immich"
}

variable "immich_chart_version" {
  description = "immich-app/immich-charts chart version (OCI). Chart appVersion lags Immich releases; bump deliberately."
  type        = string
  default     = "0.12.0"
}

variable "immich_image_tag" {
  description = "Override for the immich-server / immich-machine-learning image tag. Empty keeps the chart's pinned appVersion (safest for compatibility)."
  type        = string
  default     = "v2.7.5"
}

variable "immich_library_size" {
  description = "PVC size for the photo/video library."
  type        = string
  default     = "200Gi"
}

variable "immich_library_storage_class" {
  description = "StorageClass for the library PVC. RWO is fine — only immich-server reads/writes."
  type        = string
  default     = "ceph-block"
}

variable "immich_db_image" {
  description = "CloudNativePG operand image for the Immich Postgres Cluster. The official `standard` flavour bundles pgvector (the only vector extension Immich needs now). Minor PG upgrades = bump this tag and CNPG rolls the instances."
  type        = string
  default     = "ghcr.io/cloudnative-pg/postgresql:14.19-standard-bookworm"
}

variable "cnpg_cluster_chart_version" {
  description = "cloudnative-pg/cluster Helm chart version (renders the Immich Postgres Cluster CR)."
  type        = string
  default     = "0.6.1"
}

# --- Migration toggles: StatefulSet -> CloudNativePG -------------------------
# Flip these in sequence to cut the DB over with the old StatefulSet kept alive
# as rollback. See the file header in immich.tf for the full runbook.
variable "immich_postgres_password" {
  description = "Password for the Immich postgres user. Sensitive; goes into a Secret consumed by both the postgres StatefulSet and the immich-server pods."
  type        = string
  sensitive   = true
  # No default — provide via 05-apps/secrets.auto.tfvars (gitignored).
}

variable "immich_postgres_storage_size" {
  description = "PVC size for the postgres data dir."
  type        = string
  default     = "20Gi"
}

variable "immich_postgres_storage_class" {
  description = "StorageClass for the postgres data PVC."
  type        = string
  default     = "ceph-block"
}

variable "immich_values_override" {
  description = "Extra YAML appended to the Immich Helm values."
  type        = string
  default     = ""
}

################################################################################
# Vaultwarden
################################################################################

variable "vaultwarden_namespace" {
  description = "Namespace the Vaultwarden release lives in."
  type        = string
  default     = "vaultwarden"
}

variable "vaultwarden_chart_version" {
  description = "guerzon/vaultwarden Helm chart version."
  type        = string
  default     = "0.39.0"
}

variable "vaultwarden_image_tag" {
  description = "vaultwarden container image tag. Defaults to the chart's pinned appVersion-alpine."
  type        = string
  default     = "1.36.0-alpine"
}

variable "vaultwarden_disk_size" {
  description = "PVC size for /data (sqlite DB, attachments, sends, icon_cache)."
  type        = string
  default     = "10Gi"
}

variable "vaultwarden_storage_class" {
  description = "StorageClass for the Vaultwarden /data PVC."
  type        = string
  default     = "ceph-block"
}

variable "vaultwarden_admin_token" {
  description = <<-EOT
    Argon2id hash of the admin panel token. Generate with
    `docker run --rm vaultwarden/server /vaultwarden hash` and paste the
    full `$argon2id$...` string here. Empty disables the admin panel.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "vaultwarden_signups_allowed" {
  description = "Allow new account signups on the public endpoint. Keep false for a personal vault."
  type        = bool
  default     = false
}

variable "vaultwarden_values_override" {
  description = "Extra YAML appended to the Vaultwarden Helm values."
  type        = string
  default     = ""
}

################################################################################
# Jellyfin
################################################################################

variable "jellyfin_namespace" {
  description = "Namespace the Jellyfin deployment lives in."
  type        = string
  default     = "jellyfin"
}

variable "jellyfin_image" {
  description = "Jellyfin container image. Pin precisely — Jellyfin migrates its /config schema on upgrade, so bump deliberately."
  type        = string
  default     = "jellyfin/jellyfin:10.11.11"
}

variable "jellyfin_replicas" {
  description = "Replica count for the Jellyfin deployment. Set to 0 to release the RWO media PVC for the import-pod workflow, then back to 1."
  type        = number
  default     = 1
}

variable "jellyfin_config_size" {
  description = "PVC size for /config (settings, user DB, scraped metadata/artwork cache)."
  type        = string
  default     = "20Gi"
}

variable "jellyfin_config_storage_class" {
  description = "StorageClass for the Jellyfin /config PVC."
  type        = string
  default     = "ceph-block"
}

variable "jellyfin_media_size" {
  description = "PVC size for /media — the media library you import into. Grow in place via `kubectl edit pvc` (ceph-csi expands online)."
  type        = string
  default     = "1000Gi"
}

variable "jellyfin_media_storage_class" {
  description = "StorageClass for the Jellyfin /media PVC. RWO — only one pod (Jellyfin, or the importer) mounts it at a time."
  type        = string
  default     = "ceph-block"
}

variable "home_assistant_host_devices" {
  description = <<-EOT
    Host devices attached to the Home Assistant VM (typically USB radios like
    Zigbee/Z-Wave sticks). Each `device_name` must match a `resource_name`
    declared in talos/platform's `kubevirt_permitted_usb_devices`; that
    variable is what allowlists the device on the KubeVirt CR. `name` is a
    local handle inside the VM spec.
  EOT
  type = list(object({
    name        = string
    device_name = string
  }))
  default = [
    {
      name        = "zigbee"
      device_name = "kubevirt.io/zigbee-stick"
    }
  ]
}
