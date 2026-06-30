provider "unifi" {
  username = var.unifi_username
  password = var.unifi_password
  api_url  = var.unifi_api_url

  allow_insecure = true
}
