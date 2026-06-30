################################################################################
# Velero — orchestrator for cluster state + PV backups.
#
# What we get from one Velero install:
#   - Cluster resource state (every Kubernetes object's YAML) written to R2
#     under `backups/<name>/`.
#   - Ceph PV data shipped to R2 via the CSI snapshot data mover:
#       1. CSI driver takes a Ceph snapshot (instant, copy-on-write).
#       2. node-agent (a DaemonSet, deployed below) mounts that snapshot and
#          streams its contents through kopia into `kopia/` in the same
#          bucket.
#       3. The Ceph snapshot is released; data lives in R2 from then on.
#     This is what makes restores possible even after the whole cluster is
#     gone — without the data mover, snapshots stay on Ceph and die with it.
#
# Plugin: velero-plugin-for-aws is the object-store driver for any
# S3-compatible backend (incl. R2, MinIO, Wasabi). Added as an initContainer
# that drops the plugin binary into the Velero pod's shared volume.
#
# R2 quirks the BSL config below works around:
#   - region "auto" (R2 ignores the AWS region concept).
#   - s3ForcePathStyle: true (R2 doesn't do virtual-hosted-style URLs).
#   - s3Url: https://<account>.r2.cloudflarestorage.com (the only endpoint
#     R2 exposes — there's no per-bucket DNS).
#   - checksumAlgorithm: "" — the AWS SDK v2 bundled in Velero 1.14+ adds a
#     CRC32 trailer on PUT by default; R2 returns 400 on those, so we
#     disable it entirely. Without this every upload fails with
#     "InvalidRequest: trailing checksums are not supported".
################################################################################

resource "kubernetes_namespace_v1" "velero" {
  metadata {
    name = var.velero_namespace
    # node-agent (the data-mover DaemonSet) needs hostPath access to
    # /var/lib/kubelet/pods and /var/lib/kubelet/plugins so it can see the
    # CSI snapshot mount it just requested and talk to the Ceph CSI plugin
    # socket. PodSecurity `baseline` (Talos's default on new namespaces)
    # forbids hostPath volumes outright, so bump this namespace to
    # `privileged` — same reasoning as the monitoring namespace and
    # node-exporter. Velero's other workloads (the velero-server Deployment,
    # one-shot Backup/Restore pods) don't request anything privileged, so
    # this isn't loosening anything for them in practice.
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }
}

# Velero plugin-for-aws auth file. The chart mounts this as
# /credentials/cloud and points AWS_SHARED_CREDENTIALS_FILE at it.
resource "kubernetes_secret_v1" "velero_r2" {
  metadata {
    name      = "velero-r2"
    namespace = kubernetes_namespace_v1.velero.metadata[0].name
  }

  data = {
    cloud = <<-EOT
      [default]
      aws_access_key_id=${var.r2_access_key_id}
      aws_secret_access_key=${var.r2_secret_access_key}
    EOT
  }

  type = "Opaque"
}

# Node-agent configuration ConfigMap.
#
# This is *not* about the node-agent DaemonSet's own resources — it controls
# the resources Velero stamps onto the short-lived data mover pods it creates
# per DataUpload (the pods that mount a CSI snapshot and run kopia to stream it
# into R2). Left unconfigured those pods are BestEffort and kopia pins every
# core on the node while hashing/compressing, which is the CPU blowup we're
# fixing here.
#
# Wiring:
#   - node-agent reads this ConfigMap because we pass
#     `--node-agent-configmap=<name>` to it via nodeAgent.extraArgs below.
#   - The ConfigMap must live in the Velero namespace and contain exactly one
#     data key; node-agent takes whichever single key it finds and JSON-decodes
#     its value into the podResources config. The key name itself is arbitrary
#     (we name it after the ConfigMap for readability).
#     See https://velero.io/docs/main/data-movement-pod-resource-configuration/
resource "kubernetes_config_map_v1" "node_agent_config" {
  metadata {
    name      = "node-agent-config"
    namespace = kubernetes_namespace_v1.velero.metadata[0].name
  }

  data = {
    "node-agent-config" = jsonencode({
      podResources = {
        cpuRequest = var.data_mover_cpu_request
        cpuLimit   = var.data_mover_cpu_limit
        ephemeralStorageRequest = "8Gi"
        ephemeralStorageLimit = "32Gi"
        memoryRequest = "512Mi"
        memoryLimit = "2Gi"
      }
    })
  }
}

resource "helm_release" "velero" {
  depends_on = [
    kubernetes_secret_v1.velero_r2,
    kubernetes_config_map_v1.node_agent_config,
    kubectl_manifest.snapshotclass_rbd,
    kubectl_manifest.snapshotclass_cephfs,
  ]

  name       = "velero"
  namespace  = kubernetes_namespace_v1.velero.metadata[0].name
  repository = "https://vmware-tanzu.github.io/helm-charts"
  chart      = "velero"
  version    = var.velero_chart_version

  values = compact([
    yamlencode(merge(
      {
        # CRDs are installed by the chart and kept around if Velero is
        # uninstalled — same reasoning as cert-manager.
        upgradeCRDs      = true
        cleanUpCRDs      = false
        snapshotsEnabled = true

        metrics = {
          enabled = true
          serviceMonitor = {
            enabled = true
          }
          nodeAgentPodMonitor = {
            enabled = true
          }
          prometheusRule = {
            enabled = true
          }
        }

        # node-agent runs as a DaemonSet on every node. It's the component
        # that actually reads PV data through CSI snapshots and uploads it to
        # R2 — without it, the data mover has nothing on the node side.
        deployNodeAgent = true

        # Point node-agent at the ConfigMap above so the data mover pods it
        # creates inherit our CPU request/limit (podResources) instead of
        # running BestEffort and letting kopia eat the whole node.
        nodeAgent = {
          extraArgs = [
            "--node-agent-configmap=${kubernetes_config_map_v1.node_agent_config.metadata[0].name}",
          ]
        }

        # The plugin Velero loads to talk to R2. velero-plugin-for-aws covers
        # every S3-compatible backend.
        initContainers = [{
          name  = "velero-plugin-for-aws"
          image = var.velero_plugin_for_aws_image
          volumeMounts = [{
            mountPath = "/target"
            name      = "plugins"
          }]
        }]

        credentials = {
          # The chart's `existingSecret` arg makes Velero mount the secret we
          # built above instead of generating a fresh one from values.
          useSecret      = true
          existingSecret = kubernetes_secret_v1.velero_r2.metadata[0].name
        }

        configuration = {
          # How long an async item operation (here: each PV's DataUpload —
          # the CSI snapshot → kopia → R2 stream) may run before Velero
          # cancels it and fails the backup. The Velero server default is 4h,
          # which some of our larger PVs blow past while uploading to R2,
          # killing the whole daily-full backup. Bumped to 16h to give slow
          # volumes room to finish. Inherited by every Backup that doesn't set
          # its own itemOperationTimeout (none of ours do).
          defaultItemOperationTimeout = "16h0m0s"

          # Don't let Velero use FS backup (the legacy file-by-file uploader)
          # as a fallback — we explicitly want CSI snapshots for everything.
          defaultVolumesToFsBackup = false

          # CSI snapshot integration must be turned on explicitly via the
          # feature flag, even on Velero 1.14+. The chart's default for
          # `features` is empty, and without `EnableCSI` Velero's CSI
          # snapshotter is dormant — backups with snapshotMoveData=true
          # silently skip every PV (they finish in seconds and the backup
          # logs show no VolumeSnapshot / DataUpload activity).
          # See https://velero.io/docs/v1.16/csi/
          features = "EnableCSI"

          # Make snapshot data movement the default for every Backup the
          # server processes. The Schedules below also set
          # snapshotMoveData=true explicitly, but this ensures ad-hoc
          # `velero backup create` invocations without the
          # `--snapshot-move-data` flag still get data movement, so a manual
          # backup behaves the same as the scheduled one.
          defaultSnapshotMoveData = true

          backupStorageLocation = [{
            name     = "default"
            provider = "aws"
            bucket   = var.r2_bucket
            default  = true
            config = {
              region           = "auto"
              s3ForcePathStyle = "true"
              s3Url            = "https://${var.r2_account_id}.r2.cloudflarestorage.com"
              # R2 rejects the SDK's default CRC32 trailer on PUT; leave
              # blank to disable the trailer entirely.
              checksumAlgorithm = ""
            }
          }]

          # No volumeSnapshotLocation. Velero 1.14+ merged CSI handling into
          # core and deprecated the standalone `velero-plugin-for-csi`;
          # there is no `velero.io/csi` VolumeSnapshotter to point at any
          # more. CSI snapshot data movement uses the BackupStorageLocation
          # above directly — the DataUpload CR references it, and the data
          # mover writes kopia repo entries into the same R2 bucket.
          # VolumeSnapshotLocations are only needed for the legacy
          # native-snapshot path (e.g. EBS via velero-plugin-for-aws's
          # snapshotter), which we are explicitly not using.
          volumeSnapshotLocation = []
        }
      },
      var.velero_image_tag != "" ? {
        image = {
          tag = var.velero_image_tag
        }
      } : {},
    )),
    var.velero_values_override,
  ])
}

################################################################################
# Schedules
#
# Two of them:
#
#   - `daily-full` — 03:00 UTC, includes CSI snapshot data movement of every
#     PV in scope. Retention 30 days. This is the schedule that protects
#     against full cluster loss: a single backup name contains the full set
#     of YAML + every PV's data in R2.
#
#   - `metadata-frequent` — every 6 hours, YAML manifests only, no volume
#     snapshots. Cheap, fast, and gives you a recent recovery point for
#     "I accidentally deleted a ConfigMap" without paying the cost of a full
#     volume snapshot. Retention 7 days.
#
# Both exclude the namespaces in var.excluded_namespaces (rook-ceph in
# particular — that's intentionally not restored from snapshot; see the
# README).
################################################################################

resource "kubectl_manifest" "schedule_daily_full" {
  depends_on = [helm_release.velero]

  yaml_body = yamlencode({
    apiVersion = "velero.io/v1"
    kind       = "Schedule"
    metadata = {
      name      = "daily-full"
      namespace = kubernetes_namespace_v1.velero.metadata[0].name
    }
    spec = {
      schedule = var.backup_schedule_cron
      template = {
        ttl                = var.backup_retention
        includedNamespaces = ["*"]
        excludedNamespaces = var.excluded_namespaces
        storageLocation    = "default"
        # No volumeSnapshotLocations — see velero.tf comment on
        # configuration.volumeSnapshotLocation. CSI data movement uses the
        # BackupStorageLocation directly.
        snapshotVolumes          = true
        snapshotMoveData         = true
        defaultVolumesToFsBackup = false
        includeClusterResources  = true
      }
    }
  })

  server_side_apply = true
}

resource "kubectl_manifest" "schedule_metadata_frequent" {
  depends_on = [helm_release.velero]

  yaml_body = yamlencode({
    apiVersion = "velero.io/v1"
    kind       = "Schedule"
    metadata = {
      name      = "metadata-frequent"
      namespace = kubernetes_namespace_v1.velero.metadata[0].name
    }
    spec = {
      schedule = var.metadata_schedule_cron
      template = {
        ttl                      = var.metadata_retention
        includedNamespaces       = ["*"]
        excludedNamespaces       = var.excluded_namespaces
        storageLocation          = "default"
        snapshotVolumes          = false
        snapshotMoveData         = false
        defaultVolumesToFsBackup = false
        includeClusterResources  = true
      }
    }
  })

  server_side_apply = true
}
