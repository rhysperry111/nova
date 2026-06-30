################################################################################
# BGP — UniFi side of the peering with Cilium.
################################################################################

resource "unifi_bgp" "cilium" {
  description      = "eBGP peering with Cilium nodes; LB IP advertisements"
  enabled          = true
  upload_file_name = "bgp.conf"

  config = <<-EOT
    router bgp ${var.bgp_unifi_asn}
      bgp router-id ${var.bgp_router_ip}
      no bgp ebgp-requires-policy
      no bgp default ipv4-unicast
      bgp graceful-restart

      neighbor CILIUM peer-group
      neighbor CILIUM remote-as ${var.bgp_cilium_asn}
      neighbor CILIUM description Cilium nodes
      neighbor CILIUM advertisement-interval 0

      bgp listen range ${var.node_subnet} peer-group CILIUM

      address-family ipv4 unicast
        neighbor CILIUM activate
        neighbor CILIUM soft-reconfiguration inbound
        ! Only accept /32 routes inside the LB IP pool. Belt-and-braces:
        ! Cilium should never advertise anything else, but this stops a
        ! misconfigured node from leaking arbitrary prefixes upstream.
        neighbor CILIUM prefix-list LB-IPS-IN in
      exit-address-family
    exit

    ip prefix-list LB-IPS-IN seq 5 permit ${var.lb_pool_cidr} ge 32 le 32
  EOT
}
