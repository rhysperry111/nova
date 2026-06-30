################################################################################
# Cilium BGP — peers with the UniFi gateway and advertises LB Service IPs.
#
# Mirrors net/bgp.tf. The ASNs, peer address, and advertised prefix MUST agree
# with the FRR config on the gateway:
#
#   Cilium ASN  64512  ← bgpInstances[*].localASN below
#   UniFi  ASN  64513  ← peers[*].peerASN below
#   Peer IP    10.205.10.1  (UniFi gateway, listening for 10.205.10.0/24)
#   Prefixes advertised: /32s out of var.lb_ipam_pool_cidrs
################################################################################

resource "kubectl_manifest" "cilium_bgp_peer_config" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2"
    kind       = "CiliumBGPPeerConfig"
    metadata = {
      name = "default-peer"
    }
    spec = {
      families = [
        {
          afi  = "ipv4"
          safi = "unicast"
          advertisements = {
            matchLabels = {
              "advertise" = "bgp"
            }
          }
        }
      ]
    }
  })
}

resource "kubectl_manifest" "cilium_bgp_advertisement" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2"
    kind       = "CiliumBGPAdvertisement"
    metadata = {
      name = "bgp-advertisements"
      labels = {
        "advertise" = "bgp"
      }
    }
    spec = {
      advertisements = [
        {
          advertisementType = "Service"
          service = {
            addresses = ["LoadBalancerIP"]
          }
          selector = {
            matchExpressions = [
              {
                key      = "somekey"
                operator = "NotIn"
                values   = ["never-match-this"]
              }
            ]
          }
        }
      ]
    }
  })
}

resource "kubectl_manifest" "cilium_bgp_cluster_config" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2"
    kind       = "CiliumBGPClusterConfig"
    metadata = {
      name = "default-bgp"
    }
    spec = {
      nodeSelector = {
        matchLabels = {
          "kubernetes.io/os" = "linux"
        }
      }
      bgpInstances = [
        {
          name     = "default"
          localASN = var.bgp_cilium_asn
          peers = [
            {
              name        = "router"
              peerASN     = var.bgp_unifi_asn
              peerAddress = var.bgp_router_ip
              peerConfigRef = {
                name = "default-peer"
              }
            }
          ]
        }
      ]
    }
  })
}
