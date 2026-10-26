#!/usr/bin/env bash
# ==============================================================================
# 03-cleanup-all.sh
# Portable Reverse-Dependency Cleanup Script for BTN GKE Island-Mode Network PoC
# Dynamically discovers Project ID, Region, Zone, and all resource names via
# `scripts/00-env.sh`.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load dynamic environment variables (auto-detects active gcloud project/region/zone)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/00-env.sh"

echo "=== [1/6] Deleting Regional Internal Application Load Balancer Resources in $PROJECT_ID ($REGION) ==="
gcloud compute forwarding-rules delete "$ILB_FR_NAME" --project="$PROJECT_ID" --region="$REGION" --quiet || true
gcloud compute target-http-proxies delete "$ILB_PROXY_NAME" --project="$PROJECT_ID" --region="$REGION" --quiet || true
gcloud compute url-maps delete "$ILB_URLMAP_NAME" --project="$PROJECT_ID" --region="$REGION" --quiet || true
gcloud compute backend-services delete "$ILB_BS_NAME" --project="$PROJECT_ID" --region="$REGION" --quiet || true
gcloud compute health-checks delete "$ILB_HC_NAME" --project="$PROJECT_ID" --region="$REGION" --quiet || true
gcloud compute addresses delete "$ILB_VIP_NAME" --project="$PROJECT_ID" --region="$REGION" --quiet || true

echo "=== [2/6] Deleting GKE Cluster ($GKE_CLUSTER) & Simulated Alibaba Cloud VM ($ALICLOUD_VM_NAME) ==="
gcloud container clusters delete "$GKE_CLUSTER" --project="$PROJECT_ID" --zone="$ZONE" --quiet || true
gcloud compute instances delete "$ALICLOUD_VM_NAME" --project="$PROJECT_ID" --zone="$ZONE" --quiet || true

# Delete the Standalone NEG if GKE cluster deletion left it behind
gcloud compute network-endpoint-groups delete "$NEG_NAME" --project="$PROJECT_ID" --zone="$ZONE" --quiet || true

echo "=== [3/6] Deleting Private NAT, VPN Tunnels, HA VPN Gateways & Cloud Routers ==="
gcloud compute routers nats delete "$PRIVATE_NAT_GW" --router="$GCP_ROUTER" --project="$PROJECT_ID" --region="$REGION" --quiet || true

for TUN in "$GCP_TUN0" "$GCP_TUN1" "$ALICLOUD_TUN0" "$ALICLOUD_TUN1"; do
  gcloud compute vpn-tunnels delete "$TUN" --project="$PROJECT_ID" --region="$REGION" --quiet || true
done

gcloud compute routers delete "$GCP_ROUTER" --project="$PROJECT_ID" --region="$REGION" --quiet || true
gcloud compute routers delete "$ALICLOUD_ROUTER" --project="$PROJECT_ID" --region="$REGION" --quiet || true
gcloud compute vpn-gateways delete "$GCP_VPN_GW" --project="$PROJECT_ID" --region="$REGION" --quiet || true
gcloud compute vpn-gateways delete "$ALICLOUD_VPN_GW" --project="$PROJECT_ID" --region="$REGION" --quiet || true

echo "=== [4/6] Deleting Firewall Rules ==="
for FW in "$FW_GCP_INTERNAL" "$FW_GCP_ALICLOUD_TO_ILB" "$FW_GCP_IAP_SSH" "$FW_ALI_FROM_GCP_SNAT" "$FW_ALI_IAP_SSH"; do
  gcloud compute firewall-rules delete "$FW" --project="$PROJECT_ID" --quiet || true
done

echo "=== [5/6] Deleting Subnets ==="
for SUB in "$PROXY_ONLY_SUBNET" "$PRIVATE_NAT_SUBNET" "$GKE_SUBNET" "$ALICLOUD_SUBNET"; do
  gcloud compute networks subnets delete "$SUB" --project="$PROJECT_ID" --region="$REGION" --quiet || true
done

echo "=== [6/6] Deleting VPC Networks ==="
gcloud compute networks delete "$GCP_VPC" --project="$PROJECT_ID" --quiet || true
gcloud compute networks delete "$ALICLOUD_VPC" --project="$PROJECT_ID" --quiet || true

echo "=== Cleanup Complete in Project $PROJECT_ID! ==="
