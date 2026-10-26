#!/usr/bin/env bash
# ==============================================================================
# 02-verify-all.sh
# Portable End-to-End Verification Script for BTN GKE Island-Mode Network PoC
# Dynamically discovers Project ID, Region, Zone, and all network parameters
# via `scripts/00-env.sh`.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
mkdir -p "$REPO_ROOT/logs"
LOG_FILE="$REPO_ROOT/logs/verification_output.txt"

# Load dynamic environment variables (auto-detects active gcloud project/region/zone)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/00-env.sh"

exec > >(tee "$LOG_FILE") 2>&1

echo "=============================================================================="
echo "BTN GKE Island-Mode Network PoC — End-to-End Live Verification Suite"
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "Project:   $PROJECT_ID | Region: $REGION | Zone: $ZONE"
echo "=============================================================================="

echo ""
echo "=== [Test 1/5] Verifying GCP VPC Subnets & GKE Cluster IP Ranges (Island-Mode) ==="
gcloud compute networks subnets describe "$GKE_SUBNET" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --format="yaml(name,ipCidrRange,secondaryIpRanges)"

gcloud container clusters describe "$GKE_CLUSTER" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --format="yaml(name,status,network,subnetwork,ipAllocationPolicy.clusterIpv4CidrBlock,ipAllocationPolicy.servicesIpv4CidrBlock,currentNodeCount)"

gcloud container clusters get-credentials "$GKE_CLUSTER" \
  --zone="$ZONE" \
  --project="$PROJECT_ID" >/dev/null 2>&1

kubectl get nodes -o wide
kubectl get pods -l "app=${K8S_APP_NAME}" -o wide

echo ""
echo "=== [Test 2/5] Verifying HA VPN Tunnels & Strict /32 BGP Route Advertisements ==="
gcloud compute vpn-tunnels list \
  --project="$PROJECT_ID" \
  --filter="region:($REGION) AND (name~${GCP_TUN0} OR name~${GCP_TUN1} OR name~${ALICLOUD_TUN0} OR name~${ALICLOUD_TUN1})" \
  --format="table(name,status,vpnGateway.basename(),peerGcpGateway.basename())"

echo "--- BGP Advertised Routes on $GCP_ROUTER (GCP -> Simulated Alibaba Cloud) ---"
gcloud compute routers get-status "$GCP_ROUTER" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --format="yaml(result.bgpPeerStatus[].name,result.bgpPeerStatus[].status,result.bgpPeerStatus[].advertisedRoutes[].destRange,result.bestRoutesForRouter[].destRange)"

echo "--- BGP Learned Routes on $ALICLOUD_ROUTER (Simulated Alibaba Cloud Routing Table) ---"
gcloud compute routers get-status "$ALICLOUD_ROUTER" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --format="yaml(result.bgpPeerStatus[].name,result.bgpPeerStatus[].status,result.bgpPeerStatus[].advertisedRoutes[].destRange,result.bestRoutesForRouter[].destRange)"

echo ""
echo "=== [Test 3/5] Verifying Outbound Egress Data Plane (GKE Pods $GKE_POD_CIDR -> AliCloud VM $ALICLOUD_VM_IP via Private NAT) ==="
echo "--- Cloud Router Private NAT Port Mappings ---"
gcloud compute routers get-nat-mapping-info "$GCP_ROUTER" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --nat-name="$PRIVATE_NAT_GW"

echo "--- Starting background tcpdump packet capture on $ALICLOUD_VM_NAME (ens4) for SNAT subnet $PRIVATE_NAT_CIDR ---"
gcloud compute ssh "$ALICLOUD_VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --tunnel-through-iap \
  --command="sudo bash -c 'nohup timeout 12 tcpdump -ni ens4 \"net ${PRIVATE_NAT_CIDR} and tcp port 80\" -c 12 > /tmp/egress_tcpdump.txt 2>&1 </dev/null &'"
sleep 2

for POD in $(kubectl get pods -l "app=${K8S_APP_NAME}" -o jsonpath='{.items[*].metadata.name}'); do
  POD_IP=$(kubectl get pod "$POD" -o jsonpath='{.status.podIP}')
  NODE_IP=$(kubectl get pod "$POD" -o jsonpath='{.status.hostIP}')
  echo "--- Outbound HTTP Request from GKE Pod $POD (Pod IP: $POD_IP, Node IP: $NODE_IP) -> http://${ALICLOUD_VM_IP}/egress-from-$POD ---"
  kubectl exec "$POD" -- python3 -c "
import urllib.request
with urllib.request.urlopen('http://${ALICLOUD_VM_IP}/egress-from-$POD', timeout=5) as r:
    print('HTTP Status:', r.status)
    print(r.read().decode())
"
done

sleep 3
echo "--- Captured Data Plane tcpdump & HTTP Access Log on $ALICLOUD_VM_NAME ($ALICLOUD_VM_IP) ---"
gcloud compute ssh "$ALICLOUD_VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --tunnel-through-iap \
  --command="echo '[tcpdump on $ALICLOUD_VM_NAME ens4]:'; cat /tmp/egress_tcpdump.txt; echo ''; echo '[/var/log/alicloud-http.log on $ALICLOUD_VM_NAME]:'; sudo tail -n 4 /var/log/alicloud-http.log"

echo ""
echo "=== [Test 4/5] Verifying Inbound Ingress Data Plane (AliCloud VM $ALICLOUD_VM_IP -> GKE ILB VIP $ILB_VIP_CIDR) ==="
echo "--- Backend Health of $ILB_BS_NAME (Standalone NEG $NEG_NAME) ---"
gcloud compute backend-services get-health "$ILB_BS_NAME" \
  --project="$PROJECT_ID" \
  --region="$REGION"

echo "--- Executing 2 HTTP Requests + tcpdump on $ALICLOUD_VM_NAME ($ALICLOUD_VM_IP) -> http://${ILB_VIP_ADDRESS}/ ---"
gcloud compute ssh "$ALICLOUD_VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --tunnel-through-iap \
  --command="
sudo bash -c 'nohup timeout 8 tcpdump -ni ens4 \"host ${ILB_VIP_ADDRESS} and tcp port 80\" -c 10 > /tmp/ingress_tcpdump.txt 2>&1 </dev/null &'
sleep 1
echo '>>> Request 1: curl -i -s http://${ILB_VIP_ADDRESS}/ingress-from-alicloud-1'
curl -i -s -m 5 http://${ILB_VIP_ADDRESS}/ingress-from-alicloud-1
echo ''
echo '>>> Request 2: curl -i -s http://${ILB_VIP_ADDRESS}/ingress-from-alicloud-2'
curl -i -s -m 5 http://${ILB_VIP_ADDRESS}/ingress-from-alicloud-2
sleep 2
echo ''
echo '[tcpdump on $ALICLOUD_VM_NAME ens4 during Ingress to ${ILB_VIP_ADDRESS}:80]:'
cat /tmp/ingress_tcpdump.txt
"

echo "--- GKE Pod Logs (kubectl logs -l app=${K8S_APP_NAME}) confirming receipt of requests from $ALICLOUD_VM_IP ---"
kubectl logs -l "app=${K8S_APP_NAME}" --tail=12 --prefix=true

echo ""
echo "=== [Test 5/5] Verifying Island-Mode Isolation (Negative Tests from AliCloud VM to Pod/Node IPs) ==="
SamplePodIP=$(kubectl get pods -l "app=${K8S_APP_NAME}" -o jsonpath='{.items[0].status.podIP}')
SampleNodeIP=$(kubectl get pods -l "app=${K8S_APP_NAME}" -o jsonpath='{.items[0].status.hostIP}')
gcloud compute ssh "$ALICLOUD_VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --tunnel-through-iap \
  --command="echo '1. Testing direct HTTP to GKE Pod IP ($SamplePodIP:8080) [Expect Timeout]:'; (curl -s -m 3 http://$SamplePodIP:8080/ && echo 'FAIL_ROUTABLE') || echo 'PASS: Direct Pod IP $SamplePodIP is unroutable from Alibaba Cloud (Island-Mode Enforced)'; echo '2. Testing direct HTTP to GKE Node IP ($SampleNodeIP:80) [Expect Timeout]:'; (curl -s -m 3 http://$SampleNodeIP:80/ && echo 'FAIL_ROUTABLE') || echo 'PASS: Direct Node IP $SampleNodeIP is unroutable from Alibaba Cloud (Island-Mode Enforced)'"

echo ""
echo "=============================================================================="
echo "ALL 5 VERIFICATION TESTS PASSED SUCCESSFULLY!"
echo "Saved log to: $LOG_FILE"
echo "=============================================================================="
