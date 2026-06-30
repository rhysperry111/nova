# nova backups stage

Velero backing up cluster resource state **and** Ceph PV data to Cloudflare R2.

| File | What it does |
| --- | --- |
| [versions.tf](versions.tf) | `kubernetes` + `helm` + `kubectl` provider pins |
| [providers.tf](providers.tf) | All three providers wired to `var.kubeconfig_path` |
| [variables.tf](variables.tf) | R2 creds, chart versions, schedules, retention, exclusions |
| [snapshot-controller.tf](snapshot-controller.tf) | kubernetes-csi/external-snapshotter — installs the `snapshot.storage.k8s.io` CRDs + the controller that reconciles `VolumeSnapshot` objects |
| [snapshot-classes.tf](snapshot-classes.tf) | `VolumeSnapshotClass` for ceph-block (RBD) + ceph-filesystem (CephFS) |
| [velero.tf](velero.tf) | Velero namespace + R2 credentials Secret + Helm release + two `Schedule` CRs |
| [terraform.auto.tfvars](terraform.auto.tfvars) | Example tfvars — copy and gitignore the real one |

This stage runs **after `platform/`**. It depends on Rook-Ceph (for CSI
snapshots) but nothing in `platformservices/` or `apps/`, so you can apply it
as soon as the platform stage is green.

```sh
cd backups/
tofu init
tofu apply
```

## How the backups work

**Two schedules, one R2 bucket.**

| Schedule | When | What | Retention |
| --- | --- | --- | --- |
| `metadata-frequent` | every 6 h | every namespace's YAML manifests, no volumes | 7 days |
| `daily-full` | 03:00 UTC | every namespace's YAML **plus** CSI snapshot data movement of every PV | 30 days |

Both exclude `kube-system`, `kube-public`, `kube-node-lease`, `velero`, and
`rook-ceph` (see [variables.tf](variables.tf) for the reasoning).

**The PV data path** for `daily-full`:

1. Velero asks the cluster to create a `VolumeSnapshot` for each PVC in scope.
2. The `csi-rbdplugin-snapclass` / `csi-cephfsplugin-snapclass` we ship here
   tells the snapshotter how to talk to Ceph; Ceph creates a copy-on-write
   snapshot.
3. Velero's `node-agent` DaemonSet mounts that snapshot read-only and streams
   its contents through kopia into the R2 bucket under `kopia/`.
4. The Ceph snapshot is released. From here on, PV data lives in R2 and is
   restorable even if the original cluster is gone.

The resource YAMLs live alongside under `backups/<backup-name>/` in the same
bucket.

## R2 setup (one-time)

You need three things in [variables.tf](variables.tf):

1. **Bucket** — Cloudflare dashboard → R2 → Create bucket. Pick a name and
   put it in `r2_bucket`. Velero will not create the bucket; it expects it
   to exist.
2. **API token** — Cloudflare dashboard → R2 → Manage R2 API Tokens →
   Create API Token. Permission `Object Read & Write`, scoped to the bucket
   above. The Access Key ID + Secret Access Key are shown **once** — copy
   both into `r2_access_key_id` and `r2_secret_access_key`.
3. **Account ID** — R2 overview page sidebar, 32-char hex. Goes into
   `r2_account_id`; the endpoint URL is derived from it.

R2 has no egress fees, so restore traffic is free. Storage is ~$0.015/GB·mo
which puts the whole nova cluster at single-digit dollars/month even with
30-day daily retention.

## Day-to-day: inspecting backups

`velero` is the CLI; install with `brew install velero` or grab the binary
from the
[releases page](https://github.com/vmware-tanzu/velero/releases). Point it
at the cluster's kubeconfig (same one this stage uses) and the velero
namespace:

```sh
export KUBECONFIG=../cluster/kubeconfig

velero backup get                               # list all backups
velero backup describe daily-full-20260528...   # details of one backup
velero backup logs    daily-full-20260528...    # see what got snapshotted
velero schedule get                             # the two schedules
```

The schedule resources themselves live in-cluster as `Schedule.velero.io` in
the `velero` namespace, so `kubectl -n velero get schedules` works too.

## Verifying a backup actually snapshotted volumes

A backup that finishes in seconds with no errors is **not necessarily** a
successful backup — Velero will silently skip PVs if CSI snapshotting is
misconfigured (no `features: EnableCSI`, no matching VolumeSnapshotClass, no
node-agent reachable). Always confirm a fresh install actually moves data
before trusting the schedule. Run a one-shot backup and check the four
indicators below:

```sh
velero backup create verify --include-namespaces immich --snapshot-move-data --wait
```

1. **The backup describes itself as having snapshots.**

   ```sh
   velero backup describe verify --details
   ```

   Look for the lines:

   ```
   Phase:  Completed
   ...
   CSI Volume Snapshots:  <N> of <N> snapshots completed successfully
   ...
   ```

   `<N>` should match the number of PVCs the namespace has. `0` (or the
   field being absent) means Velero never even tried — likely a
   feature-flag / snapshot-class problem.

2. **`VolumeSnapshot` objects appeared in the source namespace during the
   backup.** (They get cleaned up after the data upload completes, so catch
   them while the backup is running, or look at the previous backup's logs.)

   ```sh
   kubectl -n velero logs deploy/velero | grep -i volumesnapshot | tail
   ```

   Each PV in scope should produce a "Creating snapshot" line.

3. **`DataUpload` CRs ran to completion.** Each PV gets one; this is the
   actual proof that bytes moved from Ceph to R2.

   ```sh
   kubectl -n velero get datauploads.velero.io
   # NAME                STATUS     STARTED   BYTES DONE   TOTAL BYTES   STORAGE LOCATION   AGE
   # verify-r8m4x        Completed  2m        3145728      3145728       default            3m
   ```

   `Status: Completed` and a non-zero `BYTES DONE` is the confirmation.
   `Status: InProgress` for many minutes is normal for large PVs (kopia
   streaming the snapshot up to R2 over WAN).

4. **R2 has objects under `kopia/`.** The data-mover writes a kopia repo
   into that prefix; until it does, R2 only contains the resource YAMLs in
   `backups/`.

   ```sh
   aws --endpoint-url "https://${R2_ACCOUNT}.r2.cloudflarestorage.com" \
       s3 ls --recursive s3://${R2_BUCKET}/kopia/ | head
   ```

If any of these four checks come back empty, **don't trust the backup** —
debug before letting the daily schedule lull you into a false sense of
safety. The four most common reasons it falls back to a metadata-only
backup are listed in [Troubleshooting](#troubleshooting) below.

## Restoring

### A single PVC's data (volume-level restore)

Use case: a PVC's data was corrupted/wiped but the workload manifests are
all fine.

```sh
# 1. Find a backup that includes the namespace & PVC you want.
velero backup get
velero backup describe daily-full-20260528030000 --details \
  | less     # look for the PVC under "Persistent Volume Claims"

# 2. Scale the owning workload down to 0 so nothing is holding the volume.
kubectl -n immich scale statefulset immich-postgres --replicas=0

# 3. Restore JUST the PVC + PV from that backup. We tell Velero to skip
#    everything else, so it only re-creates the volume.
velero restore create \
  --from-backup daily-full-20260528030000 \
  --include-namespaces immich \
  --include-resources persistentvolumeclaims,persistentvolumes \
  --selector 'app.kubernetes.io/name=immich-postgres' \
  --restore-volumes=true

# 4. Watch the restore.
velero restore describe <restore-name>
velero restore logs     <restore-name>

# 5. Scale the workload back up.
kubectl -n immich scale statefulset immich-postgres --replicas=1
```

Velero's restore for a CSI-data-moved snapshot pulls the kopia contents back
down from R2 into a fresh PV provisioned by Rook (so you get a new volume
with the snapshot's data, not the corrupt one). You can also pre-create the
target PVC by hand if you want to control its size or StorageClass.

If the PVC has `prevent_destroy = true` in Terraform (like immich-library
and immich-postgres do), you'll need to delete the old PVC *manually* before
the restore can re-create it under the same name. The Terraform state will
then think the PVC is missing; run `tofu apply` to put it back into state —
the restored PVC will already match and Terraform will adopt it.

### A single namespace (workload-level restore)

Use case: you nuked a namespace, or want to roll one app back to yesterday.

```sh
velero restore create \
  --from-backup daily-full-20260528030000 \
  --include-namespaces immich \
  --restore-volumes=true
```

That re-creates every object that lived in `immich` at backup time, and
restores any PVs that namespace had. If the namespace still exists, Velero
merges (skips already-existing objects by default); to start clean, delete
the namespace first.

### Full cluster loss

The worst case: every node's disks are gone. R2 is the only thing left.

1. **Re-stand the cluster up.** Same physical hardware or new, follow the
   stage 1 → stage 2 → stage 3 order in [../README.md](../README.md):

   ```sh
   cd ../cluster/     && tofu apply
   cd ../platform/    && tofu apply
   cd ../platformservices/ && tofu apply
   ```

   At this point you have an empty cluster with Cilium, Rook-Ceph, Vault,
   cert-manager, external-dns, ArgoCD — but none of the apps' data.

2. **Apply this stage**, pointing at the **same R2 bucket** as before:

   ```sh
   cd ../backups/ && tofu apply
   ```

   Velero comes up and on first sync reads the existing `backups/` and
   `kopia/` prefixes from R2 — every backup the old cluster wrote is now
   visible to the new one.

   ```sh
   velero backup get   # should list all the backups from before the loss
   ```

3. **Restore from the most recent daily-full.** Pick the latest:

   ```sh
   LATEST=$(velero backup get -o json \
     | jq -r '.items
              | map(select(.metadata.name | startswith("daily-full-")))
              | sort_by(.metadata.creationTimestamp)
              | last.metadata.name')
   echo "restoring from $LATEST"

   velero restore create cluster-recovery \
     --from-backup "$LATEST" \
     --restore-volumes=true
   ```

   Velero will:
   - Re-create every backed-up namespace.
   - Re-create every Service, Deployment, StatefulSet, Secret, ConfigMap,
     Ingress, etc. exactly as captured.
   - Provision fresh PVs on the new Ceph cluster and stream the kopia data
     back into them from R2.

   This takes a while — the PV data has to come down from R2 over WAN. Use
   `velero restore describe cluster-recovery` to watch.

4. **Re-apply the apps stage**, so Terraform's state lines up with what
   Velero just put back:

   ```sh
   cd ../apps/ && tofu apply
   ```

   Most resources will already exist; Terraform adopts them in place (the
   PVCs declared with `prevent_destroy` were restored under the same names,
   so Terraform sees no drift on the spec it cares about).

5. **Sanity-check each app.** Log into Immich, Home Assistant, Vaultwarden,
   etc. Vaultwarden's `rsa_key.*` files restore verbatim, so existing
   clients stay logged in. Immich's postgres data is in the restored
   `data` PVC of the StatefulSet; Immich comes up against it directly.
   Home Assistant's VM disk restores as a PVC and KubeVirt's
   `VirtualMachine` resource (also captured by Velero) boots off it.

### Why rook-ceph is excluded

`rook-ceph` namespace state is **deliberately not** in the backup. The
CephCluster CR describes the physical OSDs (which disks on which nodes),
the MON quorum, the on-disk format — none of that is portable to a new
cluster. Restoring it would conflict with the freshly-deployed Rook from
the platform stage and at best get rejected, at worst corrupt the new
cluster.

The **data** on Ceph PVs is what matters, and that's what the CSI snapshot
data mover ships to R2. On restore, Velero asks the new Ceph cluster to
provision fresh PVs and refills them from R2 — Ceph is the substrate, not
the payload.

## Troubleshooting

- **`InvalidRequest: trailing checksums are not supported`** in
  `velero backup logs`. R2 rejected an upload with the AWS SDK's default
  CRC32 trailer. Make sure
  `configuration.backupStorageLocation[0].config.checksumAlgorithm = ""`
  in [velero.tf](velero.tf) — `tofu apply` again if you've edited it.

- **`no VolumeSnapshotClass found for driver rook-ceph.rbd.csi.ceph.com`**.
  The label `velero.io/csi-volumesnapshot-class: "true"` got stripped off
  the snapshot class, or the class doesn't exist. Check:

  ```sh
  kubectl get volumesnapshotclass --show-labels
  ```

- **`unable to get valid VolumeSnapshotter for "velero.io/csi"`** in backup
  errors. The Backup or Schedule references a `volumeSnapshotLocation` whose
  `provider: csi` is pointing at the old `velero-plugin-for-csi` plugin —
  deprecated and removed in Velero 1.14, when CSI handling moved into core.
  The fix is to **drop the VolumeSnapshotLocation entirely**: CSI snapshot
  data movement uses the BackupStorageLocation directly. This stage is
  already configured that way ([velero.tf](velero.tf): empty
  `volumeSnapshotLocation`, no `volumeSnapshotLocations` on Schedules) — if
  you add custom Backups by hand, omit those fields too.

- **Backup `PartiallyFailed` with `data movement failed`**. The node-agent
  DaemonSet pod on the same node as the PV couldn't reach R2 or ran out of
  scratch space. Check `kubectl -n velero logs ds/node-agent` and the
  pod's `/tmp` usage — kopia caches blocks before uploading.

- **`expected backup to be of type Volumes-included` on restore**. You're
  restoring from the `metadata-frequent` schedule — that one explicitly
  doesn't include volumes. Pick a `daily-full-*` backup instead.

- **Bucket-fills**. Velero garbage-collects expired backups every hour by
  default; if R2 usage is climbing past expectations, check
  `velero backup get` for backups that look orphaned (older than
  retention, status not `Deleting`). Force one with
  `velero backup delete <name> --confirm`.
