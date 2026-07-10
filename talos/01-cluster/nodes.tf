################################################################################
# Per-node talos_machine resources.
#
# Each resource keeps the node's machine config + OS image in sync. Drift on
# either side (config edited, var.talos_version bumped) is reconciled on the
# next `terraform apply`.
#
# Resources are chained via `depends_on` so that:
#   - initial install proceeds one node at a time, and
#   - in-place OS upgrades (triggered by changing the installer image) drain,
#     reboot, and rejoin one node before the next starts — preventing parallel
#     downtime / quorum loss.
#
# `drain_on_upgrade = true` cordons + drains the node before the reboot. Rook
# PDBs hold the drain back if it would degrade Ceph beyond what we allow (see
# cluster-resources.tf), so the chain pace is set by Ceph recovery in practice.
################################################################################

locals {
  installer_image = data.talos_image_factory_urls.this.urls.installer
}

resource "talos_machine" "n0" {
  node                  = local.ordered_nodes[0].ip
  endpoint              = local.ordered_nodes[0].ip
  client_configuration  = talos_machine_secrets.this.client_configuration
  machine_configuration = data.talos_machine_configuration.controlplane[local.ordered_nodes[0].name].machine_configuration
  image                 = local.installer_image
  drain_on_upgrade      = true

  timeouts = {
    create = "2h"
    update = "2h"
    delete = "2h"
  }
}

resource "talos_machine" "n1" {
  depends_on = [talos_machine.n0]

  node                  = local.ordered_nodes[1].ip
  endpoint              = local.ordered_nodes[1].ip
  client_configuration  = talos_machine_secrets.this.client_configuration
  machine_configuration = data.talos_machine_configuration.controlplane[local.ordered_nodes[1].name].machine_configuration
  image                 = local.installer_image
  drain_on_upgrade      = true

  timeouts = {
    create = "2h"
    update = "2h"
    delete = "2h"
  }
}

resource "talos_machine" "n2" {
  depends_on = [talos_machine.n1]

  node                  = local.ordered_nodes[2].ip
  endpoint              = local.ordered_nodes[2].ip
  client_configuration  = talos_machine_secrets.this.client_configuration
  machine_configuration = data.talos_machine_configuration.controlplane[local.ordered_nodes[2].name].machine_configuration
  image                 = local.installer_image
  drain_on_upgrade      = true

  timeouts = {
    create = "2h"
    update = "2h"
    delete = "2h"
  }
}

resource "talos_machine" "n3" {
  depends_on = [talos_machine.n2]

  node                  = local.ordered_nodes[3].ip
  endpoint              = local.ordered_nodes[3].ip
  client_configuration  = talos_machine_secrets.this.client_configuration
  machine_configuration = data.talos_machine_configuration.controlplane[local.ordered_nodes[3].name].machine_configuration
  image                 = local.installer_image
  drain_on_upgrade      = true

  timeouts = {
    create = "2h"
    update = "2h"
    delete = "2h"
  }
}
