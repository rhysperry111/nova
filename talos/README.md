# nova talos cluster

Terraform that provisions a 4-node Talos cluster on the Nova network
(`10.205.10.0/24`, VLAN 10 — see [../00-net/](../00-net/)). All four nodes run as
combined control plane + worker. Cilium replaces kube-proxy entirely.
Rook-Ceph takes the two SATA SSDs on each node for CSI-backed block +
filesystem storage. On top of that: Vault, cert-manager, ExternalDNS,
KubeVirt + CDI, and ArgoCD.

The terraform is split into **five numbered stages** under `talos/` (plus the
UniFi `00-net` stage at the repo root), each its own Terraform workspace (own
state, own `tofu init`, own `tofu apply`). Stages are explicitly ordered — each
one depends only on artefacts the previous stage has already written to disk —
so there is no provider chicken-and-egg problem and no `-target` gymnastics.

Orchestration, the central `nova.yaml` config, and secret handling are
documented in [../APPROACH.md](../APPROACH.md). Day-to-day you drive everything
from the repo-root `Makefile` (`make help`); the manual per-stage commands below
still work.

```
.
├── nova.yaml             ← central config (versions + cross-cutting)
├── Makefile              ← orchestration (make all / make <stage>)
├── 00-net/               ← Stage 0: UniFi network + BGP (repo root, not under talos/)
└── talos/
    ├── README.md             ← you are here
    ├── 01-cluster/           ← Stage 1: Talos OS + Kubernetes
    ├── 02-platform/          ← Stage 2: CNI (Cilium) + CSI (Rook-Ceph)
    ├── 03-platformservices/  ← Stage 3: cert-manager, external-dns, ArgoCD, kube-prometheus-stack
    ├── 04-backups/           ← Stage 4: Velero → Cloudflare R2 (cluster state + Ceph PV data)
    └── 05-apps/              ← Stage 5: Vault, KubeVirt-based VMs, Immich, Vaultwarden, ...
```

## How the stages talk to each other

Stage 1 writes two files into its own directory:

- [01-cluster/kubeconfig](01-cluster/) — used by stages 2–5 to reach the API
- [01-cluster/talosconfig](01-cluster/) — used by you to reach Talos directly

Stages 2–5 reference `../01-cluster/kubeconfig` via the
`kubernetes`, `helm`, and `kubectl` providers' `config_path`. That's the
entirety of the inter-stage coupling. No `terraform_remote_state`, no shared
backend, no secrets passed around — just a kubeconfig file on disk.

The path is exposed as `var.kubeconfig_path` in every downstream stage, so if you ever
move state out of these local directories (CI runners, remote backends),
override it.

## Apply order

```sh
# Everything, in order, from the repo root. `make` regenerates each stage's
# nova.auto.tfvars from nova.yaml before applying it.
make all

# …or one stage at a time (each depends on `make generate`):
make net               # Stage 0: 00-net           — UniFi network + BGP
make cluster           # Stage 1: talos/01-cluster — Talos OS + Kubernetes
make platform          # Stage 2: talos/02-platform
make platformservices  # Stage 3: talos/03-platformservices
make backups           # Stage 4: talos/04-backups — recommended before apps
make apps              # Stage 5: talos/05-apps

# Manual equivalent for a single stage (skips generation — run `make generate`
# yourself if nova.yaml changed):
cd talos/01-cluster && tofu init && tofu apply
```

Stage 0 (`00-net`) provisions the UniFi VLAN + DHCP + BGP peering the nodes
live on; it must exist before the nodes can get addresses.

Each stage is idempotent and can be re-applied independently. Re-running
stage 1 on an existing cluster is the upgrade path (see "Day 2" below); it
won't touch what stages 2/3 created.

## What's in each stage

### [01-cluster/](01-cluster/) — OS + Kubernetes

| File | What it does |
| --- | --- |
| [versions.tf](01-cluster/versions.tf) | `siderolabs/talos` 0.12-alpha + `hashicorp/local` |
| [variables.tf](01-cluster/variables.tf) | Cluster name, VIP, node IPs, gateway, DNS, Talos/K8s versions, subnets, extensions |
| [providers.tf](01-cluster/providers.tf) | `provider "talos"` (no kubeconfig — cluster doesn't exist yet) |
| [secrets.tf](01-cluster/secrets.tf) | `talos_machine_secrets` + client config |
| [machine-config.tf](01-cluster/machine-config.tf) | Image factory schematic + URLs + per-node machine config |
| [nodes.tf](01-cluster/nodes.tf) | Four `talos_machine` resources chained via `depends_on` (rolling upgrades) |
| [bootstrap.tf](01-cluster/bootstrap.tf) | `talos_cluster` (etcd bootstrap + K8s version), kubeconfig, local files |
| [outputs.tf](01-cluster/outputs.tf) | Paths to talosconfig/kubeconfig, endpoint |
| [patches/common.yaml](01-cluster/patches/common.yaml) | NVMe install, LACP bond, VIP, Rook mounts, CNI=none, kube-proxy=disabled |

State here is the whole Talos cluster: machine secrets, every node's running
OS image, every node's applied machine config, K8s version. Bumping
`var.talos_version` or `var.kubernetes_version` and re-applying is the
upgrade.

### [02-platform/](02-platform/) — CNI + CSI

| File | What it does |
| --- | --- |
| [versions.tf](02-platform/versions.tf) | `hashicorp/kubernetes` + `hashicorp/helm` |
| [variables.tf](02-platform/variables.tf) | Chart versions, `kubeconfig_path`, `*_values_override` |
| [providers.tf](02-platform/providers.tf) | `kubernetes` + `helm` from `var.kubeconfig_path` |
| [cilium.tf](02-platform/cilium.tf) | Cilium with `kubeProxyReplacement: true`, KubePrism, Hubble |
| [rook-ceph.tf](02-platform/rook-ceph.tf) | Rook operator + cluster, `ceph-block` and `ceph-filesystem` storage classes |

This stage is "everything you need before a workload can actually run":
networking and storage. Nothing here writes outside the cluster.

### [04-backups/](04-backups/) — Velero → Cloudflare R2

| File | What it does |
| --- | --- |
| [versions.tf](04-backups/versions.tf) | `kubernetes` + `helm` + `kubectl` provider pins |
| [providers.tf](04-backups/providers.tf) | All three providers from `var.kubeconfig_path` |
| [variables.tf](04-backups/variables.tf) | R2 creds, chart versions, schedules, retention, excluded namespaces |
| [snapshot-controller.tf](04-backups/snapshot-controller.tf) | kubernetes-csi/external-snapshotter — CRDs + controller for `VolumeSnapshot` reconciliation |
| [snapshot-classes.tf](04-backups/snapshot-classes.tf) | `VolumeSnapshotClass` for `ceph-block` (RBD) + `ceph-filesystem` (CephFS) |
| [velero.tf](04-backups/velero.tf) | Velero namespace + R2 credentials Secret + Helm release + `Schedule` CRs |

Two schedules ship by default: a 6-hourly metadata-only backup (cheap,
7-day retention) and a nightly full backup that snapshots every PV via CSI
and ships the data to R2 with the data mover (30-day retention).
[04-backups/README.md](04-backups/README.md) is the runbook for single-PVC,
single-namespace, and full-cluster-loss recoveries.

## Getting nodes ready (before stage 1)

Talos nodes need to be booted into **maintenance mode** before stage 1 can
push configs at them. Maintenance mode is the default state of a freshly
booted Talos installer — there is no machine config on the install disk
yet, so the API listens on the node's primary IP without auth and accepts a
single config payload.

1. **Boot each of the 4 nodes** from a Talos ISO matching
   `var.talos_version`. Easiest path: from `01-cluster/`, run
   `tofu apply -target=talos_image_factory_schematic.this -target=data.talos_image_factory_urls.this`,
   then look at the ISO URL in the data source output and PXE / USB / IPMI-boot
   from it. You can also grab a vanilla ISO from
   [factory.talos.dev](https://factory.talos.dev) if you don't have
   extensions configured yet.

2. **Don't run `talosctl apply-config` by hand** — leave the nodes in
   maintenance mode. The `talos_machine` resources in stage 1 will apply the
   config.

3. **Confirm the bond will come up.** In maintenance mode the installer
   falls back to DHCP on each physical NIC; the LACP bond is created the
   moment Terraform applies the config. The upstream Unifi switch ports
   for each node must already be configured as an LACP port-channel.

4. **Get each node onto its target IP for the first boot.** Stage 1 stamps
   a static `bond0` address from `var.nodes` (plus `var.gateway` and
   `var.dns_servers` from [01-cluster/variables.tf](01-cluster/variables.tf)) onto
   each node, so after the first apply the nodes are statically addressed
   and never DHCP again. But for the *first* apply, Terraform needs to
   reach the node at that IP — which means the maintenance-mode boot has
   to land on the same address. Two ways:

   - **One-time DHCP reservation (easiest):** reserve each node's first
     physical NIC MAC to the matching `nodes` IP in Unifi. In maintenance
     mode the node DHCPs that IP on a single NIC; Terraform applies the
     static config; on reboot the bond comes up with the same IP and the
     reservation never matters again. (You can find each NIC's MAC with
     `talosctl -e <unreserved-ip> --insecure get links` after a no-reservation
     boot, or read it off the chassis stickers.)
   - **Kernel cmdline (no DHCP):** boot the ISO with
     `ip=10.205.10.11::10.205.10.1:255.255.255.0:nova-1::off` (etc.) as a
     kernel argument. The installer comes up with that static IP from the
     start. Means per-node ISO/PXE configs but no Unifi work.

5. **Verify reachability in maintenance mode:**

   ```sh
   talosctl -e 10.205.10.11 -n 10.205.10.11 --insecure version
   ```

## Day 2: upgrades and config changes

All three of these run from `01-cluster/` and are a single `tofu apply`:

### Talos OS upgrade

Bump `var.talos_version`. The image factory data source resolves a new
installer URL, every `talos_machine.nN.image` changes, and the chain
re-applies one node at a time with `drain_on_upgrade = true` (cordons,
drains respecting PDBs, A/B-upgrades, reboots, waits for ready, uncordons).
Rook's auto-managed PDBs hold the drain back if Ceph would lose redundancy
— see [02-platform/rook-ceph.tf](02-platform/rook-ceph.tf).

### Kubernetes upgrade

Bump `var.kubernetes_version`. `talos_cluster.this` picks up the drift and
runs the same rolling upgrade `talosctl upgrade-k8s` would — control plane
first, then kubelets, one node at a time.

### Machine config changes

Edit [01-cluster/patches/common.yaml](01-cluster/patches/common.yaml) (or anything
else feeding `data.talos_machine_configuration.controlplane`). The provider
hashes the applied config on each refresh; drift triggers a re-apply
through `talos_machine`, riding the same chained drain → reboot → rejoin
flow.