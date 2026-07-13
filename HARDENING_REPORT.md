# NAP Metrics Exporter Hardening Report

Date: 2026-07-13
Repository: NAP-Metrics-SelfHosted-Prometheus

## Scope
This report documents:
- What each script and key file does.
- Risks and likely failure modes identified during review.
- Hardening changes applied across two patch passes.
- Validation status and residual risk.

## Repository Behavior Summary

### exporter.py
Purpose:
- Runs a Prometheus metrics endpoint for AKS NAP/Karpenter derived metrics.

Main flow:
1. Load Kubernetes config (in-cluster first, then local kubeconfig fallback).
2. Start HTTP metrics server on configured port.
3. Poll every interval seconds:
   - NodeClaim CRDs for capacity, age, status, creation/termination counters.
   - Kubernetes Nodes to count NAP-managed Ready or NotReady nodes.
   - Kubernetes Events to count selected Karpenter reasons.
4. Export metrics for scraping by Prometheus.

### deploy.ps1
Purpose:
- Provision Azure infrastructure and deploy exporter end-to-end.

Main flow:
1. Validate required tools (az, docker, helm as needed).
2. Validate Azure CLI version and target AKS version availability.
3. Create resource group, VNet, subnets, managed identity, ACR.
4. Build and push exporter image (unless skipped).
5. Create AKS with NAP enabled (unless skipped).
6. Install kube-prometheus-stack (unless skipped).
7. Apply exporter manifest, set deployment image, check rollout.

### manifests/nap-custom-exporter.yaml
Purpose:
- Kubernetes objects for exporter runtime and scrape integration:
  - Namespace
  - ServiceAccount and RBAC
  - Deployment and Service
  - ServiceMonitor

### scripts/Install-Choco.ps1
Purpose:
- Bootstrap Chocolatey.

### scripts/Install-Helm.ps1
Purpose:
- Install Helm via Chocolatey.

## Findings Identified

### High
1. ServiceMonitor release selector mismatch risk
- Impact: Exporter may not be scraped when Prometheus release name is customized.
- Root cause: Manifest label used fixed release value while deploy script allows configurable release name.

### Medium
2. Helm repo add non-idempotent behavior
- Impact: Re-running deployment can fail when repository already exists.

3. Use of private Prometheus client internals
- Impact: Breakage risk with library upgrades and brittle collector behavior.

4. Event dedupe trimming used unordered set slicing
- Impact: Duplicate counts or missed dedupe after trimming.

5. Event fetch used single page only
- Impact: Event loss under high cluster event volume.

### Low
6. Interval accepted invalid values
- Impact: Negative values can fail sleep; zero can cause high-frequency loop behavior.

7. Helper scripts are less automation-safe and use remote script execution pattern
- Impact: Potential interactive install hangs and supply chain hygiene concerns.

## Hardening Changes Applied

## Pass 1 (already applied)

### A. Removed reliance on private metric internals
File: exporter.py
- Replaced direct access to private metric fields with explicit label tracking and stale-label removal using metric remove methods.
- Added per-metric label state tracking sets.

### B. Enforced positive interval validation
File: exporter.py
- Added argument validation to require interval > 0.

### C. Made Helm repo setup idempotent
File: deploy.ps1
- Updated helm repo add to use force-update.

### D. Aligned ServiceMonitor release label during deploy
File: deploy.ps1
- After applying manifest, script now checks for ServiceMonitor and updates release label to the configured Prometheus release name.

## Pass 2 (this pass)

### E. Added paginated event retrieval
File: exporter.py
- Event collection now pages through list_event_for_all_namespaces using continue tokens.
- Added a bounded page limit to keep collection runtime controlled.
- Logs warning when page cap is hit.

### F. Added deterministic FIFO eviction for dedupe cache
File: exporter.py
- Replaced unordered set slicing with ordered UID tracking using deque.
- Added helper method to record UIDs and evict oldest deterministically when capacity is exceeded.

## Current Validation Status

Validation executed:
- Editor diagnostics check on modified files in prior pass.

Observed status:
- deploy.ps1 has no static diagnostics issues.
- exporter.py diagnostics in this environment only report unresolved local imports when Python deps are not installed in active interpreter.

Notes:
- Those import diagnostics are environment/dependency related, not syntax errors in patched logic.

## Residual Risks and Recommendations

1. Event page cap tradeoff
- Current cap prevents runaway collection time but may still defer processing in very high event volume clusters.
- Recommendation: make max pages configurable via environment variable if needed.

2. Helper install scripts
- scripts/Install-Helm.ps1 can be made non-interactive with explicit flags.
- scripts/Install-Choco.ps1 uses a common but high-trust bootstrap pattern.

3. Manifest image default
- Deployment manifest uses a fixed image reference suitable for sample/demo; deploy script overrides image during rollout.
- Recommendation: document this clearly in README to avoid confusion in manual apply workflows.

## Suggested Verification Steps

1. Local static checks
- Run Python lint/type checks in a configured environment with dependencies installed.

2. Functional smoke test in cluster
- Deploy exporter and verify pod readiness.
- Verify metrics endpoint responds.
- Verify ServiceMonitor labels match Prometheus release.

3. Event behavior test
- Generate Karpenter-relevant events and confirm nap_events_total increments.
- Confirm no duplicate spikes after repeated collection cycles.

## Files Changed Across Hardening
- exporter.py
- deploy.ps1
- HARDENING_REPORT.md
