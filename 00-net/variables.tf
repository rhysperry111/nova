################################################################################
# Provider credentials — secret. Provide via 00-net/secrets.auto.tfvars
# (gitignored). No defaults, so a missing secrets file fails closed.
################################################################################

variable "unifi_username" {
  description = "UniFi controller username for the bootstrap stage."
  type        = string
  sensitive   = true
}

variable "unifi_password" {
  description = "UniFi controller password for the bootstrap stage."
  type        = string
  sensitive   = true
}

################################################################################
# UniFi controller. Non-secret values below carry defaults equal to the live
# config; `nova.auto.tfvars` (from nova.yaml) overrides them via `make generate`.
################################################################################

variable "unifi_api_url" {
  description = "UniFi Controller API URL the bootstrap stage talks to."
  type        = string
  default     = "https://10.205.20.1"
}

################################################################################
# Nova network
################################################################################

variable "network_name" {
  description = "Name of the UniFi network created for the Nova cluster."
  type        = string
  default     = "Nova"
}

variable "network_cidr" {
  description = "The network's own gateway address + prefix (unifi_network.subnet)."
  type        = string
  default     = "10.205.10.1/24"
}

variable "network_vlan" {
  description = "VLAN ID for the Nova network."
  type        = number
  default     = 10
}

variable "dhcp_start" {
  description = "First address in the DHCP pool."
  type        = string
  default     = "10.205.10.11"
}

variable "dhcp_stop" {
  description = "Last address in the DHCP pool."
  type        = string
  default     = "10.205.10.249"
}

################################################################################
# BGP / routing — MUST agree with talos/02-platform/cilium-bgp.tf. Centralised
# in nova.yaml so the two sides of the peering can't drift.
################################################################################

variable "node_subnet" {
  description = "Nova node subnet; the BGP listen range on the gateway."
  type        = string
  default     = "10.205.10.0/24"
}

variable "lb_pool_cidr" {
  description = "LB IP pool. Only /32s inside this are accepted from Cilium (inbound prefix-list)."
  type        = string
  default     = "10.208.0.0/16"
}

variable "bgp_cilium_asn" {
  description = "Cilium-side ASN (remote-as of the CILIUM peer-group)."
  type        = number
  default     = 64512
}

variable "bgp_unifi_asn" {
  description = "UniFi-side ASN (local `router bgp` ASN on the gateway)."
  type        = number
  default     = 64513
}

variable "bgp_router_ip" {
  description = "UniFi gateway IP; FRR router-id."
  type        = string
  default     = "10.205.10.1"
}
