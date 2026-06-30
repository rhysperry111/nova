################################################################################
# snapshot-controller — kubernetes-csi/external-snapshotter, the upstream
# project that:
#   - defines the cluster-wide `snapshot.storage.k8s.io` CRDs
#     (VolumeSnapshot, VolumeSnapshotContent, VolumeSnapshotClass), and
#   - runs the controller Deployment that watches those CRs and drives the
#     per-driver snapshotter sidecars.
#
# Rook-Ceph already ships a snapshotter sidecar inside its CSI driver pods,
# but that sidecar is inert until both (a) the CRDs are registered with the
# API server and (b) the snapshot-controller is reconciling VolumeSnapshot
# objects. That's the gap this chart closes.
#
# Why install it here and not in `platform/`:
#   - The only consumer in this project is Velero's CSI snapshot data mover
#     (see velero.tf). Keeping the controller next to its sole consumer
#     keeps platform/ focused on networking + raw storage.
#   - On a full-cluster rebuild the apply order is still safe: platform/
#     brings up Rook (which provides the snapshotter *sidecar*), then this
#     stage brings up the *controller* and the VolumeSnapshotClasses that
#     bind sidecar and controller to each storage class.
#
# kubernetes-csi/external-snapshotter doesn't publish an official Helm chart;
# the piraeusdatastore packaging is the de-facto community one and tracks
# upstream versions closely.
################################################################################

resource "helm_release" "snapshot_controller" {
  name       = "snapshot-controller"
  namespace  = "kube-system"
  repository = "https://piraeus.io/helm-charts/"
  chart      = "snapshot-controller"
  version    = var.snapshot_controller_chart_version
}
