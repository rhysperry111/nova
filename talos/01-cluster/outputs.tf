output "talosconfig_path" {
  description = "Path to the rendered talosconfig (for talosctl --talosconfig)."
  value       = local_sensitive_file.talosconfig.filename
}

output "kubeconfig_path" {
  description = "Path to the rendered kubeconfig (for kubectl --kubeconfig)."
  value       = local_sensitive_file.kubeconfig.filename
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint (control-plane VIP)."
  value       = "https://${var.cluster_vip}:6443"
}

output "nodes" {
  description = "Node name to IP mapping."
  value       = var.nodes
}

output "schematic_id" {
  description = "Image Factory schematic ID."
  value       = talos_image_factory_schematic.this.id
}

output "installer_image" {
  description = "Installer image used for first installs and upgrades."
  value       = local.installer_image
}

output "iso_url" {
  description = "Boot ISO matching the installer (for maintenance mode)."
  value       = data.talos_image_factory_urls.this.urls.iso
}

output "pxe_url" {
  description = "iPXE script URL matching the installer."
  value       = data.talos_image_factory_urls.this.urls.pxe
}
