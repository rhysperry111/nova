################################################################################
# Rook-Ceph — CSI provider, claiming the two SATA SSDs per node.
#
# Three charts, applied strictly in this order (Rook v1.20+ requirement):
#   1. rook-ceph            (operator + bundled ceph-csi-operator subchart + CRDs)
#   2. ceph-csi-drivers     (the actual RBD/CephFS CSI drivers — see note below)
#   3. rook-ceph-cluster    (CephCluster + pools + storage classes)
#
# As of Rook v1.20 the operator NO LONGER deploys the CSI drivers. They're now
# admin-managed via the ceph-csi-operator, and the ceph-csi-drivers chart (from
# the upstream ceph-csi-operator Helm repo, NOT charts.rook.io) is what actually
# brings them up. Without it the CSI driver sits in a failed state (missing
# service accounts) and every PVC fails to mount. The driver names MUST stay
# prefixed with the operator namespace ("rook-ceph") so the provisioner names
# (rook-ceph.rbd.csi.ceph.com / rook-ceph.cephfs.csi.ceph.com) match the
# existing StorageClasses and PVs — changing them would orphan all volumes.
# Ref: https://rook.io/docs/rook/v1.20/Upgrade/rook-upgrade/#helm
#
# Each release depends_on the previous one to enforce the ordering above. The
# operator depends_on Cilium so it doesn't try to schedule before pods can
# network.
################################################################################

resource "kubernetes_namespace" "rook_ceph" {
  depends_on = [helm_release.cilium]

  metadata {
    name = "rook-ceph"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

resource "helm_release" "rook_ceph_operator" {
  depends_on = [kubernetes_namespace.rook_ceph]

  name       = "rook-ceph"
  repository = "https://charts.rook.io/release"
  chart      = "rook-ceph"
  version    = var.rook_ceph_version
  namespace  = kubernetes_namespace.rook_ceph.metadata[0].name

  values = compact([
    yamlencode({
      # Rook v1.20+: the operator no longer carries enableRbdDriver /
      # enableCephfsDriver — those drivers are deployed by the ceph-csi-drivers
      # release below. installCsiOperator defaults to true, which installs the
      # bundled ceph-csi-operator subchart (and its CRDs) that the drivers chart
      # depends on; left implicit here.
      monitoring = {
        enabled = true
      }
    }),
    var.rook_ceph_operator_values_override,
  ])
}

# Ceph-CSI drivers — separate chart since Rook v1.20. Installed with Rook's
# recommended values: drivers enabled, names prefixed with the operator
# namespace so existing StorageClasses/PVs keep working. Must land after the
# operator (for the ceph-csi-operator CRDs) and before the cluster.
resource "helm_release" "ceph_csi_drivers" {
  depends_on = [helm_release.rook_ceph_operator]

  name       = "ceph-csi-drivers"
  repository = "https://ceph.github.io/ceph-csi-operator"
  chart      = "ceph-csi-drivers"
  version    = var.ceph_csi_drivers_version
  namespace  = kubernetes_namespace.rook_ceph.metadata[0].name

  values = compact([
    yamlencode({
      operatorConfig = {
        # Must equal the rook operator namespace — drives the driver-name prefix.
        namespace = kubernetes_namespace.rook_ceph.metadata[0].name
      }
      drivers = {
        rbd = {
          enabled        = true
          name           = "${kubernetes_namespace.rook_ceph.metadata[0].name}.rbd.csi.ceph.com"
          snapshotPolicy = "volumeSnapshot"
        }
        cephfs = {
          enabled        = true
          name           = "${kubernetes_namespace.rook_ceph.metadata[0].name}.cephfs.csi.ceph.com"
          snapshotPolicy = "volumeSnapshot"
        }
        nfs = {
          enabled = false
          name    = "${kubernetes_namespace.rook_ceph.metadata[0].name}.nfs.csi.ceph.com"
        }
        nvmeof = {
          enabled = false
          name    = "${kubernetes_namespace.rook_ceph.metadata[0].name}.nvmeof.csi.ceph.com"
        }
      }
    }),
    var.ceph_csi_drivers_values_override,
  ])
}

resource "helm_release" "rook_ceph_cluster" {
  depends_on = [helm_release.ceph_csi_drivers]

  name       = "rook-ceph-cluster"
  repository = "https://charts.rook.io/release"
  chart      = "rook-ceph-cluster"
  version    = var.rook_ceph_version
  namespace  = kubernetes_namespace.rook_ceph.metadata[0].name

  values = compact([
    yamlencode({
      operatorNamespace = kubernetes_namespace.rook_ceph.metadata[0].name

      monitoring = {
        enabled               = true
        createPrometheusRules = true
      }

      cephClusterSpec = {
        mon = {
          count                = 3
          allowMultiplePerNode = false
        }
        mgr = {
          count = 2
        }
        dashboard = {
          enabled = true
          ssl     = false
        }

        # Graceful node-upgrade handling. Talos drains via the kubelet API;
        # Rook responds by creating PDBs that block parallel disruption of
        # OSDs in the same failure domain (host). Combined with the
        # depends_on chain in the cluster stage's nodes.tf, at most one node
        # is ever being drained / rebooted at a time and Ceph stays within
        # its size=3 / min_size=2 envelope.
        disruptionManagement = {
          managePodBudgets      = true
          osdMaintenanceTimeout = 30
        }

        storage = {
          useAllNodes   = true
          useAllDevices = false
          # NVMe is the system disk and won't appear as sd*, so this safely
          # matches only the two SATA SSDs Rook is meant to claim. Adjust
          # the regex if a node ever exposes extra sd* devices that aren't
          # for Ceph.
          devicePathFilter = "^/dev/disk/by-id/ata-"
        }
      }

      # 4-node cluster, 2 OSDs each (8 OSDs total). size=3, min_size=2 lets
      # us lose any one node and still serve writes — exactly what the
      # upgrade chain needs.
      cephBlockPools = [
        {
          name = "replicapool"
          spec = {
            failureDomain = "host"
            replicated = {
              size                   = 3
              requireSafeReplicaSize = true
            }
            parameters = {
              min_size = "2"
            }
          }
          storageClass = {
            enabled              = true
            name                 = "ceph-block"
            isDefault            = true
            reclaimPolicy        = "Delete"
            allowVolumeExpansion = true
            # The chart only auto-injects clusterID + pool. Every other
            # CSI parameter (secret refs, image format/features, fstype)
            # has to be set explicitly here or the StorageClass renders
            # with no secret refs and CSI fails with "provided secret is
            # empty" on PVC bind.
            parameters = {
              "imageFormat"                                            = "2"
              "imageFeatures"                                          = "layering"
              "csi.storage.k8s.io/fstype"                              = "ext4"
              "csi.storage.k8s.io/provisioner-secret-name"             = "rook-csi-rbd-provisioner"
              "csi.storage.k8s.io/provisioner-secret-namespace"        = "rook-ceph"
              "csi.storage.k8s.io/controller-expand-secret-name"       = "rook-csi-rbd-provisioner"
              "csi.storage.k8s.io/controller-expand-secret-namespace"  = "rook-ceph"
              "csi.storage.k8s.io/controller-publish-secret-name"      = "rook-csi-rbd-provisioner"
              "csi.storage.k8s.io/controller-publish-secret-namespace" = "rook-ceph"
              "csi.storage.k8s.io/node-stage-secret-name"              = "rook-csi-rbd-node"
              "csi.storage.k8s.io/node-stage-secret-namespace"         = "rook-ceph"
            }
          }
        },
      ]

      cephFileSystems = [
        {
          name = "ceph-filesystem"
          spec = {
            metadataPool = {
              replicated = { size = 3 }
              parameters = { min_size = "2" }
            }
            dataPools = [{
              name          = "data0"
              failureDomain = "host"
              replicated    = { size = 3 }
              parameters    = { min_size = "2" }
            }]
            metadataServer = {
              activeCount   = 1
              activeStandby = true
            }
          }
          storageClass = {
            enabled              = true
            name                 = "ceph-filesystem"
            reclaimPolicy        = "Delete"
            allowVolumeExpansion = true
            # Same chart behaviour as cephBlockPools — clusterID + fsName +
            # pool come from the chart, the rest is on us.
            parameters = {
              "csi.storage.k8s.io/fstype"                              = "ext4"
              "csi.storage.k8s.io/provisioner-secret-name"             = "rook-csi-cephfs-provisioner"
              "csi.storage.k8s.io/provisioner-secret-namespace"        = "rook-ceph"
              "csi.storage.k8s.io/controller-expand-secret-name"       = "rook-csi-cephfs-provisioner"
              "csi.storage.k8s.io/controller-expand-secret-namespace"  = "rook-ceph"
              "csi.storage.k8s.io/controller-publish-secret-name"      = "rook-csi-cephfs-provisioner"
              "csi.storage.k8s.io/controller-publish-secret-namespace" = "rook-ceph"
              "csi.storage.k8s.io/node-stage-secret-name"              = "rook-csi-cephfs-node"
              "csi.storage.k8s.io/node-stage-secret-namespace"         = "rook-ceph"
            }
          }
        },
      ]

      cephObjectStores = []

      # Dashboard ingress — dashboard runs HTTP (ssl=false above), the
      # cilium ingress terminates TLS. cert-manager picks up the
      # cluster-issuer annotation and provisions ceph-dashboard-tls;
      # external-dns picks up the host from spec.tls[].hosts and creates
      # the matching Cloudflare record.
      ingress = {
        dashboard = {
          ingressClassName = var.ingress_class_name
          annotations = {
            "cert-manager.io/cluster-issuer" = var.cluster_issuer_name
          }
          host = {
            name     = "ceph.${var.ingress_domain}"
            path     = "/"
            pathType = "Prefix"
          }
          tls = [{
            hosts      = ["ceph.${var.ingress_domain}"]
            secretName = "ceph-dashboard-tls"
          }]
        }
      }
    }),
    var.rook_ceph_cluster_values_override,
  ])
}
