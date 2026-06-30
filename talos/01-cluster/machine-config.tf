locals {
  # Prefix length pulled off var.node_subnet so each node gets `IP/PREFIX`.
  node_prefix_length = split("/", var.node_subnet)[1]

  # Deterministic node ordering: sort by hostname so the upgrade chain is
  # stable across plans regardless of map iteration order.
  ordered_nodes = [for name in sort(keys(var.nodes)) : {
    name = name
    ip   = var.nodes[name]
  }]
}

# Image factory: register a schematic (optionally with extensions) and resolve
# the installer image URL Talos will use for installs and in-place upgrades.
data "talos_image_factory_extensions_versions" "this" {
  count         = length(var.talos_extensions) > 0 ? 1 : 0
  talos_version = var.talos_version
  filters = {
    names = var.talos_extensions
  }
}

resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = length(var.talos_extensions) > 0 ? data.talos_image_factory_extensions_versions.this[0].extensions_info.*.name : []
      }
    }
  })
}

data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = var.talos_platform
  architecture  = var.talos_architecture
}

# Per-node controlplane config (each is otherwise identical; only the hostname
# patch differs).
data "talos_machine_configuration" "controlplane" {
  for_each = var.nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = "https://${var.cluster_vip}:6443"
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version

  # Don't render commented-out examples / docs into the base config. Without
  # this the default HostnameConfig + ResolverConfig examples (with
  # auto: stable, 1.1.1.1, etc.) get emitted and merge weirdly with our
  # patches.
  docs     = false
  examples = false

  config_patches = [
    templatefile("${path.module}/patches/common.yaml", {
      cluster_vip    = var.cluster_vip
      node_subnet    = var.node_subnet
      pod_subnet     = var.pod_subnet
      service_subnet = var.service_subnet
      node_cidr      = "${each.value}/${local.node_prefix_length}"
      gateway        = var.gateway
      dns_servers    = var.dns_servers
      hostname       = each.key
    }),
    yamlencode({
      cluster = {
        allowSchedulingOnControlPlanes = true
      }
    }),
  ]
}
