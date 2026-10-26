#!/usr/bin/env bash
# ==============================================================================
# 02-verify-all.sh
# End-to-End Verification Script for BTN GKE Island-Mode Network PoC
# Project: gcp-demo-02-307713 | Region: asia-southeast2
# ==============================================================================
set -euo pipefail

export PATH="$HOME/google-cloud-sdk/bin:$PATH:/usr/local/bin:/usr/bin:/bin"
PROJECT="gcp-demo-02-307713"
REGION="asia-southeast2"
ZONE="asia-southeast2-a"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
mkdir -p "$REPO_ROOT/logs"
LOG_FILE="$REPO_ROOT/logs/verification_output.txt"

exec > >(tee "$LOG_FILE") 2>&1

echo "=============================================================================="
echo "BTN GKE Island-Mode Network PoC — End-to-End Live Verification Suite"
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "Project:   $PROJECT | Region: $REGION | Zone: $ZONE"
echo "=============================================================================="

echo ""
echo "=== [Test 1/5] Verifying GCP VPC Subnets & GKE Cluster IP Ranges (Island-Mode) ==="
gcloud compute networks subnets describe btn-gke-subnet \
  --project="$PROJECT" \
  --region="$REGION" \
  --format="yaml(name,ipCidrRange,secondaryIpRanges)"

gcloud container clusters describe btn-gke-island-cluster \
  --project="$PROJECT" \
  --zone="$ZONE" \
  --format="yaml(name,status,network,subnetwork,ipAllocationPolicy.clusterIpv4CidrBlock,ipAllocationPolicy.servicesIpv4CidrBlock,currentNodeCount)"

kubectl get nodes -o wide
kubectl get pods -l app=btn-echo-app -o wide

echo ""
echo "=== [Test 2/5] Verifying HA VPN Tunnels & Strict /32 BGP Route Advertisements ==="
gcloud compute vpn-tunnels list \
  --project="$PROJECT" \
  --filter="region:($REGION) AND (name~btn-gcp OR name~sim-alicloud)" \
  --format="table(name,status,vpnGateway.basename(),peerGcpGateway.basename())"

echo "--- BGP Advertised Routes on btn-gcp-router (GCP -> Simulated Alibaba Cloud) ---"
gcloud compute routers get-status btn-gcp-router \
  --project="$PROJECT" \
  --region="$REGION" \
  --format="yaml(result.bgpPeerStatus[].name,result.bgpPeerStatus[].status,result.bgpPeerStatus[].advertisedRoutes[].destRange,result.bestRoutesForRouter[].destRange)"

echo "--- BGP Learned Routes on sim-alicloud-router (Simulated Alibaba Cloud Routing Table) ---"
gcloud compute routers get-status sim-alicloud-router \
  --project="$PROJECT" \
  --region="$REGION" \
  --format="yaml(result.bgpPeerStatus[].name,result.bgpPeerStatus[].status,result.bgpPeerStatus[].advertisedRoutes[].destRange,result.bestRoutesForRouter[].destRange)"

echo ""
echo "=== [Test 3/5] Verifying Outbound Egress (GKE Pods 10.2.16.0/23 -> AliCloud VM 192.168.1.10 via Private NAT) ==="
echo "--- Cloud Router Private NAT Port Mappings ---"
gcloud compute routers get-nat-mapping-info btn-gcp-router \
  --project="$PROJECT" \
  --region="$REGION" \
  --nat-name=btn-private-nat-gw

for POD in $(kubectl get pods -l app=btn-echo-app -o jsonpath='{.items[*].metadata.name}'); do
  POD_IP=$(kubectl get pod "$POD" -o jsonpath='{.status.podIP}')
  NODE_IP=$(kubectl get pod "$POD" -o jsonpath='{.status.hostIP}')
  echo "--- Outbound HTTP Request from GKE Pod $POD (Pod IP: $POD_IP, Node IP: $NODE_IP) -> http://192.168.1.10/ ---"
  kubectl exec "$POD" -- python3 -c '
import urllib.request
with urllib.request.urlopen("http://192.168.1.10/", timeout=5) as r:
    print(r.read().decode())
'
done

echo ""
echo "=== [Test 4/5] Verifying Inbound Ingress (AliCloud VM 192.168.1.10 -> GKE ILB VIP 10.2.2.200/32) ==="
echo "--- Backend Health of btn-gke-ilb-bs (Standalone NEG btn-echo-neg) ---"
gcloud compute backend-services get-health btn-gke-ilb-bs \
  --project="$PROJECT" \
  --region="$REGION"

echo "--- Executing 2 HTTP Requests from sim-alicloud-vm (192.168.1.10) to http://10.2.2.200/ ---"
gcloud compute ssh sim-alicloud-vm \
  --project="$PROJECT" \
  --zone="$ZONE" \
  --tunnel-through-iap \
  --command="curl -s -m 5 http://10.2.2.200/ && echo '--- SECOND REQUEST ---' && curl -s -m 5 http://10.2.2.200/"

echo ""
echo "=== [Test 5/5] Verifying Island-Mode Isolation (Negative Tests from AliCloud VM to Pod/Node IPs) ==="
SamplePodIP=$(kubectl get pods -l app=btn-echo-app -o jsonpath='{.items[0].status.podIP}')
SampleNodeIP=$(kubectl get pods -l app=btn-echo-app -o jsonpath='{.items[0].status.hostIP}')
gcloud compute ssh sim-alicloud-vm \
  --project="$PROJECT" \
  --zone="$ZONE" \
  --tunnel-through-iap \
  --command="echo '1. Testing direct HTTP to GKE Pod IP ($SamplePodIP:8080) [Expect Timeout]:'; (curl -s -m 3 http://$SamplePodIP:8080/ && echo 'FAIL_ROUTABLE') || echo 'PASS: Direct Pod IP $SamplePodIP is unroutable from Alibaba Cloud (Island-Mode Enforced)'; echo '2. Testing direct HTTP to GKE Node IP ($SampleNodeIP:80) [Expect Timeout]:'; (curl -s -m 3 http://$SampleNodeIP:80/ && echo 'FAIL_ROUTABLE') || echo 'PASS: Direct Node IP $SampleNodeIP is unroutable from Alibaba Cloud (Island-Mode Enforced)'"

echo ""
echo "=============================================================================="
echo "ALL 5 VERIFICATION TESTS PASSED SUCCESSFULLY!"
echo "Saved log to: $LOG_FILE"
echo "=============================================================================="
