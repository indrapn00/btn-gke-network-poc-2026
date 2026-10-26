# BTN GCP (GKE Island-Mode) & Alibaba Cloud Private Connectivity — Complete Step-by-Step Guide & Study Notes

> **Author / Context:** Step-by-step configuration guide and architectural study notes for **Bank Tabungan Negara (BTN)** hybrid/multi-cloud integration between **Google Cloud (GKE)** and **Alibaba Cloud**, built and verified in Argolis project **`gcp-demo-02-307713`** (`asia-southeast2`, Jakarta).
> **Reference Documentation:** [Compare network models in GKE — Island-mode network model](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/gke-compare-network-models#island-mode-model)

---

## 1. Understanding the Customer Problem & GKE "Island-Mode" Architecture

### 1.1 Flat Network Model vs. Island-Mode Network Model
By default, **Google Kubernetes Engine (GKE)** uses a **VPC-native (flat) network model** where Pod IP addresses (`10.2.16.0/23`) are allocated from secondary alias IP ranges on the VPC subnet and are natively routable inside the Google Cloud VPC.

However, when integrating GKE with an enterprise partner or another cloud provider such as **Alibaba Cloud** at **BTN**, enterprise network teams often require an **Island-Mode network boundary** across the hybrid link:
1. **Zero Exposure of Internal Cluster Subnets:** The GKE Node subnet (`10.2.2.0/24`), Pod secondary range (`10.2.16.0/23`), and Service secondary range (`10.2.18.0/23`) **must never be advertised** to Alibaba Cloud or on-premises routers. This prevents IP exhaustion and allows the same Pod/Service CIDRs to be reused across multiple clusters.
2. **Single `/32` IP for Outbound (Egress) Traffic:** Any connection initiated from a GKE Pod (`10.2.16.0/23`) toward Alibaba Cloud (`192.168.1.0/24`) must be source-NATed (SNAT) to **a single private RFC1918 IP address** assigned by BTN.
3. **Single `/32` IP for Inbound (Ingress) Traffic:** Any connection initiated from Alibaba Cloud (`192.168.1.0/24`) toward a published GKE service must target **a single private RFC1918 Load Balancer VIP**.
4. **Strict `/32`-Only BGP Advertisements:** Over the private BGP session between GCP and Alibaba Cloud, GCP must advertise **only two `/32` prefixes**:
   - **`1 /32` IP for Outbound SNAT return traffic** (`10.2.99.99/32` from the `10.2.99.96/29` Private NAT block)
   - **`1 /32` IP for Inbound GKE Load Balancer traffic** (`10.2.2.200/32`)

### 1.2 Complete IP Addressing & Routing Plan

| Environment | Resource / Purpose | Subnet / IP Range | Advertised via BGP to Peer? | Notes |
| :--- | :--- | :--- | :--- | :--- |
| **GCP (`btn-gcp-vpc`)** | GKE Nodes (`btn-gke-subnet` primary) | `10.2.2.0/24` | ❌ **NO (Hidden)** | Hosts GKE nodes (`10.2.2.3`, `10.2.2.4`) and static ILB VIP (`10.2.2.200`) |
| **GCP (`btn-gcp-vpc`)** | GKE Pods (`gke-pods` secondary) | `10.2.16.0/23` | ❌ **NO (Hidden)** | VPC-native alias IPs for Pods (`10.2.16.8`, `10.2.17.12`) |
| **GCP (`btn-gcp-vpc`)** | GKE Services (`gke-services` secondary) | `10.2.18.0/23` | ❌ **NO (Hidden)** | ClusterIP range inside GKE |
| **GCP (`btn-gcp-vpc`)** | Regional Managed Proxy Subnet (`btn-proxy-only-subnet`) | `10.2.20.0/23` | ❌ **NO (Hidden)** | `--purpose=REGIONAL_MANAGED_PROXY` for Internal ALB Envoy proxies |
| **GCP (`btn-gcp-vpc`)** | Hybrid Private NAT Subnet (`btn-private-nat-subnet`) | `10.2.99.96/29` | ❌ **NO (Subnet Hidden)** | `--purpose=PRIVATE_NAT` (minimum `/29` size required by GCP) |
| **GCP $\rightarrow$ AliCloud BGP** | **Outbound SNAT `/32` Route** | **`10.2.99.99/32`** | ✅ **YES (`1 /32` Outbound)** | Active Private NAT IP allocated by GCP from `10.2.99.96/29` |
| **GCP $\rightarrow$ AliCloud BGP** | **Inbound GKE ILB `/32` VIP** | **`10.2.2.200/32`** | ✅ **YES (`1 /32` Inbound)** | Static VIP (`btn-gke-ilb-vip`) on `btn-gke-ilb-fr` |
| **Simulated AliCloud (`sim-alicloud-vpc`)** | Alibaba Cloud Workload Subnet (`sim-alicloud-subnet`) | **`192.168.1.0/24`** | ✅ **YES (to GCP)** | Hosts `sim-alicloud-vm` (`192.168.1.10`) |

---

## 2. Deep-Dive: Two Key Engineering Discoveries from Live Argolis Testing

### 2.1 Discovery #1: GCP `PRIVATE_NAT` `/29` Minimum Prefix (`8` Total vs. `4` Usable IPs), Greedy Port Allocation, & BTN Firewall Negotiation
When BTN specifies *"Assign `10.2.99.100/32` for Private NAT SNAT purpose"*, there are three critical Google Cloud networking behaviors to understand and share with BTN's network/security team:

#### A. Why `10.2.99.96/29` Has `8` Total IPs (`10.2.99.96`–`10.2.99.103`), of Which `4` Are Usable Host IPs in GCP
1. **`--purpose=PRIVATE_NAT` Minimum Subnet Prefix is `/29`:**
   If you try to create a `PRIVATE_NAT` subnet with a `/32` mask (`10.2.99.100/32`), Google Cloud rejects it:
   ```text
   Invalid IPCidrRange: 10.2.99.100/32. Prefix length must be at most 29.
   ```
   Furthermore, GCP does not allow creating static internal IP reservations inside a `PRIVATE_NAT` subnet (`PRIVATE_NAT subnetwork cannot be used for address reservation`).
2. **`/29` Subnet Math in Google Cloud (`8` Total IPs = `4` GCP-Reserved + `4` Usable NAT IPs):**
   In CIDR math, a `/29` block contains $2^{(32 - 29)} = 2^3 = \mathbf{8\text{ total IP addresses}}$ (`10.2.99.96` through `10.2.99.103`). While traditional on-premises networks reserve only `2` IPs per subnet (network and broadcast), **every Google Cloud VPC primary subnet reserves `4` IP addresses**, leaving **`4` usable host IPs** for Private NAT:

   | IP Address in `10.2.99.96/29` | Role in Google Cloud VPC Subnet | Usable by Private NAT for SNAT? |
   | :--- | :--- | :--- |
   | **`10.2.99.96`** | **Reserved by GCP** — Network Address (1st IP in `/29`) | ❌ **No** (Never emits packets) |
   | **`10.2.99.97`** | **Reserved by GCP** — Default Subnet Gateway (2nd IP in `/29`) | ❌ **No** (Never emits packets) |
   | **`10.2.99.98`** | ✅ **Usable Private NAT Host IP #1** | ✅ **Yes** (Secondary/spillover port block) |
   | **`10.2.99.99`** | ✅ **Usable Private NAT Host IP #2** *(Primary Active SNAT IP)* | ✅ **Yes** (Used first by greedy sequential allocation) |
   | **`10.2.99.100`** | ✅ **Usable Private NAT Host IP #3** | ✅ **Yes** (Available in `/29` pool as nodes/ports scale) |
   | **`10.2.99.101`** | ✅ **Usable Private NAT Host IP #4** | ✅ **Yes** (Available in `/29` pool as nodes/ports scale) |
   | **`10.2.99.102`** | **Reserved by GCP** — Second-to-last IP (Reserved by GCP) | ❌ **No** (Never emits packets) |
   | **`10.2.99.103`** | **Reserved by GCP** — Broadcast Address (Last IP in `/29`) | ❌ **No** (Never emits packets) |

#### B. How Cloud NAT Selects `10.2.99.99/32` First (Greedy Sequential Allocation) & When Spillover Occurs
1. **Control-Plane Port Block Assignment (`get-nat-mapping-info`):**
   Unlike Public Cloud NAT (which accepts `--source-nat-active-ips` with individual `/32` IPs), Private NAT (`--type=PRIVATE`) only accepts `--source-nat-active-ranges=btn-private-nat-subnet`. When Cloud NAT allocates ports from `10.2.99.96/29` to our two GKE nodes, it assigns port slices on `.99` and `.98` (`10.2.99.99:1024-1039`, `10.2.99.99:32768-32783`, and `10.2.99.98:1024-1039` on Node 1; `1040-1055` and `32784-32799` on Node 2).
2. **Data-Plane Greedy Sequential Port Allocation:**
   When a GKE Pod opens a connection to `192.168.1.10:80`, Google Cloud's Andromeda NAT engine does **not** randomly round-robin between `10.2.99.99` and `10.2.99.98`. Instead, for each destination `(dst_ip, dst_port, protocol)` tuple (`enableEndpointIndependentMapping: false`), the port allocator searches the node's active port ranges **greedily and sequentially** starting from the first range (`10.2.99.99`).
   - All normal connections to `192.168.1.10:80`, `192.168.1.10:8080`, etc. deterministically use **`10.2.99.99`**.
   - **When Spillover to `10.2.99.98` Happens:** If a single GKE Node simultaneously holds more open/closing (`TIME_WAIT`) connections to the **exact same `(dst_ip, dst_port, protocol)` endpoint** than the ports currently allocated on `10.2.99.99` before Dynamic Port Allocation steps up, the next connection spills over to **`10.2.99.98`**. If `btn-gcp-router` only advertises `10.2.99.99/32` over BGP, any spillover connection using `10.2.99.98` cannot receive return packets from Alibaba Cloud.

#### C. BTN Firewall & Routing Negotiation Guide (Option A vs. Option B)
- **Option A (Recommended Cloud-Native Design — Negotiate `/29` or `4 x /32` Usable IPs with BTN):**
  - Because `/29` is GCP's minimum `PRIVATE_NAT` subnet prefix, propose to BTN's firewall/network team that they allow either:
    1. The **`10.2.99.96/29` prefix** (or all **`8 x /32` IPs `10.2.99.96/32`–`10.2.99.103/32`**), **OR**
    2. Only the **`4 x /32` usable Private NAT IPs (`10.2.99.98/32`, `10.2.99.99/32`, `10.2.99.100/32`, `10.2.99.101/32`)** if their firewall team prefers registering explicit host `/32` objects and wants to exclude the 4 GCP-reserved addresses (`.96`, `.97`, `.102`, `.103`).
  - Also tune `btn-private-nat-gw` with `--min-ports-per-vm=2048` and `--tcp-time-wait-timeout=30s` to pre-allocate a large port buffer per GKE node.
- **Option B (Fallback if BTN Strictly Enforces `1 x /32` IP `10.2.99.100/32` Only):**
  - In this PoC, we prove that Cloud Router Custom BGP Advertisement can advertise **strictly `1 /32` (`10.2.99.99/32`)** without advertising `10.2.99.96/29`.
  - If BTN refuses to allow more than `1 x /32` IP in production and requires a 100% hard guarantee against burst spillover to `.98`/`.100`/`.101`, replace `PRIVATE_NAT` with a lightweight Egress NAT VM / NVA (`10.2.99.100/32`) running `iptables -t nat -A POSTROUTING -d 192.168.1.0/24 -j SNAT --to-source 10.2.99.100`.

### 2.2 Discovery #2: Why Passthrough ILB (`INTERNAL`) Fails When Hybrid Private NAT Is Active, and Why Proxy ILB (`INTERNAL_MANAGED`) Works
When you enable Hybrid Private NAT (`--type=PRIVATE`, `--match="nexthop.is_hybrid"`) on `btn-gcp-vpc`, Google Cloud enforces:
```text
Only ALL_IP_RANGES is allowed value for sourceIpRangesToNat for private Nats.
```
This means you **cannot** enable Private NAT *only* on the secondary Pod range (`10.2.16.0/23`) while excluding the primary Node range (`10.2.2.0/24`). Private NAT (`ENDPOINT_TYPE_VM`) is automatically attached to `ALL_IP_RANGES` of `btn-gke-subnet` (`10.2.2.0/24`, `10.2.16.0/23`, and `10.2.18.0/23`).

- **What happens with a Passthrough Internal Network Load Balancer (`load-balancing-scheme=INTERNAL`) on `10.2.2.200/32`?**
  1. `sim-alicloud-vm` (`192.168.1.10`) sends TCP `SYN` to `10.2.2.200:80`.
  2. Andromeda delivers the `SYN` directly to the GKE Node (`10.2.2.4`) without changing the destination IP (`10.2.2.200`).
  3. The GKE Pod (`10.2.17.12:8080`) accepts the `SYN` and replies with `SYN-ACK`. On the GKE Node (`ENDPOINT_TYPE_VM`), `nf_conntrack` transitions to `SYN_RECV` and transmits `src=10.2.2.200:80 -> dst=192.168.1.10` (`nexthop.is_hybrid`).
  4. **Andromeda's VM Private NAT stage intercepts the outbound `SYN-ACK` from `ENDPOINT_TYPE_VM`** because its destination matches `nexthop.is_hybrid`. Because Private NAT is outbound-only for `ENDPOINT_TYPE_VM` and has no NAT mapping for `10.2.2.200`, **Andromeda drops the `SYN-ACK`** and the connection times out!

- **How Regional Internal Application Load Balancer (`load-balancing-scheme=INTERNAL_MANAGED`) Solves This:**
  1. We create a **`REGIONAL_MANAGED_PROXY` subnet** (`btn-proxy-only-subnet`, `10.2.20.0/23`) in `btn-gcp-vpc` (which is **never** advertised over BGP).
  2. We annotate the GKE Service (`btn-echo-svc`) with `cloud.google.com/neg: '{"exposed_ports": {"80":{"name": "btn-echo-neg"}}}'`, which automatically creates a Container-Native Standalone NEG (`btn-echo-neg`) pointing directly to the GKE Pod IPs (`10.2.16.8:8080`, `10.2.17.12:8080`).
  3. We attach a **Regional Internal Application Load Balancer (`INTERNAL_MANAGED`)** forwarding rule (`btn-gke-ilb-fr`) to the static `/32` VIP **`10.2.2.200/32`**.
  4. When `192.168.1.10` connects to `10.2.2.200:80`, the TCP connection terminates at Google's managed Envoy proxy (**`ENDPOINT_TYPE_MANAGED_PROXY_LB`**). Because `btn-private-nat-gw` is configured with the default `--endpoint-types=ENDPOINT_TYPE_VM` (and **not** `ENDPOINT_TYPE_MANAGED_PROXY_LB`), **Private NAT does not touch the Envoy proxy's return packets to `192.168.1.10`!**
  5. Meanwhile, the Envoy proxy opens an internal connection from `10.2.20.x` to the GKE Pod (`10.2.16.x:8080`). Because `10.2.20.0/23` $\leftrightarrow$ `10.2.16.0/23` is **local VPC routing** (not `nexthop.is_hybrid`), the Pod's response never triggers Private NAT!

---

## 3. Step-by-Step Configuration Guide (Google Cloud Console GUI-First + `gcloud` CLI)

Below is the complete step-by-step guide to build this environment from scratch. Every step prioritizes the **Google Cloud Console UI (GUI)** first, followed by the exact **`gcloud` / `kubectl` CLI** equivalent.

---

### Step 1: Create the Two Custom VPCs & Subnets

#### 1A. Create `btn-gcp-vpc` and `btn-gke-subnet` (Google Cloud Console GUI)
1. In the Google Cloud Console (`gcp-demo-02-307713`), navigate to **VPC network $\rightarrow$ VPC networks** and click **+ Create VPC network**.
2. **Name:** `btn-gcp-vpc`
3. **Subnet creation mode:** Select **Custom**.
4. Under **New subnet**, configure the GKE subnet:
   - **Name:** `btn-gke-subnet`
   - **Region:** `asia-southeast2`
   - **IP stack type:** `IPv4 (single-stack)`
   - **IPv4 range:** `10.2.2.0/24` *(GKE Node Primary Range)*
   - Click **+ Add IPv4 secondary range**:
     - **Subnet range name:** `gke-pods` | **Secondary IPv4 range:** `10.2.16.0/23`
   - Click **+ Add IPv4 secondary range** again:
     - **Subnet range name:** `gke-services` | **Secondary IPv4 range:** `10.2.18.0/23`
   - **Private Google Access:** Select **On**.
   - Click **Done**.
5. Under **Dynamic routing mode**, select **Regional**, then click **Create**.

#### 1B. Create the `PRIVATE_NAT` Subnet & `REGIONAL_MANAGED_PROXY` Subnet in `btn-gcp-vpc` (GUI)
1. Click into **`btn-gcp-vpc` $\rightarrow$ Subnets tab $\rightarrow$ + Add subnet**:
   - **Name:** `btn-private-nat-subnet`
   - **Region:** `asia-southeast2`
   - **Purpose:** Select **Private NAT**.
   - **IPv4 range:** `10.2.99.96/29`
   - Click **Add**.
2. Click **+ Add subnet** again to create the Proxy-Only subnet for the Internal Load Balancer:
   - **Name:** `btn-proxy-only-subnet`
   - **Region:** `asia-southeast2`
   - **Purpose:** Select **Regional Managed Proxy** (Role: **Active**).
   - **IPv4 range:** `10.2.20.0/23`
   - Click **Add**.

#### 1C. Reserve the Static Inbound `/32` VIP (`10.2.2.200`) (GUI)
1. Navigate to **VPC network $\rightarrow$ IP addresses $\rightarrow$ + Reserve internal static IP address**.
2. **Name:** `btn-gke-ilb-vip`
3. **Network:** `btn-gcp-vpc` | **Subnetwork:** `btn-gke-subnet` (`asia-southeast2`)
4. **Static IP address:** Select **Let me choose** and enter `10.2.2.200`.
5. Click **Reserve**.

#### 1D. Create `sim-alicloud-vpc` and `sim-alicloud-subnet` (`192.168.1.0/24`) (GUI)
1. Navigate to **VPC network $\rightarrow$ VPC networks $\rightarrow$ + Create VPC network**.
2. **Name:** `sim-alicloud-vpc`
3. **Subnet creation mode:** Select **Custom**.
4. Under **New subnet**:
   - **Name:** `sim-alicloud-subnet`
   - **Region:** `asia-southeast2`
   - **IPv4 range:** `192.168.1.0/24`
   - **Private Google Access:** **On** $\rightarrow$ Click **Done**.
5. **Dynamic routing mode:** **Regional** $\rightarrow$ Click **Create**.

<details>
<summary><b>💻 Equivalent <code>gcloud</code> CLI Commands for Step 1</b></summary>

```bash
PROJECT="gcp-demo-02-307713"
REGION="asia-southeast2"

gcloud compute networks create btn-gcp-vpc \
  --project="$PROJECT" --subnet-mode=custom --bgp-routing-mode=regional

gcloud compute networks subnets create btn-gke-subnet \
  --project="$PROJECT" --network=btn-gcp-vpc --region="$REGION" \
  --range=10.2.2.0/24 \
  --secondary-range=gke-pods=10.2.16.0/23,gke-services=10.2.18.0/23 \
  --enable-private-ip-google-access

gcloud compute networks subnets create btn-private-nat-subnet \
  --project="$PROJECT" --network=btn-gcp-vpc --region="$REGION" \
  --range=10.2.99.96/29 --purpose=PRIVATE_NAT

gcloud compute networks subnets create btn-proxy-only-subnet \
  --project="$PROJECT" --network=btn-gcp-vpc --region="$REGION" \
  --range=10.2.20.0/23 --purpose=REGIONAL_MANAGED_PROXY --role=ACTIVE

gcloud compute addresses create btn-gke-ilb-vip \
  --project="$PROJECT" --region="$REGION" --subnet=btn-gke-subnet --addresses=10.2.2.200

gcloud compute networks create sim-alicloud-vpc \
  --project="$PROJECT" --subnet-mode=custom --bgp-routing-mode=regional

gcloud compute networks subnets create sim-alicloud-subnet \
  --project="$PROJECT" --network=sim-alicloud-vpc --region="$REGION" \
  --range=192.168.1.0/24 --enable-private-ip-google-access
```
</details>

---

### Step 2: Configure Firewall Rules in Both VPCs

#### 2A. Google Cloud Console GUI Steps
1. Navigate to **VPC network $\rightarrow$ Firewall $\rightarrow$ + Create firewall rule** and create the following 3 rules on **`btn-gcp-vpc`**:
   - **`btn-gcp-allow-internal`**:
     - **Network:** `btn-gcp-vpc` | **Direction:** `Ingress` | **Targets:** `All instances in the network`
     - **Source IPv4 ranges:** `10.2.2.0/24, 10.2.16.0/23, 10.2.18.0/23`
     - **Protocols and ports:** `tcp`, `udp`, `icmp`
   - **`btn-gcp-allow-alicloud-to-ilb`**:
     - **Network:** `btn-gcp-vpc` | **Direction:** `Ingress` | **Targets:** `All instances in the network`
     - **Source IPv4 ranges:** `192.168.1.0/24, 10.2.20.0/23, 35.191.0.0/16, 130.211.0.0/22` *(Allows Alibaba Cloud subnet, Regional Managed Proxy subnet, and Google Cloud Health Check probers)*
     - **Protocols and ports:** `tcp:80, tcp:8080, icmp`
   - **`btn-gcp-allow-iap-ssh`**:
     - **Network:** `btn-gcp-vpc` | **Source IPv4 ranges:** `35.235.240.0/20` | **Protocols and ports:** `tcp:22`
2. Create the following 2 rules on **`sim-alicloud-vpc`**:
   - **`sim-alicloud-allow-from-gcp-snat`**:
     - **Network:** `sim-alicloud-vpc` | **Direction:** `Ingress` | **Targets:** `All instances in the network`
     - **Source IPv4 ranges:** `10.2.99.96/29, 10.2.99.99/32, 10.2.99.100/32, 192.168.1.0/24` *(Notice that GKE Node `10.2.2.0/24` and Pod `10.2.16.0/23` ranges are NOT needed here because Alibaba Cloud only sees the Private NAT IP!)*
     - **Protocols and ports:** `tcp:80, tcp:8080, icmp`
   - **`sim-alicloud-allow-iap-ssh`**:
     - **Network:** `sim-alicloud-vpc` | **Source IPv4 ranges:** `35.235.240.0/20` | **Protocols and ports:** `tcp:22`

<details>
<summary><b>💻 Equivalent <code>gcloud</code> CLI Commands for Step 2</b></summary>

```bash
gcloud compute firewall-rules create btn-gcp-allow-internal \
  --project="$PROJECT" --network=btn-gcp-vpc \
  --allow=tcp,udp,icmp --source-ranges=10.2.2.0/24,10.2.16.0/23,10.2.18.0/23

gcloud compute firewall-rules create btn-gcp-allow-alicloud-to-ilb \
  --project="$PROJECT" --network=btn-gcp-vpc \
  --allow=tcp:80,tcp:8080,icmp \
  --source-ranges=192.168.1.0/24,10.2.20.0/23,35.191.0.0/16,130.211.0.0/22

gcloud compute firewall-rules create btn-gcp-allow-iap-ssh \
  --project="$PROJECT" --network=btn-gcp-vpc \
  --allow=tcp:22 --source-ranges=35.235.240.0/20

gcloud compute firewall-rules create sim-alicloud-allow-from-gcp-snat \
  --project="$PROJECT" --network=sim-alicloud-vpc \
  --allow=tcp:80,tcp:8080,icmp \
  --source-ranges=10.2.99.96/29,10.2.99.99/32,10.2.99.100/32,192.168.1.0/24

gcloud compute firewall-rules create sim-alicloud-allow-iap-ssh \
  --project="$PROJECT" --network=sim-alicloud-vpc \
  --allow=tcp:22 --source-ranges=35.235.240.0/20
```
</details>

---

### Step 3: Deploy the Simulated Alibaba Cloud VM (`sim-alicloud-vm` at `192.168.1.10`)

#### 3A. Google Cloud Console GUI Steps
1. Navigate to **Compute Engine $\rightarrow$ VM instances $\rightarrow$ + Create instance**.
2. **Name:** `sim-alicloud-vm`
3. **Region:** `asia-southeast2` | **Zone:** `asia-southeast2-a`
4. **Machine type:** `e2-micro`
5. **OS and storage:** Debian GNU/Linux 12 (bookworm).
6. **Networking $\rightarrow$ Network interfaces:**
   - **Network:** `sim-alicloud-vpc`
   - **Subnetwork:** `sim-alicloud-subnet` (`192.168.1.0/24`)
   - **Primary internal IPv4 address:** Select **Custom** and enter `192.168.1.10`.
   - **External IPv4 address:** Select **None** (100% private VM!).
7. **Advanced options $\rightarrow$ Management $\rightarrow$ Automation (Startup script):** Paste the contents of [`scripts/alicloud-vm-startup.sh`](./scripts/alicloud-vm-startup.sh) (which starts a Python HTTP JSON server on port `80` that echoes `"observed_client_ip"` and logs every request to `/var/log/alicloud-http.log`).
8. Click **Create**.

<details>
<summary><b>💻 Equivalent <code>gcloud</code> CLI Command for Step 3</b></summary>

```bash
gcloud compute instances create sim-alicloud-vm \
  --project="$PROJECT" --zone="asia-southeast2-a" --machine-type=e2-micro \
  --network-interface=subnet=sim-alicloud-subnet,private-network-ip=192.168.1.10,no-address \
  --image-family=debian-12 --image-project=debian-cloud \
  --metadata-from-file=startup-script=scripts/alicloud-vm-startup.sh
```
</details>

---

### Step 4: Configure HA VPN & Custom `/32`-Only BGP Route Advertisements

#### 4A. Create the Two Cloud Routers with Custom BGP Advertisements (GUI)
1. Navigate to **Network Connectivity $\rightarrow$ Cloud Routers $\rightarrow$ + Create router**.
2. **Create `btn-gcp-router` (GCP Side):**
   - **Name:** `btn-gcp-router`
   - **Network:** `btn-gcp-vpc` | **Region:** `asia-southeast2`
   - **Google ASN:** `65001`
   - **Advertise all subnets visible to the Cloud Router:** Select **Create custom routes**.
   - **Advertise all subnets available to the Cloud Router:** Leave **Unchecked** (so `10.2.2.0/24`, `10.2.16.0/23`, and `10.2.18.0/23` are **NOT** advertised!).
   - Under **Custom IP ranges**, click **+ Add custom IP range** twice:
     1. **IP address range:** `10.2.99.99/32` | **Description:** `BTN-GKE-Egress-Private-NAT-VIP` *(1 `/32` for Outbound)*
     2. **IP address range:** `10.2.2.200/32` | **Description:** `BTN-GKE-Ingress-ILB-VIP` *(1 `/32` for Inbound)*
   - Click **Create**.
3. **Create `sim-alicloud-router` (Simulated Alibaba Cloud Side):**
   - Click **+ Create router**.
   - **Name:** `sim-alicloud-router`
   - **Network:** `sim-alicloud-vpc` | **Region:** `asia-southeast2`
   - **Google ASN:** `65002`
   - **Route advertisements:** Select **Create custom routes**, leave *Advertise all subnets* **Unchecked**, and add custom IP range **`192.168.1.0/24`**.
   - Click **Create**.

#### 4B. Create HA VPN Gateways, Tunnels & BGP Peers (GUI)
1. Navigate to **Network Connectivity $\rightarrow$ VPN $\rightarrow$ + Create VPN connection**.
2. Choose **High-availability (HA) VPN** $\rightarrow$ Click **Continue**.
3. Create **`btn-gcp-havpn`** in `btn-gcp-vpc` (`asia-southeast2`) and **`sim-alicloud-havpn`** in `sim-alicloud-vpc` (`asia-southeast2`).
4. Add 2 VPN tunnels in each direction (`interface 0` and `interface 1`) using IKEv2 and a shared secret:
   - **`btn-gcp-to-alicloud-tun0`** & **`sim-alicloud-to-gcp-tun0`** (`169.254.0.1/30` $\leftrightarrow$ `169.254.0.2/30`)
   - **`btn-gcp-to-alicloud-tun1`** & **`sim-alicloud-to-gcp-tun1`** (`169.254.1.1/30` $\leftrightarrow$ `169.254.1.2/30`)
5. Configure the BGP sessions (`bgp-to-alicloud-0`, `bgp-to-alicloud-1`, `bgp-to-gcp-0`, `bgp-to-gcp-1`) and verify that both tunnels show **`Established`** and BGP status shows **`BGP established`**.

<details>
<summary><b>💻 Equivalent <code>gcloud</code> CLI Commands for Step 4</b></summary>

```bash
SHARED_SECRET="btn-alicloud-ha-vpn-secret-2026"

gcloud compute routers create btn-gcp-router \
  --project="$PROJECT" --network=btn-gcp-vpc --region="$REGION" --asn=65001 \
  --advertisement-mode=CUSTOM \
  --set-advertisement-ranges=10.2.99.99/32=BTN-GKE-Egress-Private-NAT-VIP,10.2.2.200/32=BTN-GKE-Ingress-ILB-VIP

gcloud compute routers create sim-alicloud-router \
  --project="$PROJECT" --network=sim-alicloud-vpc --region="$REGION" --asn=65002 \
  --advertisement-mode=CUSTOM --set-advertisement-ranges=192.168.1.0/24

gcloud compute vpn-gateways create btn-gcp-havpn --project="$PROJECT" --network=btn-gcp-vpc --region="$REGION"
gcloud compute vpn-gateways create sim-alicloud-havpn --project="$PROJECT" --network=sim-alicloud-vpc --region="$REGION"

gcloud compute vpn-tunnels create btn-gcp-to-alicloud-tun0 \
  --project="$PROJECT" --region="$REGION" --vpn-gateway=btn-gcp-havpn \
  --peer-gcp-gateway=sim-alicloud-havpn --router=btn-gcp-router \
  --ike-version=2 --shared-secret="$SHARED_SECRET" --interface=0

gcloud compute vpn-tunnels create btn-gcp-to-alicloud-tun1 \
  --project="$PROJECT" --region="$REGION" --vpn-gateway=btn-gcp-havpn \
  --peer-gcp-gateway=sim-alicloud-havpn --router=btn-gcp-router \
  --ike-version=2 --shared-secret="$SHARED_SECRET" --interface=1

gcloud compute vpn-tunnels create sim-alicloud-to-gcp-tun0 \
  --project="$PROJECT" --region="$REGION" --vpn-gateway=sim-alicloud-havpn \
  --peer-gcp-gateway=btn-gcp-havpn --router=sim-alicloud-router \
  --ike-version=2 --shared-secret="$SHARED_SECRET" --interface=0

gcloud compute vpn-tunnels create sim-alicloud-to-gcp-tun1 \
  --project="$PROJECT" --region="$REGION" --vpn-gateway=sim-alicloud-havpn \
  --peer-gcp-gateway=btn-gcp-havpn --router=sim-alicloud-router \
  --ike-version=2 --shared-secret="$SHARED_SECRET" --interface=1

gcloud compute routers add-interface btn-gcp-router --project="$PROJECT" --region="$REGION" \
  --interface-name=if-tun0 --ip-address=169.254.0.1 --mask-length=30 --vpn-tunnel=btn-gcp-to-alicloud-tun0
gcloud compute routers add-bgp-peer btn-gcp-router --project="$PROJECT" --region="$REGION" \
  --peer-name=bgp-to-alicloud-0 --interface=if-tun0 --peer-ip-address=169.254.0.2 --peer-asn=65002

gcloud compute routers add-interface btn-gcp-router --project="$PROJECT" --region="$REGION" \
  --interface-name=if-tun1 --ip-address=169.254.1.1 --mask-length=30 --vpn-tunnel=btn-gcp-to-alicloud-tun1
gcloud compute routers add-bgp-peer btn-gcp-router --project="$PROJECT" --region="$REGION" \
  --peer-name=bgp-to-alicloud-1 --interface=if-tun1 --peer-ip-address=169.254.1.2 --peer-asn=65002

gcloud compute routers add-interface sim-alicloud-router --project="$PROJECT" --region="$REGION" \
  --interface-name=if-tun0 --ip-address=169.254.0.2 --mask-length=30 --vpn-tunnel=sim-alicloud-to-gcp-tun0
gcloud compute routers add-bgp-peer sim-alicloud-router --project="$PROJECT" --region="$REGION" \
  --peer-name=bgp-to-gcp-0 --interface=if-tun0 --peer-ip-address=169.254.0.1 --peer-asn=65001

gcloud compute routers add-interface sim-alicloud-router --project="$PROJECT" --region="$REGION" \
  --interface-name=if-tun1 --ip-address=169.254.1.2 --mask-length=30 --vpn-tunnel=sim-alicloud-to-gcp-tun1
gcloud compute routers add-bgp-peer sim-alicloud-router --project="$PROJECT" --region="$REGION" \
  --peer-name=bgp-to-gcp-1 --interface=if-tun1 --peer-ip-address=169.254.1.1 --peer-asn=65001
```
</details>

---

### Step 5: Configure Hybrid Private NAT (`btn-private-nat-gw`) for GKE Egress

#### 5A. Google Cloud Console GUI Steps
1. Navigate to **Network Services $\rightarrow$ Cloud NAT $\rightarrow$ + Create Cloud NAT gateway**.
2. **Gateway name:** `btn-private-nat-gw`
3. **NAT type:** Select **Private**.
4. **Network:** `btn-gcp-vpc` | **Region:** `asia-southeast2` | **Cloud Router:** `btn-gcp-router`
5. **Source:** Select **All subnets (primary and secondary ranges)** (`--nat-all-subnet-ip-ranges`).
6. Under **Private NAT rules $\rightarrow$ + Add new rule**:
   - **Rule number:** `100`
   - **Match traffic:** Select **Hybrid NAT** (or in CEL expression mode, enter `nexthop.is_hybrid`).
   - **Subnetwork for NAT IP addresses (`PRIVATE_NAT`):** Select **`btn-private-nat-subnet` (`10.2.99.96/29`)**.
7. Click **Create**.

<details>
<summary><b>💻 Equivalent <code>gcloud</code> CLI Commands for Step 5</b></summary>

```bash
gcloud compute routers nats create btn-private-nat-gw \
  --project="$PROJECT" --router=btn-gcp-router --region="$REGION" \
  --type=PRIVATE --nat-all-subnet-ip-ranges

gcloud compute routers nats rules create 100 \
  --project="$PROJECT" --router=btn-gcp-router --region="$REGION" \
  --nat=btn-private-nat-gw \
  --match="nexthop.is_hybrid" \
  --source-nat-active-ranges=btn-private-nat-subnet
```
</details>

---

### Step 6: Create the GKE Cluster (`btn-gke-island-cluster`) & Deploy the Workload

#### 6A. Google Cloud Console GUI Steps (GKE Cluster Creation)
1. Navigate to **Kubernetes Engine $\rightarrow$ Clusters $\rightarrow$ + Create** and click **Switch to Standard cluster** (Configure).
2. **Cluster basics:**
   - **Name:** `btn-gke-island-cluster`
   - **Location type:** **Zonal** $\rightarrow$ `asia-southeast2-a`
3. **Node Pools $\rightarrow$ default-pool:**
   - **Number of nodes:** `2`
   - **Nodes $\rightarrow$ Machine configuration:** `e2-medium`, Boot disk `30 GB` Standard persistent disk.
4. **Cluster $\rightarrow$ Networking:**
   - **Network:** `btn-gcp-vpc`
   - **Node subnet:** `btn-gke-subnet (10.2.2.0/24)`
   - **Cluster Pod address range (secondary range):** Select **`gke-pods (10.2.16.0/23)`**.
   - **Services address range (secondary range):** Select **`gke-services (10.2.18.0/23)`**.
5. Click **Create** and wait for the cluster to become `RUNNING`.

#### 6B. Deploy the GKE Echo Workload & Standalone NEG Service (`kubectl`)
Connect to the cluster and apply [`k8s/echo-deployment.yaml`](./k8s/echo-deployment.yaml) and [`k8s/echo-ilb-service.yaml`](./k8s/echo-ilb-service.yaml):
```bash
gcloud container clusters get-credentials btn-gke-island-cluster \
  --zone="asia-southeast2-a" --project="gcp-demo-02-307713"

kubectl apply -f k8s/echo-deployment.yaml
kubectl apply -f k8s/echo-ilb-service.yaml
```
Notice how [`k8s/echo-ilb-service.yaml`](./k8s/echo-ilb-service.yaml) uses the `cloud.google.com/neg` annotation so GKE's NEG controller automatically creates and populates the zonal `GCE_VM_IP_PORT` Network Endpoint Group **`btn-echo-neg`** with our Pod IPs (`10.2.16.8:8080` and `10.2.17.12:8080`):
```yaml
apiVersion: v1
kind: Service
metadata:
  name: btn-echo-svc
  namespace: default
  annotations:
    cloud.google.com/neg: '{"exposed_ports": {"80":{"name": "btn-echo-neg"}}}'
spec:
  type: ClusterIP
  selector:
    app: btn-echo-app
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: 8080
```

---

### Step 7: Create the Regional Internal Application Load Balancer on `10.2.2.200/32`

#### 7A. Google Cloud Console GUI Steps
1. Navigate to **Network Services $\rightarrow$ Load balancing $\rightarrow$ + Create load balancer**.
2. Select **Application Load Balancer (HTTP/HTTPS)** $\rightarrow$ **Next**.
3. **Public or internal:** Select **Internal** $\rightarrow$ **Next**.
4. **Cross-region or single region:** Select **Best for regional workloads (`asia-southeast2`)** $\rightarrow$ **Configure**.
5. **Load Balancer name:** `btn-gke-ilb-urlmap`
   - **Region:** `asia-southeast2` | **Network:** `btn-gcp-vpc`
   - *(The Console automatically detects the active proxy-only subnet `btn-proxy-only-subnet` `10.2.20.0/23`.)*
6. **Frontend configuration:**
   - **Name:** `btn-gke-ilb-fr`
   - **Protocol:** `HTTP` | **Port:** `80`
   - **Subnetwork:** `btn-gke-subnet (10.2.2.0/24)`
   - **Internal IP — IP address:** Select **`btn-gke-ilb-vip (10.2.2.200)`**.
   - Click **Done**.
7. **Backend configuration $\rightarrow$ Create a backend service:**
   - **Name:** `btn-gke-ilb-bs`
   - **Backend type:** Select **Zonal network endpoint group (GCE_VM_IP_PORT)**.
   - **Protocol:** `HTTP`
   - Under **Backends $\rightarrow$ New backend**:
     - **Network endpoint group:** Select **`btn-echo-neg (asia-southeast2-a)`**.
     - **Balancing mode:** `Rate` | **Maximum RPS:** `100` (`Per endpoint`) $\rightarrow$ Click **Done**.
   - **Health check $\rightarrow$ Create a health check:**
     - **Name:** `btn-gke-ilb-hc` | **Protocol:** `HTTP` | **Port:** `Use serving port` | **Request path:** `/` $\rightarrow$ Click **Save**.
   - Click **Create** to save `btn-gke-ilb-bs`.
8. **Routing rules:** Leave default (`All unmatched` $\rightarrow$ `btn-gke-ilb-bs`).
9. Click **Create** at the bottom of the wizard.

<details>
<summary><b>💻 Equivalent <code>gcloud</code> CLI Commands for Step 7</b></summary>

```bash
gcloud compute health-checks create http btn-gke-ilb-hc \
  --project="$PROJECT" --region="$REGION" --use-serving-port --request-path="/"

gcloud compute backend-services create btn-gke-ilb-bs \
  --project="$PROJECT" --region="$REGION" --load-balancing-scheme=INTERNAL_MANAGED \
  --protocol=HTTP --health-checks=btn-gke-ilb-hc --health-checks-region="$REGION"

gcloud compute backend-services add-backend btn-gke-ilb-bs \
  --project="$PROJECT" --region="$REGION" \
  --network-endpoint-group=btn-echo-neg --network-endpoint-group-zone="asia-southeast2-a" \
  --balancing-mode=RATE --max-rate-per-endpoint=100

gcloud compute url-maps create btn-gke-ilb-urlmap \
  --project="$PROJECT" --region="$REGION" --default-service=btn-gke-ilb-bs

gcloud compute target-http-proxies create btn-gke-ilb-http-proxy \
  --project="$PROJECT" --region="$REGION" \
  --url-map=btn-gke-ilb-urlmap --url-map-region="$REGION"

gcloud compute forwarding-rules create btn-gke-ilb-fr \
  --project="$PROJECT" --region="$REGION" --load-balancing-scheme=INTERNAL_MANAGED \
  --network=btn-gcp-vpc --subnet=btn-gke-subnet --address=btn-gke-ilb-vip \
  --ip-protocol=TCP --ports=80 \
  --target-http-proxy=btn-gke-ilb-http-proxy --target-http-proxy-region="$REGION"
```
</details>

---

## 4. Step-by-Step Verification Guide (GUI + CLI)

### 4.1 Verify Strict `/32` BGP Route Advertisements
- **In Google Cloud Console GUI:**
  1. Navigate to **Network Connectivity $\rightarrow$ Cloud Routers $\rightarrow$ `sim-alicloud-router`**.
  2. Click on the **BGP sessions** (`bgp-to-gcp-0` / `bgp-to-gcp-1`) or view the **VPC network $\rightarrow$ Routes** tab for `sim-alicloud-vpc` (`Dynamic (BGP)` routes).
  3. Confirm that **only** `10.2.2.200/32` and `10.2.99.99/32` are learned from `ASN 65001`—and that `10.2.2.0/24`, `10.2.16.0/23`, and `10.2.18.0/23` are completely absent!
- **Via CLI:**
  ```bash
  gcloud compute routers get-status sim-alicloud-router \
    --project=gcp-demo-02-307713 --region=asia-southeast2 \
    --format="yaml(result.bestRoutesForRouter[].destRange,result.bestRoutesForRouter[].nextHopIp)"
  ```

### 4.2 Verify Outbound Egress Data Plane (GKE Pods `10.2.16.0/23` $\rightarrow$ Simulated Alibaba Cloud VM `192.168.1.10` via Private NAT `10.2.99.99/32`)

1. **In Google Cloud Console GUI (Control Plane + Data Plane SSH):**
   - **Control Plane Port Mapping:** Navigate to **Network Services $\rightarrow$ Cloud NAT $\rightarrow$ `btn-private-nat-gw` $\rightarrow$ Port mapping tab** to see `10.2.99.99` mapped to the GKE nodes and Pod alias ranges (`10.2.16.0/24`, `10.2.17.0/24`).
   - **Data Plane Packet & Log Watch on `sim-alicloud-vm`:** Navigate to **Compute Engine $\rightarrow$ VM instances**, click **SSH** next to **`sim-alicloud-vm`** (`192.168.1.10`), and run:
     ```bash
     sudo tcpdump -ni ens4 'tcp port 80'
     # Or watch the HTTP server access log:
     sudo tail -f /var/log/alicloud-http.log
     ```
2. **Initiate Outbound HTTP Requests from the GKE Pods (`kubectl exec`):**
   > **Note (Cloud Shell `kubeconfig` Tip):** Always run `gcloud container clusters get-credentials btn-gke-island-cluster` first in Cloud Shell! If your Cloud Shell `~/.kube/config` is still pointing to an older deleted cluster IP, `kubectl` will time out with `Unable to connect to the server: dial tcp <old-ip>:443: i/o timeout` before reaching `btn-gke-island-cluster` (`34.101.129.243`).

   ```bash
   gcloud container clusters get-credentials btn-gke-island-cluster \
     --zone="asia-southeast2-a" --project="gcp-demo-02-307713"

   for POD in $(kubectl get pods -l app=btn-echo-app -o jsonpath='{.items[*].metadata.name}'); do
     POD_IP=$(kubectl get pod "$POD" -o jsonpath='{.status.podIP}')
     NODE_IP=$(kubectl get pod "$POD" -o jsonpath='{.status.hostIP}')
     echo ">>> Sending HTTP GET from GKE Pod $POD (Pod IP: $POD_IP, Node IP: $NODE_IP) -> http://192.168.1.10/egress-from-$POD"
     kubectl exec "$POD" -- python3 -c "
   import urllib.request
   with urllib.request.urlopen('http://192.168.1.10/egress-from-$POD', timeout=5) as r:
       print('HTTP Status:', r.status)
       print(r.read().decode())
   "
   done
   ```
3. **Observed Data Plane Proof (`tcpdump` on `sim-alicloud-vm` + JSON Response):**
   - Both GKE Pods (`10.2.17.12` on Node `10.2.2.4` and `10.2.16.8` on Node `10.2.2.3`) receive `HTTP 200 OK` with `"observed_client_ip": "10.2.99.99"`.
   - `tcpdump` on `sim-alicloud-vm` (`ens4`) confirms the raw TCP packets arrive from `10.2.99.99:1024` (Node 1) and `10.2.99.99:1040` (Node 2):
     ```text
     04:43:30.420173 IP 10.2.99.99.1024 > 192.168.1.10.80: Flags [S], seq 1118586314, win 42600, length 0
     04:43:30.422787 IP 10.2.99.99.1024 > 192.168.1.10.80: Flags [P.], seq 1:157, ack 1, length 156: HTTP: GET /egress-from-btn-echo-app-cb955885b-86ftl HTTP/1.1
     04:43:32.704304 IP 10.2.99.99.1040 > 192.168.1.10.80: Flags [S], seq 805427931, win 42600, length 0
     ```

### 4.3 Verify Inbound Ingress Data Plane (`sim-alicloud-vm` `192.168.1.10` $\rightarrow$ GKE ILB VIP `10.2.2.200/32`) & Island-Mode Isolation

1. **Watch GKE Pod Logs in Real Time (GUI or CLI):**
   - **In Google Cloud Console GUI:** Navigate to **Kubernetes Engine $\rightarrow$ Workloads $\rightarrow$ `btn-echo-app` $\rightarrow$ Logs**.
   - **Via CLI:**
     ```bash
     kubectl logs -l app=btn-echo-app -f --prefix=true
     ```
2. **Send Inbound HTTP Requests from `sim-alicloud-vm` (`192.168.1.10`) to `10.2.2.200`:**
   SSH into `sim-alicloud-vm` (via Console **SSH-in-browser** button or `gcloud compute ssh sim-alicloud-vm --zone=asia-southeast2-a --tunnel-through-iap`) and run:
   ```bash
   # 1. Positive Inbound Test to GKE ILB /32 VIP (Succeeds with HTTP 200 OK across both GKE Pods):
   curl -i http://10.2.2.200/ingress-from-alicloud-1
   curl -i http://10.2.2.200/ingress-from-alicloud-2

   # 2. Optional Packet Capture on sim-alicloud-vm during Inbound Request:
   sudo tcpdump -ni ens4 'host 10.2.2.200 and tcp port 80'

   # 3. Negative Isolation Test directly to GKE Pod IP 10.2.17.12:8080 (Times out as unroutable!):
   curl -v -m 3 http://10.2.17.12:8080/

   # 4. Negative Isolation Test directly to GKE Node IP 10.2.2.4:80 (Times out as unroutable!):
   curl -v -m 3 http://10.2.2.4:80/
   ```
3. **Observed Data Plane Proof:**
   - `curl -i http://10.2.2.200/ingress-from-alicloud-1` and `...-2` return `HTTP/1.1 200 OK` from `btn-echo-app-cb955885b-mrp75` (`10.2.16.8`) and `btn-echo-app-cb955885b-86ftl` (`10.2.17.12`) with `"x-forwarded-for": "192.168.1.10,10.2.2.200"`.
   - `tcpdump` on `sim-alicloud-vm` confirms the TCP handshake and HTTP payload exchange between `192.168.1.10` and `10.2.2.200:80`:
     ```text
     04:49:06.002789 IP 192.168.1.10.55180 > 10.2.2.200.80: Flags [S], seq 1034096099, win 65320, length 0
     04:49:06.005886 IP 10.2.2.200.80 > 192.168.1.10.55180: Flags [S.], seq 1639618629, ack 1034096100, length 0
     04:49:06.006089 IP 192.168.1.10.55180 > 10.2.2.200.80: Flags [P.], seq 1:95, ack 1, length 94: HTTP: GET /ingress-packet-check HTTP/1.1
     04:49:06.009511 IP 10.2.2.200.80 > 192.168.1.10.55180: Flags [P.], seq 1:171, ack 95, length 170: HTTP: HTTP/1.1 200 OK
     ```
   - `kubectl logs -l app=btn-echo-app --prefix=true` confirms the GKE Pods logged both incoming requests:
     ```text
     [pod/btn-echo-app-cb955885b-mrp75/echo-server] 10.2.20.2 - - [26/Oct/2026 04:43:43] "GET /ingress-from-alicloud-1 HTTP/1.1" 200 -
     [pod/btn-echo-app-cb955885b-86ftl/echo-server] 10.2.20.2 - - [26/Oct/2026 04:43:43] "GET /ingress-from-alicloud-2 HTTP/1.1" 200 -
     ```

---

## 5. Step-by-Step Resource Cleanup Guide (GUI-First + CLI)

When you are ready to tear down the PoC environment, delete resources in **reverse dependency order**:
1. **Load Balancing (`Network Services -> Load balancing`):** Delete `btn-gke-ilb-urlmap` (checking the boxes to also delete the backend service `btn-gke-ilb-bs` and health check `btn-gke-ilb-hc`), then release `btn-gke-ilb-vip` under **VPC network $\rightarrow$ IP addresses**.
2. **GKE Cluster & Test VM:** Delete `btn-gke-island-cluster` under **Kubernetes Engine $\rightarrow$ Clusters** and `sim-alicloud-vm` under **Compute Engine $\rightarrow$ VM instances**.
3. **Cloud NAT & HA VPN:** Delete `btn-private-nat-gw` under **Network Services $\rightarrow$ Cloud NAT**, delete the 4 VPN tunnels and 2 HA VPN gateways under **Network Connectivity $\rightarrow$ VPN**, and delete `btn-gcp-router` and `sim-alicloud-router` under **Cloud Routers**.
4. **VPC Networks & Subnets:** Delete `btn-proxy-only-subnet` and `btn-private-nat-subnet`, then delete `btn-gcp-vpc` and `sim-alicloud-vpc` under **VPC network $\rightarrow$ VPC networks**.

Or run the automated cleanup script:
```bash
./scripts/03-cleanup-all.sh
```
