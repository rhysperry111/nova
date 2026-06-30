provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "kubectl" {
  config_path      = var.kubeconfig_path
  load_config_file = true
}

provider "helm" {
  kubernetes = {
    config_path = var.kubeconfig_path
  }
}
