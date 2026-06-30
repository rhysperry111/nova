################################################################################
# Cilium LB-IPAM — pool of external IPs handed out to LoadBalancer Services.
#
# The pool only matters once the BGP control plane is up and advertising these
# IPs (see cilium-bgp.tf). The /16 here must also be permitted by the inbound
# prefix-list on the UniFi side in net/bgp.tf.
################################################################################

resource "kubectl_manifest" "cilium_lb_ip_pool" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2"
    kind       = "CiliumLoadBalancerIPPool"
    metadata = {
      name = "default-pool"
    }
    spec = {
      blocks = [for cidr in var.lb_ipam_pool_cidrs : { cidr = cidr }]
    }
  })
}
