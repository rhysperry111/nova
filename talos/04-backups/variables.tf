variable "kubeconfig_path" {
  description = "Path to the kubeconfig written by the cluster stage."
  type        = string
  default     = "../01-cluster/kubeconfig"
}

################################################################################
# Cloudflare R2 — S3-compatible object storage Velero writes backups into.
#
# Bucket + token are created out-of-band in the Cloudflare dashboard:
#   1. R2 > Create bucket (name = var.r2_bucket).
#   2. R2 > Manage R2 API Tokens > Create token, Object Read & Write scope,
#      limited to the bucket above. Save the Access Key ID + Secret Access
#      Key — they're shown once.
#   3. Account ID is visible on the R2 overview page (or any zone overview);
#      it determines the S3 endpoint URL.
#
# Velero's AWS plugin handles all S3-compatible backends. R2 needs:
#   - region: "auto"
#   - s3ForcePathStyle: "true"
#   - s3Url: https://<account-id>.r2.cloudflarestorage.com
#   - checksumAlgorithm: ""  (R2 rejects the default CRC32 trailer that the
#                             AWS SDK v2 in Velero 1.14+ ships with)
################################################################################

variable "r2_account_id" {
  description = "Cloudflare account ID. Used to build the R2 S3 endpoint URL."
  type        = string
}

variable "r2_bucket" {
  description = "R2 bucket name Velero writes backups into. Create it in the Cloudflare dashboard first; Velero won't create it."
  type        = string
}

variable "r2_access_key_id" {
  description = "R2 API token Access Key ID. Scope: Object Read & Write on the bucket."
  type        = string
  sensitive   = true
}

variable "r2_secret_access_key" {
  description = "R2 API token Secret Access Key."
  type        = string
  sensitive   = true
}

################################################################################
# Velero
################################################################################

variable "velero_namespace" {
  description = "Namespace Velero runs in. Also where Backup / Schedule / Restore CRs live."
  type        = string
  default     = "velero"
}

variable "velero_chart_version" {
  description = "vmware-tanzu/velero Helm chart version. Chart 12.x ships Velero 1.18+ which has the CSI snapshot data mover built in."
  type        = string
  default     = "12.0.3"
}

variable "velero_image_tag" {
  description = "Velero image tag. Must be >= v1.14 for built-in CSI snapshotMoveData. Empty keeps the chart's pinned appVersion."
  type        = string
  default     = ""
}

variable "velero_plugin_for_aws_image" {
  description = "velero-plugin-for-aws image (the object-store plugin Velero uses for any S3-compatible backend, including R2)."
  type        = string
  default     = "velero/velero-plugin-for-aws:v1.13.2"
}

variable "velero_values_override" {
  description = "Extra YAML appended to the Velero Helm values."
  type        = string
  default     = ""
}

variable "data_mover_cpu_limit" {
  description = <<-EOT
    CPU limit applied to the per-DataUpload/DataDownload data mover pods (the
    short-lived pods node-agent spins up to stream a CSI snapshot through
    kopia into R2). kopia happily saturates every core it can see while
    hashing + compressing, which starved everything else on the node during
    the nightly backup. Capping it here keeps the data mover from monopolising
    the node. Kubernetes CPU quantity ("2000m" = 2 cores ≈ 2000 MHz of a
    typical core).

    Plumbed into the node-agent configMap's `podResources.cpuLimit`; see
    https://velero.io/docs/main/data-movement-pod-resource-configuration/
  EOT
  type        = string
  default     = "2000m"
}

variable "data_mover_cpu_request" {
  description = <<-EOT
    CPU request for the data mover pods. Must be <= data_mover_cpu_limit
    (Velero rejects the podResources block otherwise). Kept well below the
    limit so the pod schedules easily and only reserves a modest baseline,
    while still being allowed to burst up to the limit.
  EOT
  type        = string
  default     = "500m"
}

################################################################################
# Backup schedules
################################################################################

variable "backup_schedule_cron" {
  description = "Cron expression for the daily full backup (resources + CSI snapshot data movement of volumes). UTC."
  type        = string
  default     = "0 3 * * *"
}

variable "backup_retention" {
  description = "How long each daily full backup is retained before Velero garbage-collects it. Go duration string."
  type        = string
  default     = "720h0m0s" # 30 days
}

variable "metadata_schedule_cron" {
  description = "Cron expression for the frequent metadata-only backup (YAML manifests, no volumes). UTC. Cheap, fast, lets you grab a recent resource snapshot without waiting for the nightly volume sweep."
  type        = string
  default     = "0 * * * *"
}

variable "metadata_retention" {
  description = "Retention for the metadata-only backups."
  type        = string
  default     = "720h0m0s" # 7 days
}

variable "excluded_namespaces" {
  description = <<-EOT
    Namespaces excluded from both schedules.

    rook-ceph is excluded because the Ceph cluster (OSDs, MONs, MGR state)
    is bound to the physical disks on these nodes — restoring its manifests
    onto a fresh cluster would conflict with the new Rook deployment. The
    Ceph cluster is re-provisioned by the platform stage on rebuild; user
    data on RBD / CephFS volumes is restored separately via CSI snapshots
    that Velero has uploaded to R2.

    velero is excluded so a restore doesn't try to overwrite the running
    backup controller mid-restore.

    kube-system / kube-public / kube-node-lease are managed by the cluster
    itself and shouldn't be restored from snapshot.
  EOT
  type        = list(string)
  default = [
    "velero",
    "rook-ceph",
  ]
}

################################################################################
# snapshot-controller (kubernetes-csi/external-snapshotter)
################################################################################

variable "snapshot_controller_chart_version" {
  description = <<-EOT
    piraeusdatastore/snapshot-controller Helm chart version. Ships the
    cluster-wide `snapshot.storage.k8s.io` CRDs plus the snapshot-controller
    Deployment that reconciles VolumeSnapshot objects. Without this nothing
    on the cluster understands the VolumeSnapshotClass / VolumeSnapshot CRs
    Velero creates during a backup.

    Chart 5.x ships external-snapshotter v8.x (K8s 1.30+ compatible).
  EOT
  type        = string
  default     = "5.1.1"
}

################################################################################
# VolumeSnapshotClasses
################################################################################

variable "rook_ceph_namespace" {
  description = "Namespace Rook-Ceph is installed into. Used to point the CSI snapshotter secrets at the right place."
  type        = string
  default     = "rook-ceph"
}

variable "snapshot_deletion_policy" {
  description = <<-EOT
    deletionPolicy on the VolumeSnapshotClass. `Retain` keeps the underlying
    Ceph snapshot when the VolumeSnapshot object is deleted (safer — you can
    recover from an accidental delete), `Delete` removes the Ceph snapshot
    with the VS object (saves space). Velero deletes VolumeSnapshot objects
    once it has uploaded the snapshot data to R2, so `Delete` is fine for the
    space-conscious default.
  EOT
  type        = string
  default     = "Delete"
}
