variable "kubeconfig_path" {
  description = "Path to the kubeconfig written by the cluster stage."
  type        = string
  default     = "../01-cluster/kubeconfig"
}

variable "cilium_version" {
  description = "Cilium Helm chart version."
  type        = string
  default     = "1.19.5"
}

variable "cilium_values_override" {
  description = "Extra YAML appended to the Cilium Helm values."
  type        = string
  default     = ""
}

variable "rook_ceph_version" {
  description = "Rook-Ceph Helm chart version (operator and cluster charts share it)."
  type        = string
  default     = "v1.20.1"
}

variable "rook_ceph_operator_values_override" {
  description = "Extra YAML appended to the Rook-Ceph operator Helm values."
  type        = string
  default     = ""
}

variable "ceph_csi_drivers_version" {
  description = <<-EOT
    ceph-csi-drivers Helm chart version (repo: https://ceph.github.io/ceph-csi-operator).
    Since Rook v1.20 the operator no longer deploys the CSI drivers itself; this
    chart installs them and MUST be present or PVCs fail to mount. Keep it matched
    to the ceph-csi-operator subchart version pinned by the rook-ceph chart.
  EOT
  type        = string
  default     = "1.0.1"
}

variable "ceph_csi_drivers_values_override" {
  description = "Extra YAML appended to the ceph-csi-drivers Helm values."
  type        = string
  default     = ""
}

variable "rook_ceph_cluster_values_override" {
  description = "Extra YAML appended to the Rook-Ceph cluster Helm values."
  type        = string
  default     = ""
}

variable "metrics_server_version" {
  description = "metrics-server Helm chart version."
  type        = string
  default     = "3.13.1"
}

variable "metrics_server_values_override" {
  description = "Extra YAML appended to the metrics-server Helm values."
  type        = string
  default     = ""
}

variable "kubevirt_version" {
  description = "KubeVirt release tag (used for both kubevirt-operator.yaml URL and the operator image)."
  type        = string
  default     = "v1.8.4"
}

variable "cdi_version" {
  description = "Containerized Data Importer release tag. cdi-operator.yaml and cdi-cr.yaml are fetched from this tag."
  type        = string
  default     = "v1.65.0"
}

variable "kubevirt_feature_gates" {
  description = "Feature gates set on the KubeVirt CR's developerConfiguration. `HostDevices` is added automatically when kubevirt_permitted_usb_devices is non-empty."
  type        = list(string)
  default     = []
}

variable "kubevirt_permitted_usb_devices" {
  description = <<-EOT
    USB devices allowlisted for host passthrough on the KubeVirt CR.
    Each entry becomes a permittedHostDevices.usb selector. The
    `resource_name` is what VirtualMachine specs reference via
    `spec.domain.devices.hostDevices[*].deviceName`. Vendor/product are
    the 4-hex-digit USB IDs (lsusb output, lowercase, no `0x`).
  EOT
  type = list(object({
    resource_name = string
    vendor        = string
    product       = string
  }))
  default = [
    {
      resource_name = "kubevirt.io/zigbee-stick"
      vendor        = "10c4"
      product       = "ea60"
    }
  ]
}

################################################################################
# Ingress / Gateway API — shared knobs.
#
# The cluster-issuer name is referenced in `cert-manager.io/cluster-issuer`
# annotations on the Ingress objects created by this stage, even though the
# ClusterIssuer itself is created later in platformservices. The annotation
# becomes load-bearing only once cert-manager is up; until then it's inert.
################################################################################

variable "ingress_domain" {
  description = "Domain suffix for service hostnames (e.g. `hubble.<ingress_domain>`)."
  type        = string
  default     = "rhysperry.com"
}

variable "ingress_class_name" {
  description = "IngressClass used on every Ingress created by this stage."
  type        = string
  default     = "cilium"
}

variable "cluster_issuer_name" {
  description = "Name of the cert-manager ClusterIssuer referenced in Ingress annotations. Created in platformservices."
  type        = string
  default     = "letsencrypt"
}

variable "gateway_api_version" {
  description = "kubernetes-sigs/gateway-api release tag. Standard-install CRDs are fetched from this tag."
  type        = string
  default     = "v1.5.1"
}

################################################################################
# LB-IPAM — CIDR Cilium hands LoadBalancer IPs out of. Independent of BGP;
# kept here so re-adding BGP/L2 announcements later doesn't reshuffle IPs
# already pinned to existing Services.
################################################################################

variable "lb_ipam_pool_cidrs" {
  description = "CIDRs the CiliumLoadBalancerIPPool allocates from. Must be reachable via BGP routes — by design, NOT in the node or pod/service subnets. Pairs with the inbound prefix-list in 00-net/bgp.tf — keep the two in sync."
  type        = list(string)
  default     = ["10.208.0.0/16"]
}

################################################################################
# BGP — MUST agree with 00-net/bgp.tf (the UniFi/FRR side of the peering).
# Centralised in nova.yaml so the two sides can't drift. Defaults equal the
# live config; nova.auto.tfvars overrides via `make generate`.
################################################################################

variable "bgp_cilium_asn" {
  description = "Cilium-side ASN (localASN on CiliumBGPClusterConfig)."
  type        = number
  default     = 64512
}

variable "bgp_unifi_asn" {
  description = "UniFi-side ASN (peerASN on the Cilium peer)."
  type        = number
  default     = 64513
}

variable "bgp_router_ip" {
  description = "UniFi gateway IP that Cilium peers with (peerAddress)."
  type        = string
  default     = "10.205.10.1"
}
