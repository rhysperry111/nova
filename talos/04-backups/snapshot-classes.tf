################################################################################
# VolumeSnapshotClasses for the two Rook-Ceph CSI drivers.
#
# These are what makes the "snapshot a PVC" verb work in the cluster. Without
# them, Velero's CSI plugin sees a PVC backed by ceph-block / ceph-filesystem
# and has nowhere to record the snapshot.
#
# Wiring:
#   - driver: must match the provisioner Rook registers
#       rook-ceph.rbd.csi.ceph.com     for ceph-block (RBD)
#       rook-ceph.cephfs.csi.ceph.com  for ceph-filesystem (CephFS)
#   - clusterID: Rook uses the operator namespace name as the cluster ID by
#     default. Both StorageClasses created by the platform stage point at
#     this same ID, so the snapshot class must match.
#   - snapshotter-secret-*: the same provisioner secrets the StorageClass
#     uses. Already created by the rook-ceph-cluster Helm release.
#
# The label `velero.io/csi-volumesnapshot-class: "true"` is the convention
# Velero uses to pick a default snapshot class per driver — without it,
# Velero refuses to snapshot ("no VolumeSnapshotClass found for driver X")
# even though the class exists.
################################################################################

resource "kubectl_manifest" "snapshotclass_rbd" {
  # The snapshot-controller chart is what registers the
  # `volumesnapshotclasses.snapshot.storage.k8s.io` CRD with the API server.
  # Without that dependency this manifest races the CRD install and fails
  # with "resource isn't valid for cluster".
  depends_on = [helm_release.snapshot_controller]

  yaml_body = yamlencode({
    apiVersion = "snapshot.storage.k8s.io/v1"
    kind       = "VolumeSnapshotClass"
    metadata = {
      name = "csi-rbdplugin-snapclass"
      labels = {
        "velero.io/csi-volumesnapshot-class" = "true"
      }
    }
    driver = "${var.rook_ceph_namespace}.rbd.csi.ceph.com"
    parameters = {
      clusterID                                         = var.rook_ceph_namespace
      "csi.storage.k8s.io/snapshotter-secret-name"      = "rook-csi-rbd-provisioner"
      "csi.storage.k8s.io/snapshotter-secret-namespace" = var.rook_ceph_namespace
    }
    deletionPolicy = var.snapshot_deletion_policy
  })

  server_side_apply = true
}

resource "kubectl_manifest" "snapshotclass_cephfs" {
  depends_on = [helm_release.snapshot_controller]

  yaml_body = yamlencode({
    apiVersion = "snapshot.storage.k8s.io/v1"
    kind       = "VolumeSnapshotClass"
    metadata = {
      name = "csi-cephfsplugin-snapclass"
      labels = {
        "velero.io/csi-volumesnapshot-class" = "true"
      }
    }
    driver = "${var.rook_ceph_namespace}.cephfs.csi.ceph.com"
    parameters = {
      clusterID                                         = var.rook_ceph_namespace
      "csi.storage.k8s.io/snapshotter-secret-name"      = "rook-csi-cephfs-provisioner"
      "csi.storage.k8s.io/snapshotter-secret-namespace" = var.rook_ceph_namespace
    }
    deletionPolicy = var.snapshot_deletion_policy
  })

  server_side_apply = true
}
