# NAP Custom Exporter

Prometheus exporter for **AKS Node Auto-Provisioning (NAP)** metrics in clusters with self-hosted Prometheus.

## Why?

When using NAP on AKS, Karpenter control plane metrics are **only available via Azure Managed Prometheus** ([issue #612](https://github.com/Azure/karpenter-provider-azure/issues/612)). If you can't or don't want to use Azure Managed Prometheus, this exporter is your alternative: it watches `NodeClaim` resources (Karpenter CRD) and Kubernetes events to derive equivalent metrics and expose them at `:9110/metrics`.

> **⚠️ Note**: These are metrics **derived** from the Kubernetes API, not native Karpenter control plane metrics. Some internal metrics (such as scheduling times) cannot be replicated. For the full set, the official path is [Azure Managed Prometheus](https://learn.microsoft.com/en-us/azure/azure-monitor/containers/prometheus-metrics-scrape-default#controlplane-node-auto-provisioning).

## Exposed Metrics

| Metric | Type | Description |
|---|---|---|
| `nap_nodeclaims_total` | Gauge | Active NodeClaims by phase and nodepool |
| `nap_nodeclaims_created_total` | Counter | NodeClaims created (observed) |
| `nap_nodeclaims_terminated_total` | Counter | NodeClaims deleted (observed) |
| `nap_nodes_total` | Gauge | NAP nodes by status (Ready/NotReady) |
| `nap_nodeclaim_capacity_cpu_cores` | Gauge | CPU capacity per NodeClaim |
| `nap_nodeclaim_capacity_memory_bytes` | Gauge | Memory capacity per NodeClaim |
| `nap_nodeclaim_age_seconds` | Gauge | Age of each NodeClaim |
| `nap_events_total` | Counter | Karpenter events (Launched, Disrupting…) |
| `nap_exporter_scrape_duration_seconds` | Summary | Duration of each collection cycle |
| `nap_exporter_errors_total` | Counter | Errors during collection |

## Architecture

```
┌─────────────────────────────────────────────────┐
│              AKS Cluster with NAP               │
│                                                  │
│   ┌─────────────────┐   ┌────────────────────┐  │
│   │  NAP Custom      │   │  Prometheus        │  │
│   │  Exporter        │──▶│  (self-hosted)     │  │
│   │  :9110/metrics   │   │                    │  │
│   └────────┬────────┘   └────────┬───────────┘  │
│            │                      │              │
│   Queries K8s API:               ▼              │
│   • NodeClaim CRDs        ┌──────────┐         │
│   • Nodes                 │ Grafana  │         │
│   • Events                └──────────┘         │
└─────────────────────────────────────────────────┘
```

## Quick Start

### Azure deployment with AKS + NAP/Karpenter

Use [deploy.ps1](c:\Users\dawahby\MyRepos\NAP-Metrics-SelfHosted-Prometheus\deploy.ps1) to provision Azure infrastructure with Azure CLI and deploy this exporter end to end:

```powershell
.\deploy.ps1 -SubscriptionId <subscription-id> -Location <location>
```

The script creates:
- Resource group
- Virtual network with node subnet and delegated API server subnet
- User-assigned managed identity for AKS
- Azure Container Registry
- AKS cluster on Kubernetes `1.31.0`
- AKS Node Auto-Provisioning in `Auto` mode, which provides managed Karpenter with the default `default` and `system-surge` node pools
- Self-hosted Prometheus via `kube-prometheus-stack` Helm chart using standard chart values
- The exporter image in ACR and the Kubernetes deployment from [manifests/nap-custom-exporter.yaml](c:\Users\dawahby\MyRepos\NAP-Metrics-SelfHosted-Prometheus\manifests\nap-custom-exporter.yaml)

Requirements:
- Azure CLI `2.76.0` or later
- Docker
- Helm
- Azure login with permission to create RBAC assignments and AKS resources

Notes:
- The script uses AKS-managed Karpenter through NAP rather than installing the open-source Karpenter Helm chart separately. That is the supported AKS path and avoids conflicting controllers.
- The self-hosted Prometheus install creates the `ServiceMonitor` CRD before the exporter manifest is applied.

### 1. Build and push the image

```bash
docker build -t <your-registry>/nap-custom-exporter:latest .
docker push <your-registry>/nap-custom-exporter:latest
```

### 2. Deploy to the cluster

Update the image in `manifests/nap-custom-exporter.yaml` and apply:

```bash
kubectl apply -f manifests/nap-custom-exporter.yaml
```

This creates:
- **Namespace** `nap-exporter`
- **ServiceAccount** + **ClusterRole** + **ClusterRoleBinding** (read access for NodeClaims, Nodes, Events)
- **Deployment** with one replica of the exporter
- **Service** ClusterIP on port 9110
- **ServiceMonitor** for auto-discovery with kube-prometheus-stack

### 3. Verify metrics

```powershell
kubectl port-forward -n nap-exporter svc/nap-custom-exporter 9110:9110
curl http://localhost:9110/metrics | select-string nap_
```

### 4. Verify Prometheus Ingestion

Collector and ingestion verification flow:

1. The collector exposes derived NAP metrics on `http://<collector>:9110/metrics` from Kubernetes `NodeClaim`, `Node`, and `Event` resources.
2. The `ServiceMonitor` in `nap-exporter` instructs kube-prometheus-stack to scrape `/metrics` every 30 seconds.
3. Verify the scrape target is active in Prometheus API:

```powershell
kubectl -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090
curl "http://localhost:9090/api/v1/targets?state=active" | select-string nap-custom-exporter
```

4. Verify ingestion by querying a collector metric through Prometheus API:

```powershell
curl.exe "http://localhost:9090/api/v1/query?query=nap_nodeclaims_total"
```

## Prometheus Query API with curl

After port-forwarding Prometheus:

```bash
kubectl -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090
```

Use these curl patterns to consume the Prometheus HTTP API.

If you are in PowerShell, use `curl.exe` (not `curl`) to avoid alias behavior.

### 1. Instant query (single point in time)

```powerhell
curl.exe --get "http://localhost:9090/api/v1/query" --data-urlencode "query=nap_nodes_total"
```

```bash
curl.exe --get "http://localhost:9090/api/v1/query" --data-urlencode "query=nap_nodes_total"
```
### 2. Instant query with labels and aggregation

```powershell
curl.exe --get "http://localhost:9090/api/v1/query" --data-urlencode "query=sum by (status) (nap_nodes_total)"
```

```bash
curl --get "http://localhost:9090/api/v1/query" --data-urlencode "query=sum by (status) (nap_nodes_total)"
```

### 3. Range query (time series over a window)


```powershell
curl.exe --get "http://localhost:9090/api/v1/query_range" --data-urlencode 'query=nap_nodeclaims_total{phase="Ready"}' --data-urlencode "start=2026-07-16T10:00:00Z" --data-urlencode "end=2026-07-16T11:00:00Z" --data-urlencode "step=30s"
```

### 4. Check API health quickly

```bash
curl "http://localhost:9090/-/healthy"
curl "http://localhost:9090/-/ready"
```

```powershell
curl.exe "http://localhost:9090/-/healthy"
curl.exe "http://localhost:9090/-/ready"
```

### 5. Return only parsed JSON values (optional with jq)

```bash
curr --get "http://localhost:9090/api/v1/query" --data-urlencode "query=nap_events_total" | jq '.data.result'
```

```powershell
curl.exe --get "http://localhost:9090/api/v1/query" --data-urlencode "query=nap_nodes_total" | jq '.data.result'
```


Notes:
- Prefer `--get` + `--data-urlencode` for PromQL expressions with spaces, braces, or quotes.
- For `query_range`, `step` can be `15s`, `30s`, `1m`, etc.
- The API response shape is `{ "status": "success", "data": { "resultType": ..., "result": [...] } }`.

### PowerShell alternative (Invoke-RestMethod)

A reusable script is available at `scripts/query-prometheus.ps1`.

Instant query:

```powershell
./scripts/query-prometheus.ps1 -Query 'nap_nodes_total' -asjson
```

Range query:

```powershell
./scripts/query-prometheus.ps1 -Mode query_range `
  -Query 'nap_nodeclaims_total{phase="Ready"}' `
  -Start '2026-07-16T10:00:00Z' `
  -End '2026-07-16T11:00:00Z' `
  -Step '30s'
```

Raw JSON response:

```powershell
./scripts/query-prometheus.ps1 -Query 'nap_events_total' -AsJson
```

## Configuration

| Environment Variable / Flag | Default | Description |
|---|---|---|
| `NAP_EXPORTER_PORT` / `--port` | `9110` | Port for the `/metrics` endpoint |
| `NAP_EXPORTER_INTERVAL` / `--interval` | `30` | Collection interval in seconds |

## How It Works

1. Connects to the Kubernetes API server (in-cluster or local kubeconfig)
2. Every `--interval` seconds:
   - Lists **NodeClaim** CRDs (`karpenter.sh/v1`) → status, capacity, and age gauges
   - Detects NodeClaim creations/deletions → counters
   - Lists **Nodes** with Karpenter labels → NAP node gauge
   - Lists **Events** → Karpenter event counter (deduplicated by UID)
3. Exposes everything in Prometheus format at `:9110/metrics`

## Required RBAC Permissions

```yaml
rules:
  - apiGroups: ["karpenter.sh"]
    resources: ["nodeclaims"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get", "list", "watch"]
```

Included in `manifests/nap-custom-exporter.yaml`.

## Repository Structure

```
.
├── .gitignore
├── DISCLAIMER.md                      # Open-source usage and third-party license notice
├── Dockerfile                         # Exporter container image definition
├── exporter.py                        # Prometheus exporter implementation
├── HARDENING_REPORT.md                # Security/reliability review and fixes
├── README.md
├── requirements.txt                   # Python dependencies
└── scripts/
    ├── deploy.ps1                     # End-to-end Azure + AKS + Prometheus deployment
    ├── env.ps1                        # Local environment variables (ignored from git)
    ├── env.sample                     # Environment variable template
    ├── Install-Choco.ps1              # Chocolatey bootstrap helper
    ├── Install-Helm.ps1               # Helm installation helper
    └── manifests/
        └── nap-custom-exporter.yaml   # Namespace, RBAC, Deployment, Service, ServiceMonitor
```

## Local Execution (Development)

```bash
pip install -r requirements.txt
python exporter.py --port 9110 --interval 15
# Uses your local kubeconfig to connect to the cluster
```

## Prerequisites

- AKS cluster with **NAP enabled** (`--node-provisioning-mode Auto`)
- Self-hosted Prometheus (e.g., [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack))
- The `NodeClaim` CRD (`karpenter.sh/v1`) must exist in the cluster (created when NAP is enabled)

Notes for `nap_*` but total:
- This metric only counts nodes created by AKS NAP/Karpenter (nodes with `karpenter.sh/*` labels).
- The default AKS system node pool (`systemnp`) is not NAP-managed, so those nodes are excluded by design.
- To populate this metric, run workload that triggers NAP scale-out so NodeClaims are created and nodes are provisioned in NAP-managed pools (for example, `default` or `system-surge`).

## Acknowledgments

Special thanks to the original author, **josemzr**, for the foundational work behind this project.

## Disclaimer

See [DISCLAIMER.md](DISCLAIMER.md) for the open-source usage and third-party license notice.