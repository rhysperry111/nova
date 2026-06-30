################################################################################
# Cilium — CNI + full kube-proxy replacement.
#
# The Talos config disables kube-proxy and sets cni.name=none, so Cilium is the
# only thing that lets pods talk to each other or to services. Install this
# before anything else in the cluster.
################################################################################

resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = var.cilium_version
  namespace  = "kube-system"
  wait       = false

  values = compact([
    yamlencode({
      ipam = {
        mode = "kubernetes"
      }
      kubeProxyReplacement = true
      externalIPs          = { enabled = true }
      bpf                  = { masquerade = true }

      # KubePrism is a Talos-managed local API proxy on every node. Pointing
      # Cilium at it removes the need to know the control-plane VIP from inside
      # the cluster and keeps Cilium healthy during control-plane churn.
      k8sServiceHost = "localhost"
      k8sServicePort = 7445

      # Talos manages cgroupv2; tell Cilium not to remount.
      cgroup = {
        autoMount = { enabled = false }
        hostRoot  = "/sys/fs/cgroup"
      }

      # Ingress: register the `cilium` IngressClass as the cluster default so
      # downstream charts don't have to set `ingressClassName` explicitly. One
      # shared LB Service (`cilium-ingress` in kube-system) fronts every
      # Ingress — cheaper than a Service per Ingress. The LB IP for that
      # Service is allocated by LB-IPAM (see cilium-bgp.tf) and announced to
      # the UniFi gateway via BGP.
      ingressController = {
        enabled          = true
        default          = true
        loadbalancerMode = "dedicated"
      }

      # BGP control plane: peers with the UniFi gateway so LB IPs allocated
      # by cilium-lb-ipam.tf are reachable from outside the node subnet.
      # Peer/advertisement config lives in cilium-bgp.tf; must agree with
      # net/bgp.tf.
      bgpControlPlane = {
        enabled = true
      }

      # Talos requires explicit caps for the agent and cleanup init container.
      securityContext = {
        capabilities = {
          ciliumAgent = [
            "CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK",
            "SYS_ADMIN", "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER",
            "SETGID", "SETUID",
          ]
          cleanCiliumState = ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
        }
      }

      dashboards = {
        enabled = true
        namespace = "monitoring"
      }

      hubble = {
        enabled = true
        relay   = {
          enabled = true
          prometheus = {
            enabled = true
            serviceMonitor = {
              enabled = true
            }
        }
        }
        ui = {
          enabled = true
          ingress = {
            enabled   = true
            className = var.ingress_class_name
            annotations = {
              "cert-manager.io/cluster-issuer" = var.cluster_issuer_name
            }
            hosts = ["hubble.${var.ingress_domain}"]
            tls = [{
              secretName = "hubble-ui-tls"
              hosts      = ["hubble.${var.ingress_domain}"]
            }]
          }
        }
        metrics = {
          enableOpenMetrics = true
          enabled = [
            "dns:query",
            "tcp",
            "icmp",
            "httpV2:exemplars=true;"
          ]
          serviceMonitor = {
            enabled = true
          }
          dashboards = {
            enabled = true
            namespace = "monitoring"
          }
        }
      }

      envoy = {
        enabled = true
        prometheus = {
          enabled = true
          serviceMonitor = {
            enabled = true
          }
        }
      }

      operator = {
        replicas = 2
        prometheus = {
          enabled = true
          serviceMonitor = {
            enabled = true
          }
        }
      }

      prometheus = {
        enabled = true
        serviceMonitor = {
          enabled = true
        }
      }
    }),
    var.cilium_values_override,
  ])
}
