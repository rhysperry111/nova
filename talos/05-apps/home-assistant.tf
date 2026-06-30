################################################################################
# Home Assistant — runs as a KubeVirt VirtualMachine.
#
# Why a VM and not the container ("Home Assistant Container"): supervised
# add-ons (Z2M, ESPHome, Matter server, etc.) are only available on Home
# Assistant OS, which ships as a disk image — not a container. Running the
# OS image inside KubeVirt is the only way to get the full HA supervisor
# experience on Kubernetes.
#
# Disk: CDI imports haos_ova-<version>.qcow2.xz over HTTPS into a PVC backed
# by var.home_assistant_storage_class. CDI's importer detects the .xz
# compression and decompresses on the fly.
#
# USB passthrough: var.home_assistant_host_devices references resource names
# allowlisted on the KubeVirt CR via the platform stage's
# `kubevirt_permitted_usb_devices`. The two variables MUST agree — the VM
# spec's deviceName is what the device plugin advertises, and the operator
# only advertises names it has in its allowlist.
#
# Networking: pod-network masquerade. The VM gets a pod IP; external access
# is via the Service + Ingress below. mDNS-based device discovery from the
# LAN won't traverse this — swap to a bridge/multus interface if you need
# Home Assistant to discover devices via Avahi/SSDP/etc.
################################################################################

resource "kubernetes_namespace_v1" "home_assistant" {
  metadata {
    name = var.home_assistant_namespace
  }
}

locals {
  home_assistant_haos_url = "https://github.com/home-assistant/operating-system/releases/download/${var.home_assistant_os_version}/haos_ova-${var.home_assistant_os_version}.qcow2.xz"
}

resource "kubectl_manifest" "home_assistant_vm" {
  depends_on = [kubernetes_namespace_v1.home_assistant]

  yaml_body = yamlencode({
    apiVersion = "kubevirt.io/v1"
    kind       = "VirtualMachine"
    metadata = {
      name      = "home-assistant"
      namespace = kubernetes_namespace_v1.home_assistant.metadata[0].name
    }
    spec = {
      runStrategy = "Always"

      # CDI creates this PVC and imports the qcow2.xz into it the first time
      # the VM is brought up. Deleting the VM (with the default
      # dataVolumeTemplates GC) deletes the PVC — back up HA's snapshots
      # off-cluster if you care about losing config.
      dataVolumeTemplates = [{
        metadata = {
          name = "home-assistant-disk"
        }
        spec = {
          source = {
            http = {
              url = local.home_assistant_haos_url
            }
          }
          pvc = {
            accessModes = ["ReadWriteOnce"]
            resources = {
              requests = {
                storage = var.home_assistant_disk_size
              }
            }
            storageClassName = var.home_assistant_storage_class
          }
        }
      }]

      template = {
        metadata = {
          labels = {
            "kubevirt.io/domain" = "home-assistant"
            app                  = "home-assistant"
          }
        }
        spec = {
          domain = {
            machine = { type = "q35" }

            # HAOS images are GPT/UEFI — boot with OVMF, not SeaBIOS.
            firmware = {
              bootloader = {
                efi = {
                  secureBoot = false
                }
              }
            }

            cpu = {
              cores = var.home_assistant_cpu_cores
            }
            resources = {
              requests = {
                memory = var.home_assistant_memory
              }
            }
            devices = {
              disks = [{
                name = "rootdisk"
                disk = { bus = "virtio" }
              }]
              interfaces = [{
                name       = "default"
                masquerade = {}
                model      = "virtio"
              }]
              hostDevices = [for d in var.home_assistant_host_devices : {
                name       = d.name
                deviceName = d.device_name
              }]
            }
          }
          networks = [{
            name = "default"
            pod  = {}
          }]
          volumes = [{
            name = "rootdisk"
            dataVolume = {
              name = "home-assistant-disk"
            }
          }]
        }
      }
    }
  })

  server_side_apply = true
  wait              = false
}

resource "kubernetes_service_v1" "home_assistant" {
  metadata {
    name      = "home-assistant"
    namespace = kubernetes_namespace_v1.home_assistant.metadata[0].name
  }
  spec {
    selector = {
      "kubevirt.io/domain" = "home-assistant"
    }
    port {
      name        = "http"
      port        = 8123
      target_port = 8123
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_ingress_v1" "home_assistant" {
  metadata {
    name      = "home-assistant"
    namespace = kubernetes_namespace_v1.home_assistant.metadata[0].name
    annotations = {
      "cert-manager.io/cluster-issuer" = var.cluster_issuer_name
    }
  }

  spec {
    ingress_class_name = var.ingress_class_name

    tls {
      hosts       = ["home.${var.ingress_domain}"]
      secret_name = "home-assistant-tls"
    }

    rule {
      host = "home.${var.ingress_domain}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.home_assistant.metadata[0].name
              port {
                number = 8123
              }
            }
          }
        }
      }
    }
  }
}
