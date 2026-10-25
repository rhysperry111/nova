variable "cluster_name" {
  description = "Name of the Talos/Kubernetes cluster."
  type        = string
  default     = "nova"
}

variable "cluster_vip" {
  description = "Virtual IP shared by all control plane nodes; used as the cluster API endpoint."
  type        = string
  default     = "10.205.10.10"
}

variable "nodes" {
  description = "Map of node hostname to its primary (bond0) IPv4 address."
  type        = map(string)
  default = {
    "nova-1" = "10.205.10.11"
    "nova-2" = "10.205.10.12"
    "nova-3" = "10.205.10.13"
    "nova-4" = "10.205.10.14"
  }

  validation {
    condition     = length(var.nodes) == 4
    error_message = "nodes.tf has exactly four talos_machine blocks (n0..n3); add/remove one there before changing the node count."
  }
}

variable "talos_version" {
  description = "Installed Talos version. Drives the installer image (talos_machine.image + UnattendedInstallConfig)."
  type        = string
  default     = "v1.14.4"

  validation {
    condition     = can(regex("^v\\d+\\.\\d+\\.\\d+$", var.talos_version))
    error_message = "talos_version must be a full release tag such as v1.14.4."
  }
}

variable "talos_config_contract" {
  description = "Machine-config contract (talos_machine_configuration / talos_machine_secrets talos_version). Pinned to the minor the cluster was created on; independent of talos_version."
  type        = string
  default     = "v1.14"

  validation {
    condition     = can(regex("^v\\d+\\.\\d+(\\.\\d+)?$", var.talos_config_contract))
    error_message = "talos_config_contract must look like v1.14."
  }
}

variable "talos_extensions" {
  description = "Official Talos system extensions baked into the installer image."
  type        = list(string)
  default     = []
}

variable "talos_platform" {
  description = "Image factory platform (metal for bare-metal nodes)."
  type        = string
  default     = "metal"
}

variable "talos_architecture" {
  description = "Image factory architecture."
  type        = string
  default     = "amd64"
}

variable "kubernetes_version" {
  description = "Kubernetes version. Bumping this triggers a rolling K8s upgrade via talos_cluster."
  type        = string
  default     = "v1.37.0"

  validation {
    condition     = can(regex("^v\\d+\\.\\d+\\.\\d+$", var.kubernetes_version))
    error_message = "kubernetes_version must be a full version tag such as v1.37.0."
  }
}

variable "pod_subnet" {
  description = "Pod CIDR; Cilium consumes this via Kubernetes IPAM."
  type        = string
  default     = "10.206.0.0/16"
}

variable "service_subnet" {
  description = "Service CIDR."
  type        = string
  default     = "10.207.0.0/16"
}

variable "node_subnet" {
  description = "Subnet the bond0 address lives on; constrains kubelet node-IP selection and provides the prefix length for the per-node static address."
  type        = string
  default     = "10.205.10.0/24"
}

variable "gateway" {
  description = "Default gateway on the node subnet."
  type        = string
  default     = "10.205.10.1"
}

variable "dns_servers" {
  description = "Upstream DNS servers configured on each node."
  type        = list(string)
  default     = ["10.205.10.1"]
}

variable "write_machine_configs" {
  description = "Write each node's rendered machine config to rendered/<node>.yaml (contains the full PKI)."
  type        = bool
  default     = false
}
