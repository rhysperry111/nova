resource "unifi_network" "bootstrap_network" {
  name       = var.network_name
  subnet     = var.network_cidr
  vlan       = var.network_vlan
  auto_scale = false

  multicast_dns     = false
  network_isolation = true
  internet_access   = true

  dhcp_server = {
    enabled = true
    start   = var.dhcp_start
    stop    = var.dhcp_stop
  }
}
