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
