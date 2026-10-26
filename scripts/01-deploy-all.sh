#!/usr/bin/env bash
# ==============================================================================
# 01-deploy-all.sh
# End-to-End Provisioning Script for BTN GKE Island-Mode Network PoC
# Project: gcp-demo-02-307713 | Region: asia-southeast2 (Jakarta)
# ==============================================================================
set -euo pipefail

export PATH="$HOME/google-cloud-sdk/bin:$PATH:/usr/local/bin:/usr/bin:/bin"
PROJECT="gcp-demo-02-307713"
REGION="asia-southeast2"
ZONE="asia-southeast2-a"
SHARED_SECRET="btn-alicloud-ha-vpn-secret-2026"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== [1/8] Creating GCP Island-Mode VPC (btn-gcp-vpc) & Simulated Alibaba Cloud VPC (sim-alicloud-vpc) ==="
gcloud compute networks create btn-gcp-vpc \
  --project="$PROJECT" \
  --subnet-mode=custom \
  --bgp-routing-mode=regional || true

gcloud compute networks create sim-alicloud-vpc \
  --project="$PROJECT" \
  --subnet-mode=custom \
  --bgp-routing-mode=regional || true

echo "=== [2/8] Creating Subnets & Reserving Static ILB VIP (10.2.2.200/32) ==="
# GKE Subnet: Primary (Nodes) = 10.2.2.0/24, Secondary (Pods) = 10.2.16.0/23, Secondary (Services) = 10.2.18.0/23
gcloud compute networks subnets create btn-gke-subnet \
  --project="$PROJECT" \
  --network=btn-gcp-vpc \
  --region="$REGION" \
  --range=10.2.2.0/24 \
  --secondary-range=gke-pods=10.2.16.0/23,gke-services=10.2.18.0/23 \
  --enable-private-ip-google-access || true

# Private NAT Subnet: Minimum prefix length in GCP for --purpose=PRIVATE_NAT is /29.
# 10.2.99.96/29 encompasses 10.2.99.98 - 10.2.99.101 (including 10.2.99.99 and 10.2.99.100).
gcloud compute networks subnets create btn-private-nat-subnet \
  --project="$PROJECT" \
  --network=btn-gcp-vpc \
  --region="$REGION" \
  --range=10.2.99.96/29 \
  --purpose=PRIVATE_NAT || true

# Regional Managed Proxy Subnet: Used by Regional Internal Application Load Balancer (ENDPOINT_TYPE_MANAGED_PROXY_LB)
# so inbound traffic to 10.2.2.200/32 does not collide with Private NAT (ENDPOINT_TYPE_VM) on btn-gke-subnet.
gcloud compute networks subnets create btn-proxy-only-subnet \
  --project="$PROJECT" \
  --network=btn-gcp-vpc \
  --region="$REGION" \
  --range=10.2.20.0/23 \
  --purpose=REGIONAL_MANAGED_PROXY \
  --role=ACTIVE || true

# Simulated Alibaba Cloud Subnet: 192.168.1.0/24
gcloud compute networks subnets create sim-alicloud-subnet \
  --project="$PROJECT" \
  --network=sim-alicloud-vpc \
  --region="$REGION" \
  --range=192.168.1.0/24 \
  --enable-private-ip-google-access || true

# Static /32 VIP for Inbound GKE Internal Load Balancer (10.2.2.200)
gcloud compute addresses create btn-gke-ilb-vip \
  --project="$PROJECT" \
  --region="$REGION" \
  --subnet=btn-gke-subnet \
  --addresses=10.2.2.200 || true

echo "=== [3/8] Creating Firewall Rules ==="
gcloud compute firewall-rules create btn-gcp-allow-internal \
  --project="$PROJECT" \
  --network=btn-gcp-vpc \
  --allow=tcp,udp,icmp \
  --source-ranges=10.2.2.0/24,10.2.16.0/23,10.2.18.0/23 || true

gcloud compute firewall-rules create btn-gcp-allow-alicloud-to-ilb \
  --project="$PROJECT" \
  --network=btn-gcp-vpc \
  --allow=tcp:80,tcp:8080,icmp \
  --source-ranges=192.168.1.0/24,10.2.20.0/23,35.191.0.0/16,130.211.0.0/22 || true

gcloud compute firewall-rules create btn-gcp-allow-iap-ssh \
  --project="$PROJECT" \
  --network=btn-gcp-vpc \
  --allow=tcp:22 \
  --source-ranges=35.235.240.0/20 || true

gcloud compute firewall-rules create sim-alicloud-allow-from-gcp-snat \
  --project="$PROJECT" \
  --network=sim-alicloud-vpc \
  --allow=tcp:80,tcp:8080,icmp \
  --source-ranges=10.2.99.96/29,10.2.99.99/32,10.2.99.100/32,192.168.1.0/24 || true

gcloud compute firewall-rules create sim-alicloud-allow-iap-ssh \
  --project="$PROJECT" \
  --network=sim-alicloud-vpc \
  --allow=tcp:22 \
  --source-ranges=35.235.240.0/20 || true

echo "=== [4/8] Creating Simulated Alibaba Cloud Test VM (192.168.1.10) ==="
gcloud compute instances create sim-alicloud-vm \
  --project="$PROJECT" \
  --zone="$ZONE" \
  --machine-type=e2-micro \
  --network-interface=subnet=sim-alicloud-subnet,private-network-ip=192.168.1.10,no-address \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --metadata-from-file=startup-script="$SCRIPT_DIR/alicloud-vm-startup.sh" || true

echo "=== [5/8] Creating HA VPN Gateways, Cloud Routers, VPN Tunnels & Custom /32 BGP Sessions ==="
# GCP Cloud Router: Advertises ONLY 2 /32 routes:
#   - 10.2.99.99/32 (Outbound Private NAT /32 IP allocated by GCP from 10.2.99.96/29)
#   - 10.2.2.200/32 (Inbound GKE Internal Load Balancer /32 VIP)
# Does NOT advertise 10.2.2.0/24 (Nodes), 10.2.16.0/23 (Pods), 10.2.18.0/23 (Services), or 10.2.20.0/23 (Proxies).
gcloud compute routers create btn-gcp-router \
  --project="$PROJECT" \
  --network=btn-gcp-vpc \
  --region="$REGION" \
  --asn=65001 \
  --advertisement-mode=CUSTOM \
  --set-advertisement-ranges=10.2.99.99/32=BTN-GKE-Egress-Private-NAT-VIP,10.2.2.200/32=BTN-GKE-Ingress-ILB-VIP || true

gcloud compute routers create sim-alicloud-router \
  --project="$PROJECT" \
  --network=sim-alicloud-vpc \
  --region="$REGION" \
  --asn=65002 \
  --advertisement-mode=CUSTOM \
  --set-advertisement-ranges=192.168.1.0/24 || true

gcloud compute vpn-gateways create btn-gcp-havpn \
  --project="$PROJECT" \
  --network=btn-gcp-vpc \
  --region="$REGION" || true

gcloud compute vpn-gateways create sim-alicloud-havpn \
  --project="$PROJECT" \
  --network=sim-alicloud-vpc \
  --region="$REGION" || true

gcloud compute vpn-tunnels create btn-gcp-to-alicloud-tun0 \
  --project="$PROJECT" \
  --region="$REGION" \
  --vpn-gateway=btn-gcp-havpn \
  --peer-gcp-gateway=sim-alicloud-havpn \
  --router=btn-gcp-router \
  --ike-version=2 \
  --shared-secret="$SHARED_SECRET" \
  --interface=0 || true

gcloud compute vpn-tunnels create btn-gcp-to-alicloud-tun1 \
  --project="$PROJECT" \
  --region="$REGION" \
  --vpn-gateway=btn-gcp-havpn \
  --peer-gcp-gateway=sim-alicloud-havpn \
  --router=btn-gcp-router \
  --ike-version=2 \
  --shared-secret="$SHARED_SECRET" \
  --interface=1 || true

gcloud compute vpn-tunnels create sim-alicloud-to-gcp-tun0 \
  --project="$PROJECT" \
  --region="$REGION" \
  --vpn-gateway=sim-alicloud-havpn \
  --peer-gcp-gateway=btn-gcp-havpn \
  --router=sim-alicloud-router \
  --ike-version=2 \
  --shared-secret="$SHARED_SECRET" \
  --interface=0 || true

gcloud compute vpn-tunnels create sim-alicloud-to-gcp-tun1 \
  --project="$PROJECT" \
  --region="$REGION" \
  --vpn-gateway=sim-alicloud-havpn \
  --peer-gcp-gateway=btn-gcp-havpn \
  --router=sim-alicloud-router \
  --ike-version=2 \
  --shared-secret="$SHARED_SECRET" \
  --interface=1 || true

gcloud compute routers add-interface btn-gcp-router \
  --project="$PROJECT" --region="$REGION" \
  --interface-name=if-tun0 --ip-address=169.254.0.1 --mask-length=30 \
  --vpn-tunnel=btn-gcp-to-alicloud-tun0 || true

gcloud compute routers add-bgp-peer btn-gcp-router \
  --project="$PROJECT" --region="$REGION" \
  --peer-name=bgp-to-alicloud-0 --interface=if-tun0 \
  --peer-ip-address=169.254.0.2 --peer-asn=65002 || true

gcloud compute routers add-interface btn-gcp-router \
  --project="$PROJECT" --region="$REGION" \
  --interface-name=if-tun1 --ip-address=169.254.1.1 --mask-length=30 \
  --vpn-tunnel=btn-gcp-to-alicloud-tun1 || true

gcloud compute routers add-bgp-peer btn-gcp-router \
  --project="$PROJECT" --region="$REGION" \
  --peer-name=bgp-to-alicloud-1 --interface=if-tun1 \
  --peer-ip-address=169.254.1.2 --peer-asn=65002 || true

gcloud compute routers add-interface sim-alicloud-router \
  --project="$PROJECT" --region="$REGION" \
  --interface-name=if-tun0 --ip-address=169.254.0.2 --mask-length=30 \
  --vpn-tunnel=sim-alicloud-to-gcp-tun0 || true

gcloud compute routers add-bgp-peer sim-alicloud-router \
  --project="$PROJECT" --region="$REGION" \
  --peer-name=bgp-to-gcp-0 --interface=if-tun0 \
  --peer-ip-address=169.254.0.1 --peer-asn=65001 || true

gcloud compute routers add-interface sim-alicloud-router \
  --project="$PROJECT" --region="$REGION" \
  --interface-name=if-tun1 --ip-address=169.254.1.2 --mask-length=30 \
  --vpn-tunnel=sim-alicloud-to-gcp-tun1 || true

gcloud compute routers add-bgp-peer sim-alicloud-router \
  --project="$PROJECT" --region="$REGION" \
  --peer-name=bgp-to-gcp-1 --interface=if-tun1 \
  --peer-ip-address=169.254.1.1 --peer-asn=65001 || true

echo "=== [6/8] Configuring Hybrid Private NAT (btn-private-nat-gw) ==="
gcloud compute routers nats create btn-private-nat-gw \
  --project="$PROJECT" \
  --router=btn-gcp-router \
  --region="$REGION" \
  --type=PRIVATE \
  --nat-all-subnet-ip-ranges || true

gcloud compute routers nats rules create 100 \
  --project="$PROJECT" \
  --router=btn-gcp-router \
  --region="$REGION" \
  --nat=btn-private-nat-gw \
  --match="nexthop.is_hybrid" \
  --source-nat-active-ranges=btn-private-nat-subnet || true

echo "=== [7/8] Creating GKE Island-Mode Cluster & Deploying Workloads ==="
gcloud container clusters create btn-gke-island-cluster \
  --project="$PROJECT" \
  --zone="$ZONE" \
  --network=btn-gcp-vpc \
  --subnetwork=btn-gke-subnet \
  --cluster-secondary-range-name=gke-pods \
  --services-secondary-range-name=gke-services \
  --enable-ip-alias \
  --num-nodes=2 \
  --machine-type=e2-medium \
  --disk-type=pd-standard \
  --disk-size=30 \
  --no-enable-autoupgrade || true

gcloud container clusters get-credentials btn-gke-island-cluster \
  --zone="$ZONE" \
  --project="$PROJECT"

kubectl apply -f "$REPO_ROOT/k8s/echo-deployment.yaml"
kubectl apply -f "$REPO_ROOT/k8s/echo-ilb-service.yaml"

echo "=== [8/8] Provisioning Regional Internal Application Load Balancer on 10.2.2.200/32 ==="
for i in {1..20}; do
  if gcloud compute network-endpoint-groups describe btn-echo-neg --project="$PROJECT" --zone="$ZONE" >/dev/null 2>&1; then
    break
  fi
  sleep 3
done

gcloud compute health-checks create http btn-gke-ilb-hc \
  --project="$PROJECT" \
  --region="$REGION" \
  --use-serving-port \
  --request-path="/" || true

gcloud compute backend-services create btn-gke-ilb-bs \
  --project="$PROJECT" \
  --region="$REGION" \
  --load-balancing-scheme=INTERNAL_MANAGED \
  --protocol=HTTP \
  --health-checks=btn-gke-ilb-hc \
  --health-checks-region="$REGION" || true

gcloud compute backend-services add-backend btn-gke-ilb-bs \
  --project="$PROJECT" \
  --region="$REGION" \
  --network-endpoint-group=btn-echo-neg \
  --network-endpoint-group-zone="$ZONE" \
  --balancing-mode=RATE \
  --max-rate-per-endpoint=100 || true

gcloud compute url-maps create btn-gke-ilb-urlmap \
  --project="$PROJECT" \
  --region="$REGION" \
  --default-service=btn-gke-ilb-bs || true

gcloud compute target-http-proxies create btn-gke-ilb-http-proxy \
  --project="$PROJECT" \
  --region="$REGION" \
  --url-map=btn-gke-ilb-urlmap \
  --url-map-region="$REGION" || true

gcloud compute forwarding-rules create btn-gke-ilb-fr \
  --project="$PROJECT" \
  --region="$REGION" \
  --load-balancing-scheme=INTERNAL_MANAGED \
  --network=btn-gcp-vpc \
  --subnet=btn-gke-subnet \
  --address=btn-gke-ilb-vip \
  --ip-protocol=TCP \
  --ports=80 \
  --target-http-proxy=btn-gke-ilb-http-proxy \
  --target-http-proxy-region="$REGION" || true

echo "=== Deployment Complete! Run ./scripts/02-verify-all.sh to verify all requirements. ==="
