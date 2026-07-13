#!/usr/bin/env python3
"""
NAP Custom Exporter — Prometheus exporter for AKS Node Auto-Provisioning metrics.

This exporter watches Karpenter NodeClaim CRDs and Kubernetes Node/Event objects
to derive metrics that are normally only available via Azure Managed Prometheus.

It exposes a /metrics endpoint that can be scraped by any self-hosted Prometheus.

Metrics exposed:
  - nap_nodeclaims_total                  Gauge   Total NodeClaims by phase
  - nap_nodeclaims_created_total          Counter NodeClaims created
  - nap_nodeclaims_terminated_total       Counter NodeClaims deleted/terminated
  - nap_nodes_total                       Gauge   NAP-managed nodes by status
  - nap_nodeclaim_capacity_cpu_cores      Gauge   CPU capacity per NodeClaim
  - nap_nodeclaim_capacity_memory_bytes   Gauge   Memory capacity per NodeClaim
  - nap_nodeclaim_age_seconds             Gauge   Age of each NodeClaim
  - nap_events_total                      Counter Karpenter-related events
  - nap_exporter_scrape_duration_seconds  Summary Time to collect metrics
  - nap_exporter_errors_total             Counter Errors during collection

Usage:
  python exporter.py [--port 9110] [--interval 30]

Environment variables:
  NAP_EXPORTER_PORT      Port to listen on (default: 9110)
  NAP_EXPORTER_INTERVAL  Scrape interval in seconds (default: 30)
"""

import argparse
from collections import deque
import logging
import os
import signal
import time
from datetime import datetime, timezone

from kubernetes import client, config
from kubernetes.client.rest import ApiException
from prometheus_client import (
    Counter,
    Gauge,
    Summary,
    start_http_server,
)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("nap-exporter")

# ---------------------------------------------------------------------------
# Prometheus metrics
# ---------------------------------------------------------------------------
NODECLAIMS_TOTAL = Gauge(
    "nap_nodeclaims_total",
    "Number of NodeClaims by phase",
    ["phase", "nodepool"],
)

NODECLAIMS_CREATED = Counter(
    "nap_nodeclaims_created_total",
    "Total number of NodeClaims created (observed)",
    ["nodepool"],
)

NODECLAIMS_TERMINATED = Counter(
    "nap_nodeclaims_terminated_total",
    "Total number of NodeClaims terminated/deleted (observed)",
    ["nodepool"],
)

NAP_NODES_TOTAL = Gauge(
    "nap_nodes_total",
    "Number of NAP-managed nodes by condition status",
    ["status"],
)

NODECLAIM_CPU = Gauge(
    "nap_nodeclaim_capacity_cpu_cores",
    "CPU capacity (cores) reported in NodeClaim status",
    ["nodeclaim", "nodepool"],
)

NODECLAIM_MEMORY = Gauge(
    "nap_nodeclaim_capacity_memory_bytes",
    "Memory capacity (bytes) reported in NodeClaim status",
    ["nodeclaim", "nodepool"],
)

NODECLAIM_AGE = Gauge(
    "nap_nodeclaim_age_seconds",
    "Age of the NodeClaim in seconds",
    ["nodeclaim", "nodepool", "phase"],
)

EVENTS_TOTAL = Counter(
    "nap_events_total",
    "Karpenter/NAP-related events observed",
    ["reason", "type"],
)

SCRAPE_DURATION = Summary(
    "nap_exporter_scrape_duration_seconds",
    "Time spent collecting NAP metrics",
)

ERRORS_TOTAL = Counter(
    "nap_exporter_errors_total",
    "Total collection errors",
    ["source"],
)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
KARPENTER_GROUP = "karpenter.sh"
NODECLAIM_VERSION = "v1"
NODECLAIM_PLURAL = "nodeclaims"

# Labels that identify a NAP-managed node
NAP_NODE_LABELS = [
    "karpenter.sh/registered",
    "karpenter.sh/nodepool",
]

# Event reasons related to Karpenter / NAP
KARPENTER_EVENT_REASONS = {
    "Nominated",
    "Launched",
    "Registered",
    "Initialized",
    "DisruptionBlocked",
    "Disrupting",
    "SpotInterrupted",
    "SpotRebalanced",
    "Unconsolidatable",
    "Drifted",
    "Emptied",
    "Expired",
}


# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------
def _parse_k8s_resource(value: str) -> float:
    """Convert a Kubernetes resource quantity string to a numeric value."""
    if value is None:
        return 0.0
    value = str(value)
    if value.endswith("m"):
        return float(value[:-1]) / 1000.0
    if value.endswith("Ki"):
        return float(value[:-2]) * 1024
    if value.endswith("Mi"):
        return float(value[:-2]) * 1024 * 1024
    if value.endswith("Gi"):
        return float(value[:-2]) * 1024 * 1024 * 1024
    if value.endswith("Ti"):
        return float(value[:-2]) * 1024 * 1024 * 1024 * 1024
    if value.endswith("k"):
        return float(value[:-1]) * 1000
    if value.endswith("M"):
        return float(value[:-1]) * 1_000_000
    if value.endswith("G"):
        return float(value[:-1]) * 1_000_000_000
    try:
        return float(value)
    except ValueError:
        return 0.0


def _age_seconds(creation_timestamp: str) -> float:
    """Return seconds since a Kubernetes creation timestamp."""
    if not creation_timestamp:
        return 0.0
    try:
        created = datetime.fromisoformat(creation_timestamp.replace("Z", "+00:00"))
        return (datetime.now(timezone.utc) - created).total_seconds()
    except (ValueError, TypeError):
        return 0.0


# ---------------------------------------------------------------------------
# Collector
# ---------------------------------------------------------------------------
class NAPCollector:
    """Periodically collects NAP metrics from the Kubernetes API."""

    def __init__(self):
        self._custom_api: client.CustomObjectsApi | None = None
        self._core_api: client.CoreV1Api | None = None
        self._known_nodeclaims: dict[str, str] = {}  # name -> nodepool
        self._seen_event_uids: set[str] = set()
        self._seen_event_uid_order: deque[str] = deque()
        self._seen_event_uid_capacity = 10000
        self._nodeclaims_total_labels: set[tuple[str, str]] = set()
        self._nodeclaim_cpu_labels: set[tuple[str, str]] = set()
        self._nodeclaim_memory_labels: set[tuple[str, str]] = set()
        self._nodeclaim_age_labels: set[tuple[str, str, str]] = set()
        self._nap_nodes_total_labels: set[str] = set()

    # -- initialisation -------------------------------------------------------

    def init_k8s(self):
        """Load kubeconfig or in-cluster config."""
        try:
            config.load_incluster_config()
            log.info("Using in-cluster Kubernetes config")
        except config.ConfigException:
            config.load_kube_config()
            log.info("Using local kubeconfig")
        self._custom_api = client.CustomObjectsApi()
        self._core_api = client.CoreV1Api()

    # -- collection -----------------------------------------------------------

    @SCRAPE_DURATION.time()
    def collect(self):
        """Run a single collection cycle."""
        self._collect_nodeclaims()
        self._collect_nap_nodes()
        self._collect_events()

    def _collect_nodeclaims(self):
        """Fetch all NodeClaim CRs and update gauges / counters."""
        try:
            result = self._custom_api.list_cluster_custom_object(
                group=KARPENTER_GROUP,
                version=NODECLAIM_VERSION,
                plural=NODECLAIM_PLURAL,
            )
        except ApiException as exc:
            if exc.status == 404:
                log.warning("NodeClaim CRD not found — is NAP enabled on this cluster?")
            else:
                log.error("Error listing NodeClaims: %s", exc.reason)
            ERRORS_TOTAL.labels(source="nodeclaims").inc()
            return

        current_claims: dict[str, str] = {}  # name -> nodepool
        phase_counts: dict[tuple[str, str], int] = {}
        current_cpu_labels: set[tuple[str, str]] = set()
        current_memory_labels: set[tuple[str, str]] = set()
        current_age_labels: set[tuple[str, str, str]] = set()

        for item in result.get("items", []):
            metadata = item.get("metadata", {})
            name = metadata.get("name", "unknown")
            labels = metadata.get("labels", {})
            status = item.get("status", {})
            spec = item.get("spec", {})

            nodepool = labels.get("karpenter.sh/nodepool", spec.get("nodePoolRef", {}).get("name", "unknown"))
            phase = _status_phase(status)
            creation = metadata.get("creationTimestamp", "")

            current_claims[name] = nodepool

            # Count by phase/nodepool
            key = (phase, nodepool)
            phase_counts[key] = phase_counts.get(key, 0) + 1

            # Capacity
            capacity = status.get("capacity", {})
            cpu = _parse_k8s_resource(capacity.get("cpu"))
            mem = _parse_k8s_resource(capacity.get("memory"))
            if cpu > 0:
                NODECLAIM_CPU.labels(nodeclaim=name, nodepool=nodepool).set(cpu)
                current_cpu_labels.add((name, nodepool))
            if mem > 0:
                NODECLAIM_MEMORY.labels(nodeclaim=name, nodepool=nodepool).set(mem)
                current_memory_labels.add((name, nodepool))

            # Age
            age = _age_seconds(creation)
            NODECLAIM_AGE.labels(nodeclaim=name, nodepool=nodepool, phase=phase).set(age)
            current_age_labels.add((name, nodepool, phase))

        # Populate gauges
        for (phase, nodepool), count in phase_counts.items():
            NODECLAIMS_TOTAL.labels(phase=phase, nodepool=nodepool).set(count)

        # Remove stale labeled time series for gauges backed by dynamic resources
        current_total_labels = set(phase_counts.keys())
        for phase, nodepool in self._nodeclaims_total_labels - current_total_labels:
            NODECLAIMS_TOTAL.remove(phase, nodepool)
        self._nodeclaims_total_labels = current_total_labels

        for nodeclaim, nodepool in self._nodeclaim_cpu_labels - current_cpu_labels:
            NODECLAIM_CPU.remove(nodeclaim, nodepool)
        self._nodeclaim_cpu_labels = current_cpu_labels

        for nodeclaim, nodepool in self._nodeclaim_memory_labels - current_memory_labels:
            NODECLAIM_MEMORY.remove(nodeclaim, nodepool)
        self._nodeclaim_memory_labels = current_memory_labels

        for nodeclaim, nodepool, phase in self._nodeclaim_age_labels - current_age_labels:
            NODECLAIM_AGE.remove(nodeclaim, nodepool, phase)
        self._nodeclaim_age_labels = current_age_labels

        # Detect created / terminated (skip first run)
        current_names = set(current_claims.keys())
        known_names = set(self._known_nodeclaims.keys())

        if self._known_nodeclaims:
            for name in current_names - known_names:
                pool = current_claims.get(name, "unknown")
                NODECLAIMS_CREATED.labels(nodepool=pool).inc()
            for name in known_names - current_names:
                pool = self._known_nodeclaims.get(name, "unknown")
                NODECLAIMS_TERMINATED.labels(nodepool=pool).inc()

        self._known_nodeclaims = current_claims
        log.debug("NodeClaims: %d active, %d new, %d gone",
                  len(current_names), len(current_names - known_names), len(known_names - current_names))

    def _collect_nap_nodes(self):
        """Count nodes that were provisioned by NAP/Karpenter."""
        try:
            nodes = self._core_api.list_node()
        except ApiException as exc:
            log.error("Error listing nodes: %s", exc.reason)
            ERRORS_TOTAL.labels(source="nodes").inc()
            return

        counts: dict[str, int] = {}
        for node in nodes.items:
            node_labels = node.metadata.labels or {}
            is_nap = any(lbl in node_labels for lbl in NAP_NODE_LABELS)
            if not is_nap:
                continue
            status = "Ready"
            for cond in node.status.conditions or []:
                if cond.type == "Ready":
                    status = "Ready" if cond.status == "True" else "NotReady"
                    break
            counts[status] = counts.get(status, 0) + 1

        for status, count in counts.items():
            NAP_NODES_TOTAL.labels(status=status).set(count)

        current_status_labels = set(counts.keys())
        for status in self._nap_nodes_total_labels - current_status_labels:
            NAP_NODES_TOTAL.remove(status)
        self._nap_nodes_total_labels = current_status_labels

    def _collect_events(self):
        """Scan events for Karpenter-related reasons, deduplicating by UID."""
        continue_token = None
        pages = 0
        max_pages = 10

        while pages < max_pages:
            pages += 1
            try:
                events = self._core_api.list_event_for_all_namespaces(
                    limit=200,
                    _continue=continue_token,
                    _request_timeout=10,
                )
            except ApiException as exc:
                log.error("Error listing events: %s", exc.reason)
                ERRORS_TOTAL.labels(source="events").inc()
                return

            for ev in events.items:
                reason = ev.reason or ""
                if reason not in KARPENTER_EVENT_REASONS:
                    continue
                uid = ev.metadata.uid or ""
                if not uid or uid in self._seen_event_uids:
                    continue
                self._remember_event_uid(uid)
                ev_type = ev.type or "Normal"
                EVENTS_TOTAL.labels(reason=reason, type=ev_type).inc()

            metadata = getattr(events, "metadata", None)
            continue_token = getattr(metadata, "_continue", None)
            if not continue_token:
                return

        log.warning("Event pagination stopped after %d pages; some events may be deferred", max_pages)

    def _remember_event_uid(self, uid: str):
        """Track event UIDs with deterministic FIFO eviction."""
        self._seen_event_uids.add(uid)
        self._seen_event_uid_order.append(uid)

        while len(self._seen_event_uids) > self._seen_event_uid_capacity:
            oldest_uid = self._seen_event_uid_order.popleft()
            self._seen_event_uids.discard(oldest_uid)


def _status_phase(status: dict) -> str:
    """Extract a human-readable phase from a NodeClaim status."""
    conditions = status.get("conditions", [])
    for cond in conditions:
        if cond.get("type") == "Ready" and cond.get("status") == "True":
            return "Ready"
    if conditions:
        return "Pending"
    return "Unknown"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="NAP Custom Prometheus Exporter")
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("NAP_EXPORTER_PORT", "9110")),
        help="HTTP port for /metrics (default 9110)",
    )
    parser.add_argument(
        "--interval",
        type=int,
        default=int(os.environ.get("NAP_EXPORTER_INTERVAL", "30")),
        help="Collection interval in seconds (default 30)",
    )
    args = parser.parse_args()

    if args.interval <= 0:
        parser.error("--interval must be a positive integer")

    collector = NAPCollector()
    collector.init_k8s()

    log.info("Starting NAP custom exporter on :%d (interval=%ds)", args.port, args.interval)
    start_http_server(args.port)

    # Graceful shutdown
    running = True

    def _shutdown(signum, _frame):
        nonlocal running
        log.info("Received signal %s, shutting down", signum)
        running = False

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    while running:
        try:
            collector.collect()
        except Exception:
            log.exception("Unhandled error during collection")
            ERRORS_TOTAL.labels(source="collect").inc()
        time.sleep(args.interval)

    log.info("Exporter stopped")


if __name__ == "__main__":
    main()
