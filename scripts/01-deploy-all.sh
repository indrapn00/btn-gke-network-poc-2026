#!/usr/bin/env bash
# ==============================================================================
# 01-deploy-all.sh
# Portable End-to-End Provisioning Script for BTN GKE Island-Mode Network PoC
# Dynamically discovers Project ID, Region, Zone, and all network parameters
# via `scripts/00-env.sh`.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load dynamic environment variables (auto-detects active gcloud project/region/zone)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/00-env.sh"

echo "=== [0/8] Ensuring Required Google Cloud APIs Are Enabled in $PROJECT_ID ==="
gcloud services enable compute.googleapis.com container.googleapis.com \
  --project="$PROJECT_ID"

echo "=== [1/8] Creating GCP Island-Mode VPC ($GCP_VPC) & Simulated Alibaba Cloud VPC ($ALICLOUD_VPC) ==="
gcloud compute networks create "$GCP_VPC" \
  --project="$PROJECT_ID" \
  --subnet-mode=custom \
  --bgp-routing-mode=regional || true

gcloud compute networks create "$ALICLOUD_VPC" \
  --project="$PROJECT_ID" \
  --subnet-mode=custom \
  --bgp-routing-mode=regional || true

echo "=== [2/8] Creating Subnets & Reserving Static ILB VIP ($ILB_VIP_CIDR) ==="
gcloud compute networks subnets create "$GKE_SUBNET" \
  --project="$PROJECT_ID" \
  --network="$GCP_VPC" \
  --region="$REGION" \
  --range="$GKE_NODE_CIDR" \
  --secondary-range="${GKE_POD_RANGE_NAME}=${GKE_POD_CIDR},${GKE_SVC_RANGE_NAME}=${GKE_SVC_CIDR}" \
  --enable-private-ip-google-access || true

gcloud compute networks subnets create "$PRIVATE_NAT_SUBNET" \
  --project="$PROJECT_ID" \
  --network="$GCP_VPC" \
  --region="$REGION" \
  --range="$PRIVATE_NAT_CIDR" \
  --purpose=PRIVATE_NAT || true

gcloud compute networks subnets create "$PROXY_ONLY_SUBNET" \
  --project="$PROJECT_ID" \
  --network="$GCP_VPC" \
  --region="$REGION" \
  --range="$PROXY_ONLY_CIDR" \
  --purpose=REGIONAL_MANAGED_PROXY \
  --role=ACTIVE || true

gcloud compute networks subnets create "$ALICLOUD_SUBNET" \
  --project="$PROJECT_ID" \
  --network="$ALICLOUD_VPC" \
  --region="$REGION" \
  --range="$ALICLOUD_SUBNET_CIDR" \
  --enable-private-ip-google-access || true

gcloud compute addresses create "$ILB_VIP_NAME" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --subnet="$GKE_SUBNET" \
  --addresses="$ILB_VIP_ADDRESS" || true

echo "=== [3/8] Creating Firewall Rules ==="
gcloud compute firewall-rules create "$FW_GCP_INTERNAL" \
  --project="$PROJECT_ID" \
  --network="$GCP_VPC" \
  --allow=tcp,udp,icmp \
  --source-ranges="${GKE_NODE_CIDR},${GKE_POD_CIDR},${GKE_SVC_CIDR}" || true

gcloud compute firewall-rules create "$FW_GCP_ALICLOUD_TO_ILB" \
  --project="$PROJECT_ID" \
  --network="$GCP_VPC" \
  --allow=tcp:80,tcp:8080,icmp \
  --source-ranges="${ALICLOUD_SUBNET_CIDR},${PROXY_ONLY_CIDR},35.191.0.0/16,130.211.0.0/22" || true

gcloud compute firewall-rules create "$FW_GCP_IAP_SSH" \
  --project="$PROJECT_ID" \
  --network="$GCP_VPC" \
  --allow=tcp:22 \
  --source-ranges=35.235.240.0/20 || true

gcloud compute firewall-rules create "$FW_ALI_FROM_GCP_SNAT" \
  --project="$PROJECT_ID" \
  --network="$ALICLOUD_VPC" \
  --allow=tcp:80,tcp:8080,icmp \
  --source-ranges="${PRIVATE_NAT_CIDR},${PRIVATE_NAT_BGP_VIP},${ALICLOUD_SUBNET_CIDR}" || true

gcloud compute firewall-rules create "$FW_ALI_IAP_SSH" \
  --project="$PROJECT_ID" \
  --network="$ALICLOUD_VPC" \
  --allow=tcp:22 \
  --source-ranges=35.235.240.0/20 || true

echo "=== [4/8] Creating Simulated Alibaba Cloud Test VM ($ALICLOUD_VM_NAME at $ALICLOUD_VM_IP) ==="
gcloud compute instances create "$ALICLOUD_VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --machine-type="$ALICLOUD_VM_MACHINE_TYPE" \
  --network-interface="subnet=${ALICLOUD_SUBNET},private-network-ip=${ALICLOUD_VM_IP},no-address" \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --metadata-from-file="startup-script=${SCRIPT_DIR}/alicloud-vm-startup.sh" || true

echo "=== [5/8] Creating HA VPN Gateways, Cloud Routers, VPN Tunnels & Custom /32 BGP Sessions ==="
gcloud compute routers create "$GCP_ROUTER" \
  --project="$PROJECT_ID" \
  --network="$GCP_VPC" \
  --region="$REGION" \
  --asn="$GCP_ASN" \
  --advertisement-mode=CUSTOM \
  --set-advertisement-ranges="${PRIVATE_NAT_BGP_VIP}=BTN-GKE-Egress-Private-NAT-VIP,${ILB_VIP_CIDR}=BTN-GKE-Ingress-ILB-VIP" || true

gcloud compute routers create "$ALICLOUD_ROUTER" \
  --project="$PROJECT_ID" \
  --network="$ALICLOUD_VPC" \
  --region="$REGION" \
  --asn="$ALICLOUD_ASN" \
  --advertisement-mode=CUSTOM \
  --set-advertisement-ranges="$ALICLOUD_SUBNET_CIDR" || true

gcloud compute vpn-gateways create "$GCP_VPN_GW" \
  --project="$PROJECT_ID" \
  --network="$GCP_VPC" \
  --region="$REGION" || true

gcloud compute vpn-gateways create "$ALICLOUD_VPN_GW" \
  --project="$PROJECT_ID" \
  --network="$ALICLOUD_VPC" \
  --region="$REGION" || true

gcloud compute vpn-tunnels create "$GCP_TUN0" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --vpn-gateway="$GCP_VPN_GW" \
  --peer-gcp-gateway="$ALICLOUD_VPN_GW" \
  --router="$GCP_ROUTER" \
  --ike-version=2 \
  --shared-secret="$VPN_SHARED_SECRET" \
  --interface=0 || true

gcloud compute vpn-tunnels create "$GCP_TUN1" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --vpn-gateway="$GCP_VPN_GW" \
  --peer-gcp-gateway="$ALICLOUD_VPN_GW" \
  --router="$GCP_ROUTER" \
  --ike-version=2 \
  --shared-secret="$VPN_SHARED_SECRET" \
  --interface=1 || true

gcloud compute vpn-tunnels create "$ALICLOUD_TUN0" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --vpn-gateway="$ALICLOUD_VPN_GW" \
  --peer-gcp-gateway="$GCP_VPN_GW" \
  --router="$ALICLOUD_ROUTER" \
  --ike-version=2 \
  --shared-secret="$VPN_SHARED_SECRET" \
  --interface=0 || true

gcloud compute vpn-tunnels create "$ALICLOUD_TUN1" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --vpn-gateway="$ALICLOUD_VPN_GW" \
  --peer-gcp-gateway="$GCP_VPN_GW" \
  --router="$ALICLOUD_ROUTER" \
  --ike-version=2 \
  --shared-secret="$VPN_SHARED_SECRET" \
  --interface=1 || true

gcloud compute routers add-interface "$GCP_ROUTER" \
  --project="$PROJECT_ID" --region="$REGION" \
  --interface-name=if-tun0 --ip-address="$BGP_TUN0_GCP_IP" --mask-length=30 \
  --vpn-tunnel="$GCP_TUN0" || true

gcloud compute routers add-bgp-peer "$GCP_ROUTER" \
  --project="$PROJECT_ID" --region="$REGION" \
  --peer-name=bgp-to-alicloud-0 --interface=if-tun0 \
  --peer-ip-address="$BGP_TUN0_ALI_IP" --peer-asn="$ALICLOUD_ASN" || true

gcloud compute routers add-interface "$GCP_ROUTER" \
  --project="$PROJECT_ID" --region="$REGION" \
  --interface-name=if-tun1 --ip-address="$BGP_TUN1_GCP_IP" --mask-length=30 \
  --vpn-tunnel="$GCP_TUN1" || true

gcloud compute routers add-bgp-peer "$GCP_ROUTER" \
  --project="$PROJECT_ID" --region="$REGION" \
  --peer-name=bgp-to-alicloud-1 --interface=if-tun1 \
  --peer-ip-address="$BGP_TUN1_ALI_IP" --peer-asn="$ALICLOUD_ASN" || true

gcloud compute routers add-interface "$ALICLOUD_ROUTER" \
  --project="$PROJECT_ID" --region="$REGION" \
  --interface-name=if-tun0 --ip-address="$BGP_TUN0_ALI_IP" --mask-length=30 \
  --vpn-tunnel="$ALICLOUD_TUN0" || true

gcloud compute routers add-bgp-peer "$ALICLOUD_ROUTER" \
  --project="$PROJECT_ID" --region="$REGION" \
  --peer-name=bgp-to-gcp-0 --interface=if-tun0 \
  --peer-ip-address="$BGP_TUN0_GCP_IP" --peer-asn="$GCP_ASN" || true

gcloud compute routers add-interface "$ALICLOUD_ROUTER" \
  --project="$PROJECT_ID" --region="$REGION" \
  --interface-name=if-tun1 --ip-address="$BGP_TUN1_ALI_IP" --mask-length=30 \
  --vpn-tunnel="$ALICLOUD_TUN1" || true

gcloud compute routers add-bgp-peer "$ALICLOUD_ROUTER" \
  --project="$PROJECT_ID" --region="$REGION" \
  --peer-name=bgp-to-gcp-1 --interface=if-tun1 \
  --peer-ip-address="$BGP_TUN1_GCP_IP" --peer-asn="$GCP_ASN" || true

echo "=== [6/8] Configuring Hybrid Private NAT ($PRIVATE_NAT_GW) ==="
gcloud compute routers nats create "$PRIVATE_NAT_GW" \
  --project="$PROJECT_ID" \
  --router="$GCP_ROUTER" \
  --region="$REGION" \
  --type=PRIVATE \
  --nat-all-subnet-ip-ranges || true

gcloud compute routers nats rules create "$PRIVATE_NAT_RULE_NUM" \
  --project="$PROJECT_ID" \
  --router="$GCP_ROUTER" \
  --region="$REGION" \
  --nat="$PRIVATE_NAT_GW" \
  --match="nexthop.is_hybrid" \
  --source-nat-active-ranges="$PRIVATE_NAT_SUBNET" || true

echo "=== [7/8] Creating GKE Island-Mode Cluster ($GKE_CLUSTER) & Deploying Workloads ==="
gcloud container clusters create "$GKE_CLUSTER" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --network="$GCP_VPC" \
  --subnetwork="$GKE_SUBNET" \
  --cluster-secondary-range-name="$GKE_POD_RANGE_NAME" \
  --services-secondary-range-name="$GKE_SVC_RANGE_NAME" \
  --enable-ip-alias \
  --num-nodes="$GKE_NUM_NODES" \
  --machine-type="$GKE_MACHINE_TYPE" \
  --disk-type="$GKE_DISK_TYPE" \
  --disk-size="$GKE_DISK_SIZE" \
  --no-enable-autoupgrade || true

gcloud container clusters get-credentials "$GKE_CLUSTER" \
  --zone="$ZONE" \
  --project="$PROJECT_ID"

kubectl apply -f "$REPO_ROOT/k8s/echo-deployment.yaml"
kubectl apply -f "$REPO_ROOT/k8s/echo-ilb-service.yaml"

# Dynamically verify/detect the primary Private NAT IP allocated to GKE nodes and ensure BGP advertises it
sleep 5
DETECTED_NAT_IP="$(gcloud compute routers get-nat-mapping-info "$GCP_ROUTER" \
  --project="$PROJECT_ID" --region="$REGION" --nat-name="$PRIVATE_NAT_GW" \
  --format="value(interfaceNatMappings[0].ruleMappings[0].natIpPortRanges)" 2>/dev/null \
  | tr ';' '\n' | cut -d: -f1 | tail -n 1 || true)"

if [[ -n "$DETECTED_NAT_IP" && "${DETECTED_NAT_IP}/32" != "$PRIVATE_NAT_BGP_VIP" ]]; then
  echo "Detected active Private NAT IP ${DETECTED_NAT_IP}/32; updating $GCP_ROUTER custom BGP advertisement..."
  export PRIVATE_NAT_SNAT_IP="$DETECTED_NAT_IP"
  export PRIVATE_NAT_BGP_VIP="${DETECTED_NAT_IP}/32"
  gcloud compute routers update "$GCP_ROUTER" \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --advertisement-mode=CUSTOM \
    --set-advertisement-ranges="${PRIVATE_NAT_BGP_VIP}=BTN-GKE-Egress-Private-NAT-VIP,${ILB_VIP_CIDR}=BTN-GKE-Ingress-ILB-VIP"
fi

echo "=== [8/8] Provisioning Regional Internal Application Load Balancer on $ILB_VIP_CIDR ==="
for _ in {1..20}; do
  if gcloud compute network-endpoint-groups describe "$NEG_NAME" --project="$PROJECT_ID" --zone="$ZONE" >/dev/null 2>&1; then
    break
  fi
  sleep 3
done

gcloud compute health-checks create http "$ILB_HC_NAME" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --use-serving-port \
  --request-path="/" || true

gcloud compute backend-services create "$ILB_BS_NAME" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --load-balancing-scheme=INTERNAL_MANAGED \
  --protocol=HTTP \
  --health-checks="$ILB_HC_NAME" \
  --health-checks-region="$REGION" || true

gcloud compute backend-services add-backend "$ILB_BS_NAME" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --network-endpoint-group="$NEG_NAME" \
  --network-endpoint-group-zone="$ZONE" \
  --balancing-mode=RATE \
  --max-rate-per-endpoint=100 || true

gcloud compute url-maps create "$ILB_URLMAP_NAME" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --default-service="$ILB_BS_NAME" || true

gcloud compute target-http-proxies create "$ILB_PROXY_NAME" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --url-map="$ILB_URLMAP_NAME" \
  --url-map-region="$REGION" || true

gcloud compute forwarding-rules create "$ILB_FR_NAME" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --load-balancing-scheme=INTERNAL_MANAGED \
  --network="$GCP_VPC" \
  --subnet="$GKE_SUBNET" \
  --address="$ILB_VIP_NAME" \
  --ip-protocol=TCP \
  --ports=80 \
  --target-http-proxy="$ILB_PROXY_NAME" \
  --target-http-proxy-region="$REGION" || true

echo "=== Deployment Complete in Project $PROJECT_ID ($REGION)! Run ./scripts/02-verify-all.sh to verify all requirements. ==="
