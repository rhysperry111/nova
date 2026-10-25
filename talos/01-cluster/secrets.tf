resource "talos_machine_secrets" "this" {
  talos_version = var.talos_config_contract

  # Regenerating this mints a new PKI the running nodes won't trust. To
  # re-attach to empty state, import it instead (ADOPT.md).
  lifecycle {
    prevent_destroy = true
  }
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = values(var.nodes)
  nodes                = values(var.nodes)
}

ephemeral "talos_cluster_kubeconfig" "drain" {
  cluster_name    = var.cluster_name
  machine_secrets = talos_machine_secrets.this.machine_secrets
  endpoint        = "https://${var.cluster_vip}:6443"
}
