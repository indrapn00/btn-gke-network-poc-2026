#!/usr/bin/env bash
# ==============================================================================
# 03-cleanup-all.sh
# Safe Reverse-Dependency Cleanup Script for BTN GKE Island-Mode Network PoC
# Project: gcp-demo-02-307713 | Region: asia-southeast2
# ==============================================================================
set -euo pipefail

export PATH="$HOME/google-cloud-sdk/bin:$PATH:/usr/local/bin:/usr/bin:/bin"
PROJECT="gcp-demo-02-307713"
REGION="asia-southeast2"
ZONE="asia-southeast2-a"

echo "=== [1/6] Deleting Regional Internal Application Load Balancer Resources ==="
gcloud compute forwarding-rules delete btn-gke-ilb-fr --project="$PROJECT" --region="$REGION" --quiet || true
gcloud compute target-http-proxies delete btn-gke-ilb-http-proxy --project="$PROJECT" --region="$REGION" --quiet || true
gcloud compute url-maps delete btn-gke-ilb-urlmap --project="$PROJECT" --region="$REGION" --quiet || true
gcloud compute backend-services delete btn-gke-ilb-bs --project="$PROJECT" --region="$REGION" --quiet || true
gcloud compute health-checks delete btn-gke-ilb-hc --project="$PROJECT" --region="$REGION" --quiet || true
gcloud compute addresses delete btn-gke-ilb-vip --project="$PROJECT" --region="$REGION" --quiet || true

echo "=== [2/6] Deleting GKE Cluster & Simulated Alibaba Cloud VM ==="
gcloud container clusters delete btn-gke-island-cluster --project="$PROJECT" --zone="$ZONE" --quiet || true
gcloud compute instances delete sim-alicloud-vm --project="$PROJECT" --zone="$ZONE" --quiet || true

echo "=== [3/6] Deleting Private NAT, VPN Tunnels, HA VPN Gateways & Cloud Routers ==="
gcloud compute routers nats delete btn-private-nat-gw --router=btn-gcp-router --project="$PROJECT" --region="$REGION" --quiet || true

for TUN in btn-gcp-to-alicloud-tun0 btn-gcp-to-alicloud-tun1 sim-alicloud-to-gcp-tun0 sim-alicloud-to-gcp-tun1; do
  gcloud compute vpn-tunnels delete "$TUN" --project="$PROJECT" --region="$REGION" --quiet || true
done

gcloud compute routers delete btn-gcp-router --project="$PROJECT" --region="$REGION" --quiet || true
gcloud compute routers delete sim-alicloud-router --project="$PROJECT" --region="$REGION" --quiet || true
gcloud compute vpn-gateways delete btn-gcp-havpn --project="$PROJECT" --region="$REGION" --quiet || true
gcloud compute vpn-gateways delete sim-alicloud-havpn --project="$PROJECT" --region="$REGION" --quiet || true

echo "=== [4/6] Deleting Firewall Rules ==="
for FW in btn-gcp-allow-internal btn-gcp-allow-alicloud-to-ilb btn-gcp-allow-iap-ssh sim-alicloud-allow-from-gcp-snat sim-alicloud-allow-iap-ssh; do
  gcloud compute firewall-rules delete "$FW" --project="$PROJECT" --quiet || true
done

echo "=== [5/6] Deleting Subnets ==="
for SUB in btn-proxy-only-subnet btn-private-nat-subnet btn-gke-subnet sim-alicloud-subnet; do
  gcloud compute networks subnets delete "$SUB" --project="$PROJECT" --region="$REGION" --quiet || true
done

echo "=== [6/6] Deleting VPC Networks ==="
gcloud compute networks delete btn-gcp-vpc --project="$PROJECT" --quiet || true
gcloud compute networks delete sim-alicloud-vpc --project="$PROJECT" --quiet || true

echo "=== Cleanup Complete! ==="
