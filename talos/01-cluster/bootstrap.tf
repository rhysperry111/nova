################################################################################
# Cluster-level bootstrap.
#
# `talos_cluster` bootstraps etcd on the first control-plane node and tracks
# the desired Kubernetes version. Bumping var.kubernetes_version triggers a
# rolling Kubernetes upgrade (control-plane components first, then kubelets,
# one node at a time — same flow as `talosctl upgrade-k8s`).
################################################################################

resource "talos_cluster" "this" {
  depends_on = [talos_machine.n0]

  node                 = local.ordered_nodes[0].ip
  endpoint             = local.ordered_nodes[0].ip
  client_configuration = talos_machine_secrets.this.client_configuration
  kubernetes_version   = var.kubernetes_version
  control_plane_nodes  = values(var.nodes)

  timeouts = {
    create = "2h"
    update = "2h"
  }
}

data "talos_cluster_health" "this" {
  depends_on = [
    talos_cluster.this,
    talos_machine.n0,
    talos_machine.n1,
    talos_machine.n2,
    talos_machine.n3,
  ]

  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = values(var.nodes)
  control_plane_nodes  = values(var.nodes)
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on = [talos_cluster.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.ordered_nodes[0].ip
  endpoint             = local.ordered_nodes[0].ip
}

resource "local_sensitive_file" "kubeconfig" {
  content         = talos_cluster_kubeconfig.this.kubeconfig_raw
  filename        = "${path.module}/kubeconfig"
  file_permission = "0600"
}

resource "local_sensitive_file" "talosconfig" {
  content         = data.talos_client_configuration.this.talos_config
  filename        = "${path.module}/talosconfig"
  file_permission = "0600"
}
