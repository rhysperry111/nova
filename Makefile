CONFIG    := nova.yaml
GENSCRIPT := generate-config.py
TOFU      := tofu
# Default: respect committed .terraform.lock.hcl pins. To intentionally bump
# providers within their version constraints: `make cluster INIT_FLAGS=-upgrade`.
INIT_FLAGS ?=

NET_DIR     := 00-net
CLUSTER_DIR := talos/01-cluster
PLATFORM_DIR := talos/02-platform
SERVICES_DIR := talos/03-platformservices
BACKUPS_DIR := talos/04-backups
APPS_DIR    := talos/05-apps


.PHONY: all generate \
        net cluster platform platformservices backups apps \
        destroy-net destroy-cluster destroy-platform destroy-platformservices \
        destroy-backups destroy-apps destroy-all clean help


help:
	@echo ""
	@echo "Nova homelab"
	@echo "============"
	@echo ""
	@echo "  make generate           Regenerate per-stage vars from nova.yaml"
	@echo ""
	@echo "  make net                Stage 0: UniFi network + BGP (00-net)"
	@echo "  make cluster            Stage 1: Talos OS + Kubernetes (01-cluster)"
	@echo "  make platform           Stage 2: Cilium + Rook-Ceph + KubeVirt (02-platform)"
	@echo "  make platformservices   Stage 3: cert-manager, external-dns, ArgoCD, monitoring (03)"
	@echo "  make backups            Stage 4: Velero + snapshot controller (04-backups)"
	@echo "  make apps               Stage 5: Immich, Jellyfin, Vaultwarden, HASS, ... (05-apps)"
	@echo "  make all                Run the full pipeline (net -> apps)"
	@echo ""
	@echo "  make destroy-apps       Tear down apps"
	@echo "  make destroy-all        Tear down everything (apps -> net)"
	@echo ""
	@echo "  make clean              Remove generated nova.auto.tfvars files"
	@echo ""
	@echo "  Before 'make cluster': boot the 4 nodes into Talos maintenance"
	@echo "  mode first — see talos/README.md."
	@echo ""


generate:
	@python3 $(GENSCRIPT) --config $(CONFIG)


all: net cluster platform platformservices backups apps

net: generate
	@echo "========== Stage 0: UniFi network + BGP =========="
	cd $(NET_DIR) && $(TOFU) init $(INIT_FLAGS) && $(TOFU) apply

cluster: generate
	@echo "========== Stage 1: Talos OS + Kubernetes =========="
	cd $(CLUSTER_DIR) && $(TOFU) init $(INIT_FLAGS) && $(TOFU) apply

platform: generate
	@echo "========== Stage 2: CNI (Cilium) + CSI (Rook-Ceph) =========="
	cd $(PLATFORM_DIR) && $(TOFU) init $(INIT_FLAGS) && $(TOFU) apply

platformservices: generate
	@echo "========== Stage 3: Platform services =========="
	cd $(SERVICES_DIR) && $(TOFU) init $(INIT_FLAGS) && $(TOFU) apply

backups: generate
	@echo "========== Stage 4: Backups (Velero -> R2) =========="
	cd $(BACKUPS_DIR) && $(TOFU) init $(INIT_FLAGS) && $(TOFU) apply

apps: generate
	@echo "========== Stage 5: Apps =========="
	cd $(APPS_DIR) && $(TOFU) init $(INIT_FLAGS) && $(TOFU) apply


destroy-all: destroy-apps destroy-backups destroy-platformservices destroy-platform destroy-cluster destroy-net

destroy-apps:
	@echo "========== Destroying Stage 5: Apps =========="
	cd $(APPS_DIR) && $(TOFU) destroy

destroy-backups:
	@echo "========== Destroying Stage 4: Backups =========="
	cd $(BACKUPS_DIR) && $(TOFU) destroy

destroy-platformservices:
	@echo "========== Destroying Stage 3: Platform services =========="
	cd $(SERVICES_DIR) && $(TOFU) destroy

destroy-platform:
	@echo "========== Destroying Stage 2: CNI + CSI =========="
	cd $(PLATFORM_DIR) && $(TOFU) destroy

destroy-cluster:
	@echo "========== Destroying Stage 1: Talos cluster =========="
	cd $(CLUSTER_DIR) && $(TOFU) destroy

destroy-net:
	@echo "========== Destroying Stage 0: UniFi network + BGP =========="
	cd $(NET_DIR) && $(TOFU) destroy


clean:
	rm -f $(NET_DIR)/nova.auto.tfvars
	rm -f $(CLUSTER_DIR)/nova.auto.tfvars
	rm -f $(PLATFORM_DIR)/nova.auto.tfvars
	rm -f $(SERVICES_DIR)/nova.auto.tfvars
	rm -f $(BACKUPS_DIR)/nova.auto.tfvars
	rm -f $(APPS_DIR)/nova.auto.tfvars
	@echo "Clean."
