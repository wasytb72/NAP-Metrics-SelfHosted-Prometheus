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

```bash
kubectl port-forward -n nap-exporter svc/nap-custom-exporter 9110:9110
curl http://localhost:9110/metrics | grep nap_
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
├── deploy.ps1                         # End-to-end Azure + AKS + Prometheus deployment
├── Dockerfile                         # Exporter container image definition
├── exporter.py                        # Prometheus exporter implementation
├── HARDENING_REPORT.md                # Security/reliability review and fixes
├── README.md
├── requirements.txt                   # Python dependencies
├── manifests/
│   ├── nap-custom-exporter.yaml       # Namespace, RBAC, Deployment, Service, ServiceMonitor
│   └── scripts/
└── scripts/
    ├── Install-Choco.ps1              # Chocolatey bootstrap helper
    └── Install-Helm.ps1               # Helm installation helper
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

## Disclaimer

See [DISCLAIMER.md](DISCLAIMER.md) for the open-source usage and third-party license notice.