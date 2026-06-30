#!/usr/bin/env python3

import argparse
import os
import sys

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required (pip install pyyaml).", file=sys.stderr)
    sys.exit(1)


def load_config(path: str) -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


def write(path: str, content: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content)
    print(f"  wrote {path}")


def _scalar(value) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    return f'"{value}"'


def tfvars_line(key: str, value) -> str:
    if isinstance(value, list):
        items = ", ".join(_scalar(v) for v in value)
        return f"{key} = [{items}]"
    return f"{key} = {_scalar(value)}"


def tfvars_map(key: str, mapping: dict) -> str:
    lines = [f"{key} = {{"]
    for k, v in mapping.items():
        lines.append(f'  "{k}" = {_scalar(v)}')
    lines.append("}")
    return "\n".join(lines)


HEADER = "# Auto-generated from nova.yaml by generate-config.py - do not edit.\n"


def generate_net(cfg: dict, root: str) -> None:
    net = cfg["net"]
    netw = cfg["network"]
    bgp = cfg["bgp"]

    lines = [
        HEADER,
        "# UniFi controller",
        tfvars_line("unifi_api_url", net["unifi_api_url"]),
        "",
        "# Nova network",
        tfvars_line("network_name", net["network_name"]),
        tfvars_line("network_cidr", net["network_cidr"]),
        tfvars_line("network_vlan", net["vlan"]),
        tfvars_line("dhcp_start", net["dhcp_start"]),
        tfvars_line("dhcp_stop", net["dhcp_stop"]),
        "",
        "# BGP (mirror of platform/cilium-bgp.tf)",
        tfvars_line("node_subnet", netw["node_subnet"]),
        tfvars_line("lb_pool_cidr", netw["lb_pool_cidr"]),
        tfvars_line("bgp_cilium_asn", bgp["cilium_asn"]),
        tfvars_line("bgp_unifi_asn", bgp["unifi_asn"]),
        tfvars_line("bgp_router_ip", bgp["router_ip"]),
    ]
    write(os.path.join(root, "00-net", "nova.auto.tfvars"), "\n".join(lines) + "\n")


def generate_cluster(cfg: dict, root: str) -> None:
    c = cfg["cluster"]
    netw = cfg["network"]
    v = cfg["versions"]

    lines = [
        HEADER,
        "# Cluster identity",
        tfvars_line("cluster_name", c["name"]),
        tfvars_line("cluster_vip", c["vip"]),
        "",
        "# Node inventory",
        tfvars_map("nodes", cfg["nodes"]),
        "",
        "# Versions",
        tfvars_line("talos_version", v["talos"]),
        tfvars_line("kubernetes_version", v["kubernetes"]),
        "",
        "# Networking",
        tfvars_line("pod_subnet", netw["pod_subnet"]),
        tfvars_line("service_subnet", netw["service_subnet"]),
        tfvars_line("node_subnet", netw["node_subnet"]),
        tfvars_line("gateway", netw["gateway"]),
        tfvars_line("dns_servers", netw["dns_servers"]),
    ]
    write(os.path.join(root, "talos", "01-cluster", "nova.auto.tfvars"), "\n".join(lines) + "\n")


def generate_platform(cfg: dict, root: str) -> None:
    ing = cfg["ingress"]
    netw = cfg["network"]
    bgp = cfg["bgp"]
    v = cfg["versions"]

    lines = [
        HEADER,
        "# Ingress (cross-cutting)",
        tfvars_line("ingress_domain", ing["domain"]),
        tfvars_line("ingress_class_name", ing["class_name"]),
        tfvars_line("cluster_issuer_name", ing["cluster_issuer"]),
        "",
        "# LB-IPAM + BGP (must agree with 00-net)",
        tfvars_line("lb_ipam_pool_cidrs", [netw["lb_pool_cidr"]]),
        tfvars_line("bgp_cilium_asn", bgp["cilium_asn"]),
        tfvars_line("bgp_unifi_asn", bgp["unifi_asn"]),
        tfvars_line("bgp_router_ip", bgp["router_ip"]),
        "",
        "# Chart / operator versions",
        tfvars_line("cilium_version", v["cilium"]),
        tfvars_line("rook_ceph_version", v["rook_ceph"]),
        tfvars_line("ceph_csi_drivers_version", v["ceph_csi_drivers"]),
        tfvars_line("metrics_server_version", v["metrics_server"]),
        tfvars_line("kubevirt_version", v["kubevirt"]),
        tfvars_line("cdi_version", v["cdi"]),
        tfvars_line("gateway_api_version", v["gateway_api"]),
    ]
    write(os.path.join(root, "talos", "02-platform", "nova.auto.tfvars"), "\n".join(lines) + "\n")


def generate_platformservices(cfg: dict, root: str) -> None:
    ing = cfg["ingress"]
    tls = cfg["tls"]
    edns = cfg["external_dns"]
    v = cfg["versions"]

    lines = [
        HEADER,
        "# Ingress (cross-cutting)",
        tfvars_line("ingress_domain", ing["domain"]),
        tfvars_line("ingress_class_name", ing["class_name"]),
        tfvars_line("cluster_issuer_name", ing["cluster_issuer"]),
        "",
        "# cert-manager / ACME",
        tfvars_line("acme_email", tls["acme_email"]),
        tfvars_line("acme_server", tls["acme_server"]),
        tfvars_line("acme_profile", tls["acme_profile"]),
        "",
        "# external-dns",
        tfvars_line("external_dns_domain_filters", edns["domain_filters"]),
        tfvars_line("external_dns_txt_owner_id", edns["txt_owner_id"]),
        tfvars_line("external_dns_policy", edns["policy"]),
        tfvars_line("unifi_api_url", edns["unifi_api_url"]),
        "",
        "# Chart / image versions",
        tfvars_line("cert_manager_version", v["cert_manager"]),
        tfvars_line("external_dns_version", v["external_dns"]),
        tfvars_line("external_dns_unifi_webhook_version", v["external_dns_unifi_webhook"]),
        tfvars_line("argocd_version", v["argocd"]),
        tfvars_line("kube_prometheus_stack_version", v["kube_prometheus_stack"]),
        tfvars_line("registry_image_tag", v["registry_image_tag"]),
        tfvars_line("cnpg_operator_version", v["cnpg_operator"]),
    ]
    write(os.path.join(root, "talos", "03-platformservices", "nova.auto.tfvars"), "\n".join(lines) + "\n")


def generate_backups(cfg: dict, root: str) -> None:
    r2 = cfg["r2"]
    v = cfg["versions"]

    lines = [
        HEADER,
        "# Cloudflare R2 (non-secret identifiers; keys -> secrets.auto.tfvars)",
        tfvars_line("r2_account_id", r2["account_id"]),
        tfvars_line("r2_bucket", r2["bucket"]),
        "",
        "# Versions (live values — were ahead of variables.tf defaults)",
        tfvars_line("velero_chart_version", v["velero_chart"]),
        tfvars_line("velero_plugin_for_aws_image", v["velero_plugin_for_aws_image"]),
        tfvars_line("snapshot_controller_chart_version", v["snapshot_controller"]),
    ]
    write(os.path.join(root, "talos", "04-backups", "nova.auto.tfvars"), "\n".join(lines) + "\n")


def generate_apps(cfg: dict, root: str) -> None:
    ing = cfg["ingress"]
    v = cfg["versions"]

    lines = [
        HEADER,
        "# Ingress (cross-cutting)",
        tfvars_line("ingress_domain", ing["domain"]),
        tfvars_line("ingress_class_name", ing["class_name"]),
        tfvars_line("cluster_issuer_name", ing["cluster_issuer"]),
        "",
        "# App image / chart versions",
        tfvars_line("home_assistant_os_version", v["home_assistant_os"]),
        tfvars_line("immich_chart_version", v["immich_chart"]),
        tfvars_line("immich_image_tag", v["immich_image_tag"]),
        tfvars_line("immich_db_image", v["immich_db_image"]),
        tfvars_line("cnpg_cluster_chart_version", v["cnpg_cluster_chart"]),
        tfvars_line("vaultwarden_chart_version", v["vaultwarden_chart"]),
        tfvars_line("vaultwarden_image_tag", v["vaultwarden_image_tag"]),
        tfvars_line("jellyfin_image", v["jellyfin_image"]),
    ]
    write(os.path.join(root, "talos", "05-apps", "nova.auto.tfvars"), "\n".join(lines) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate per-stage tfvars from nova.yaml")
    parser.add_argument("--config", default="nova.yaml", help="Path to central config (default: nova.yaml)")
    args = parser.parse_args()

    root = os.path.dirname(os.path.abspath(args.config))
    cfg = load_config(args.config)

    print("Generating per-stage variable files from nova.yaml...")
    generate_net(cfg, root)
    generate_cluster(cfg, root)
    generate_platform(cfg, root)
    generate_platformservices(cfg, root)
    generate_backups(cfg, root)
    generate_apps(cfg, root)
    print("Done.")


if __name__ == "__main__":
    main()
