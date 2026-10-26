#!/usr/bin/env bash
# ==============================================================================
# 00-env.sh
# Dynamic Environment Discovery & Configuration for BTN GKE Island-Mode PoC
#
# Usage:
#   source ./scripts/00-env.sh
#
# All variables are dynamically discovered from your active `gcloud config` or
# can be overridden via environment variables (or a local `.env` file) before
# running `01-deploy-all.sh`, `02-verify-all.sh`, or `03-cleanup-all.sh`.
# ==============================================================================

export PATH="$HOME/google-cloud-sdk/bin:$PATH:/usr/local/bin:/usr/bin:/bin"

ENV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$ENV_SCRIPT_DIR/.." && pwd)"

# Load optional local .env overrides if present
if [[ -f "$REPO_ROOT/.env" ]]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
fi

# ------------------------------------------------------------------------------
# 1. Dynamic GCP Project, Region, and Zone Discovery
# ------------------------------------------------------------------------------
GCLOUD_ACTIVE_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
if [[ "$GCLOUD_ACTIVE_PROJECT" == "(unset)" ]]; then
  GCLOUD_ACTIVE_PROJECT=""
fi

export PROJECT_ID="${PROJECT_ID:-${PROJECT:-$GCLOUD_ACTIVE_PROJECT}}"
export PROJECT="$PROJECT_ID"

if [[ -z "$PROJECT_ID" ]]; then
  echo "ERROR: No GCP Project ID detected." >&2
  echo "Please set your active GCP project using one of the following methods:" >&2
  echo "  1) gcloud config set project YOUR_PROJECT_ID" >&2
  echo "  2) export PROJECT_ID=YOUR_PROJECT_ID" >&2
  return 1 2>/dev/null || exit 1
fi

GCLOUD_ACTIVE_REGION="$(gcloud config get-value compute/region 2>/dev/null || true)"
if [[ -z "$GCLOUD_ACTIVE_REGION" || "$GCLOUD_ACTIVE_REGION" == "(unset)" ]]; then
  GCLOUD_ACTIVE_REGION="asia-southeast2"
fi
export REGION="${REGION:-$GCLOUD_ACTIVE_REGION}"

GCLOUD_ACTIVE_ZONE="$(gcloud config get-value compute/zone 2>/dev/null || true)"
if [[ -z "$GCLOUD_ACTIVE_ZONE" || "$GCLOUD_ACTIVE_ZONE" == "(unset)" ]]; then
  GCLOUD_ACTIVE_ZONE="${REGION}-a"
fi
export ZONE="${ZONE:-$GCLOUD_ACTIVE_ZONE}"

# ------------------------------------------------------------------------------
# 2. VPC & Subnet Names (Customizable via Environment Variables)
# ------------------------------------------------------------------------------
export GCP_VPC="${GCP_VPC:-btn-gcp-vpc}"
export GKE_SUBNET="${GKE_SUBNET:-btn-gke-subnet}"
export PRIVATE_NAT_SUBNET="${PRIVATE_NAT_SUBNET:-btn-private-nat-subnet}"
export PROXY_ONLY_SUBNET="${PROXY_ONLY_SUBNET:-btn-proxy-only-subnet}"

export ALICLOUD_VPC="${ALICLOUD_VPC:-sim-alicloud-vpc}"
export ALICLOUD_SUBNET="${ALICLOUD_SUBNET:-sim-alicloud-subnet}"

# ------------------------------------------------------------------------------
# 3. IP Addressing Plan (Customizable via Environment Variables)
# ------------------------------------------------------------------------------
export GKE_NODE_CIDR="${GKE_NODE_CIDR:-10.2.2.0/24}"
export GKE_POD_RANGE_NAME="${GKE_POD_RANGE_NAME:-gke-pods}"
export GKE_POD_CIDR="${GKE_POD_CIDR:-10.2.16.0/23}"
export GKE_SVC_RANGE_NAME="${GKE_SVC_RANGE_NAME:-gke-services}"
export GKE_SVC_CIDR="${GKE_SVC_CIDR:-10.2.18.0/23}"
export PROXY_ONLY_CIDR="${PROXY_ONLY_CIDR:-10.2.20.0/23}"

# Private NAT /29 subnet (minimum prefix length required by GCP for PRIVATE_NAT)
export PRIVATE_NAT_CIDR="${PRIVATE_NAT_CIDR:-10.2.99.96/29}"
# Default expected active /32 SNAT IP (auto-verified/updated during deployment)
export PRIVATE_NAT_SNAT_IP="${PRIVATE_NAT_SNAT_IP:-10.2.99.99}"
export PRIVATE_NAT_BGP_VIP="${PRIVATE_NAT_BGP_VIP:-${PRIVATE_NAT_SNAT_IP}/32}"

# Inbound Regional Internal Application Load Balancer /32 VIP
export ILB_VIP_NAME="${ILB_VIP_NAME:-btn-gke-ilb-vip}"
export ILB_VIP_ADDRESS="${ILB_VIP_ADDRESS:-10.2.2.200}"
export ILB_VIP_CIDR="${ILB_VIP_CIDR:-${ILB_VIP_ADDRESS}/32}"

# Simulated Alibaba Cloud Subnet & Test VM IP
export ALICLOUD_SUBNET_CIDR="${ALICLOUD_SUBNET_CIDR:-192.168.1.0/24}"
export ALICLOUD_VM_NAME="${ALICLOUD_VM_NAME:-sim-alicloud-vm}"
export ALICLOUD_VM_IP="${ALICLOUD_VM_IP:-192.168.1.10}"
export ALICLOUD_VM_MACHINE_TYPE="${ALICLOUD_VM_MACHINE_TYPE:-e2-micro}"

# ------------------------------------------------------------------------------
# 4. HA VPN, Cloud Router, BGP ASNs & Private NAT Gateway Names
# ------------------------------------------------------------------------------
export GCP_ROUTER="${GCP_ROUTER:-btn-gcp-router}"
export GCP_ASN="${GCP_ASN:-65001}"
export ALICLOUD_ROUTER="${ALICLOUD_ROUTER:-sim-alicloud-router}"
export ALICLOUD_ASN="${ALICLOUD_ASN:-65002}"

export GCP_VPN_GW="${GCP_VPN_GW:-btn-gcp-havpn}"
export ALICLOUD_VPN_GW="${ALICLOUD_VPN_GW:-sim-alicloud-havpn}"
export GCP_TUN0="${GCP_TUN0:-btn-gcp-to-alicloud-tun0}"
export GCP_TUN1="${GCP_TUN1:-btn-gcp-to-alicloud-tun1}"
export ALICLOUD_TUN0="${ALICLOUD_TUN0:-sim-alicloud-to-gcp-tun0}"
export ALICLOUD_TUN1="${ALICLOUD_TUN1:-sim-alicloud-to-gcp-tun1}"

export BGP_TUN0_GCP_IP="${BGP_TUN0_GCP_IP:-169.254.0.1}"
export BGP_TUN0_ALI_IP="${BGP_TUN0_ALI_IP:-169.254.0.2}"
export BGP_TUN1_GCP_IP="${BGP_TUN1_GCP_IP:-169.254.1.1}"
export BGP_TUN1_ALI_IP="${BGP_TUN1_ALI_IP:-169.254.1.2}"
export VPN_SHARED_SECRET="${VPN_SHARED_SECRET:-btn-alicloud-ha-vpn-secret-2026}"

export PRIVATE_NAT_GW="${PRIVATE_NAT_GW:-btn-private-nat-gw}"
export PRIVATE_NAT_RULE_NUM="${PRIVATE_NAT_RULE_NUM:-100}"

# ------------------------------------------------------------------------------
# 5. Firewall Rule Names
# ------------------------------------------------------------------------------
export FW_GCP_INTERNAL="${FW_GCP_INTERNAL:-btn-gcp-allow-internal}"
export FW_GCP_ALICLOUD_TO_ILB="${FW_GCP_ALICLOUD_TO_ILB:-btn-gcp-allow-alicloud-to-ilb}"
export FW_GCP_IAP_SSH="${FW_GCP_IAP_SSH:-btn-gcp-allow-iap-ssh}"
export FW_ALI_FROM_GCP_SNAT="${FW_ALI_FROM_GCP_SNAT:-sim-alicloud-allow-from-gcp-snat}"
export FW_ALI_IAP_SSH="${FW_ALI_IAP_SSH:-sim-alicloud-allow-iap-ssh}"

# ------------------------------------------------------------------------------
# 6. GKE Cluster, Workload & Internal Load Balancer Names
# ------------------------------------------------------------------------------
export GKE_CLUSTER="${GKE_CLUSTER:-btn-gke-island-cluster}"
export GKE_NUM_NODES="${GKE_NUM_NODES:-2}"
export GKE_MACHINE_TYPE="${GKE_MACHINE_TYPE:-e2-medium}"
export GKE_DISK_TYPE="${GKE_DISK_TYPE:-pd-standard}"
export GKE_DISK_SIZE="${GKE_DISK_SIZE:-30}"

export K8S_APP_NAME="${K8S_APP_NAME:-btn-echo-app}"
export K8S_SVC_NAME="${K8S_SVC_NAME:-btn-echo-svc}"
export NEG_NAME="${NEG_NAME:-btn-echo-neg}"

export ILB_HC_NAME="${ILB_HC_NAME:-btn-gke-ilb-hc}"
export ILB_BS_NAME="${ILB_BS_NAME:-btn-gke-ilb-bs}"
export ILB_URLMAP_NAME="${ILB_URLMAP_NAME:-btn-gke-ilb-urlmap}"
export ILB_PROXY_NAME="${ILB_PROXY_NAME:-btn-gke-ilb-http-proxy}"
export ILB_FR_NAME="${ILB_FR_NAME:-btn-gke-ilb-fr}"

echo "=============================================================================="
echo "Loaded BTN GKE Island-Mode PoC Environment Configuration:"
echo "  PROJECT_ID         : $PROJECT_ID"
echo "  REGION / ZONE      : $REGION / $ZONE"
echo "  GCP VPC / Subnet   : $GCP_VPC / $GKE_SUBNET ($GKE_NODE_CIDR, Pods: $GKE_POD_CIDR, Svcs: $GKE_SVC_CIDR)"
echo "  Private NAT Subnet : $PRIVATE_NAT_SUBNET ($PRIVATE_NAT_CIDR -> BGP /32 VIP: $PRIVATE_NAT_BGP_VIP)"
echo "  Inbound ILB /32 VIP: $ILB_VIP_NAME ($ILB_VIP_CIDR)"
echo "  AliCloud VPC / VM  : $ALICLOUD_VPC / $ALICLOUD_VM_NAME ($ALICLOUD_VM_IP in $ALICLOUD_SUBNET_CIDR)"
echo "  GKE Cluster        : $GKE_CLUSTER"
echo "=============================================================================="
