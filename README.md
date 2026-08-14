# Kong Gateway Observability Reference

A minimal, working reference for wiring up metrics, logs, and traces from Kong Gateway (Konnect hybrid mode) into Prometheus, Loki, and Tempo — visualized in Grafana, with trace-to-log correlation working out of the box.

Spin up a local kind cluster with a real Konnect control plane, generate traffic, and see all three signals end to end in one screen.

## Contents

- [What this sets up](#what-this-sets-up)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Kong Gateway version requirement](#kong-gateway-version-requirement)
- [Not included: request/response body capture](#not-included-requestresponse-body-capture)
- [Common pitfalls this reference avoids](#common-pitfalls-this-reference-avoids)
- [Reproducing the missing-metrics symptom on demand](#reproducing-the-missing-metrics-symptom-on-demand)
- [Useful tasks](#useful-tasks)
- [In-cluster FQDNs](#in-cluster-fqdns)
- [Taking it to production](#taking-it-to-production)
- [Cleanup](#cleanup)
- [Notes](#notes)

## What this sets up

| Component | Role |
|---|---|
| Kong Gateway (Konnect hybrid data plane) | Proxies traffic. Exports metrics via the `prometheus` plugin; traces and structured access logs via the `opentelemetry` plugin |
| OTel Collector | Receives Kong's OTLP traces and access logs, tail-samples traces, forwards to Tempo and Loki |
| Grafana Alloy | DaemonSet tailing Kong's raw pod stdout/stderr (nginx error log, startup output) into Loki as a second, separate log stream |
| Prometheus (kube-prometheus-stack) | Scrapes Kong's `/metrics` endpoint via a ServiceMonitor |
| Loki | Stores logs — both the structured OTLP stream and Alloy's raw stdout stream |
| Tempo | Stores traces, with metrics-generator enabled for TraceQL metrics queries and service graphs |
| Grafana | Dashboards, with Loki ↔ Tempo trace/log correlation pre-configured |
| MetalLB | Gives Services real IPs on the local kind cluster — no `kubectl port-forward` needed |

## Prerequisites

- `kind`, `kubectl`, `helm`, [`task`](https://taskfile.dev) (go-task)
- [`deck`](https://github.com/Kong/deck) CLI
- A Kong Konnect account and a Personal Access Token ([get one here](https://cloud.konghq.com/global/account/tokens))
- Helm repos added: `kong`, `grafana`, `open-telemetry`, `prometheus-community`, `metallb`

## Quick start

```bash
cp .env.example .env
# edit .env — set KONNECT_TOKEN, and KONNECT_SERVER_URL if not eu.api.konghq.com

task up        # full stack: cluster, MetalLB, Prometheus/Grafana, Loki, Tempo,
               # OTel Collector, Grafana Alloy, a real Konnect control plane +
               # Kong DP, decK config, and a burst of test traffic
task validate  # confirms traces, logs, and metrics all arrived
task urls      # prints direct IPs for Grafana / Prometheus / Kong proxy
```

`task --list` shows every available task.

Open Grafana at the URL from `task urls` (login: `admin` / `task grafana-password`), and go to **Explore**:
- **Loki** → query `{service_name="kong-gateway"}` → expand a log line → a "View trace" link appears (via the Derived Field configured on the Loki datasource — see below, this isn't automatic in any Grafana version and must be explicitly configured).
- **Tempo** → search by service `kong-gateway` → open a trace → "Logs for this span" jumps back to the matching log line.

There are **two separate log streams in Loki** — querying the wrong one looks like "logs are missing":
- `{service_name="kong-gateway"}` — structured per-request access logs (method, path, status, latency, etc.), sent by Kong's `opentelemetry` plugin via OTLP.
- `{namespace="kong"}` — Kong's raw container stdout/stderr (nginx error log, startup messages, crashes), shipped by Grafana Alloy.

**To see Alloy's raw log stream specifically:** Grafana → left sidebar → **Explore** → datasource dropdown (top left) → **Loki** → query field → `{namespace="kong"}` → Run query. Narrow further to one container with `{namespace="kong", container="proxy"}`. This is where you'd look for crashes, config-reload errors, or anything that isn't captured in a per-request access log — if a Kong pod is failing to start, this stream (not `{service_name="kong-gateway"}`) is where the error will show up.

Both directions work here because `values-prometheus-stack.yaml` pre-configures them: a Derived Field on the Loki datasource (Loki → Tempo) and `tracesToLogsV2` on the Tempo datasource (Tempo → Loki). If you're wiring this up from scratch on your own Grafana instance, both need to be set up explicitly — see [Grafana's Loki derived fields docs](https://grafana.com/docs/grafana/latest/datasources/loki/configure-loki-data-source/) and [Tempo trace-to-logs docs](https://grafana.com/docs/grafana/latest/datasources/tempo/configure-tempo-data-source/configure-trace-to-logs/).

> **The name matters.** kube-prometheus-stack must be installed with the Helm release name `kube-prometheus-stack` — this reference's `Taskfile.yaml` sets it via the `MON_RELEASE` variable, and everything downstream depends on it matching exactly. Prometheus only scrapes ServiceMonitors carrying the label `release: kube-prometheus-stack`, and Kong's chart is told to set exactly that label (`values-dp.yaml.tpl`'s `serviceMonitor.labels.release`). Rename one side without the other and Kong's metrics target silently never appears — no error anywhere, it just isn't there. If you're adapting this to your own setup and renaming the Prometheus release, update `serviceMonitor.labels.release` on the Kong side to match.

## Kong Gateway version requirement

The `opentelemetry` plugin's OTLP access-log export (`access_logs.endpoint` / `access_logs_endpoint` — the mechanism this reference uses to get per-request access logs into Loki) requires a minimum Kong Gateway version:

| Kong Gateway version | OTLP access logs |
|---|---|
| < 3.13 | Not supported — the feature doesn't exist. Traces and metrics work fine; logs cannot. |
| 3.13.x | Supported via the flat field `access_logs_endpoint` |
| 3.14.x+ | Supported via the nested field `access_logs.endpoint` (this reference's `kong.yaml`). `access_logs_endpoint` still works but is deprecated. |

Set the version via `KONG_IMAGE_TAG` in `.env`. If you're troubleshooting a real deployment that's missing logs despite an otherwise-correct config, confirm the actual running version first — `helm list`'s "APP VERSION" column reflects the chart's declared default, not necessarily what's actually deployed:

```bash
kubectl exec -n <namespace> <kong-dp-pod> -c proxy -- kong version
```

## Not included: request/response body capture

The `opentelemetry` plugin only captures request/response *metadata* by default (method, path, status, latency, etc.) — not the actual body content. Capturing bodies is possible but deliberately **not built into this reference**, for reference only if you need it later:

- `opentelemetry.config.custom_attributes_by_lua` — the only way to add arbitrary fields to the access log (plain `set_serialize_value()` additions are dropped).
- A `pre-function` plugin that calls `kong.service.request.enable_buffering()` and reads `kong.request.get_raw_body()` / `kong.service.response.get_raw_body()`, storing each as parsed JSON if it parses, otherwise the raw string.

**Why this is left out here, not just an oversight:**
- Ships every request/response body to Loki — bodies routinely contain passwords, tokens, PII, and pull your observability stack into GDPR/PCI/HIPAA compliance scope.
- `enable_buffering()` disables response streaming — breaks SSE, large downloads, websockets.
- Meaningfully increases Loki ingest volume and gateway memory/latency per request.
- Doesn't handle binary or gzipped bodies — `get_raw_body()` returns them un-decoded, which shows up as garbage in the log.

If you need this for a specific debugging session: scope both plugins to one route (not global), mask sensitive fields, keep retention short, and remove them when done.

## Common pitfalls this reference avoids

**ServiceMonitor `release` label mismatch.** See the callout above — this is the single most common cause of "no Kong metrics" reports.

**Loki OTLP label requirement.** Loki's OTLP ingest endpoint requires every log stream to carry at least one index label, or it rejects the write with `HTTP 400: at least one label pair is required per stream`. Loki's built-in defaults already promote `service.name` (set here via `kong.yaml`'s `resource_attributes.service.name`) to a label — don't override `otlp_config.resource_attributes` in `values-loki.yaml` unless you also provide a replacement list.

**Grafana template variables need double-dollar escaping in Helm values.** The Loki→Tempo and Tempo→Loki correlation config uses Grafana template variables like `${__value.raw}` and `${__trace.traceId}`. Inside a Helm values file these must be written as `$${...}` (double dollar) — a single `$` gets silently consumed by Helm's own templating before Grafana ever sees it, and the correlation link resolves to an empty string instead of the trace ID. See `values-prometheus-stack.yaml` for the working, correctly-escaped version.

**Tempo's metrics-generator is only needed if you use Traces Drilldown or TraceQL metrics queries (`rate()`, etc.) — not for basic trace search or trace/log correlation.** Confirmed by testing directly: with `metricsGenerator` removed, plain Explore search, opening traces, and Loki↔Tempo correlation all still work fine. It's only Grafana's **Traces Drilldown app** specifically that requires it — without it, Drilldown fails with `error finding generators: empty ring`, and further needs the `local-blocks` processor specifically (`localblocks processor not found` otherwise). `values-tempo.yaml` enables `metricsGenerator` with all three processors (`service-graphs`, `span-metrics`, `local-blocks`) so Traces Drilldown works out of the box here — if you don't need Drilldown, this block can be removed entirely.

**The OTel Collector needs a `health_check` extension when deployed via the `open-telemetry/opentelemetry-collector` Helm chart** (this reference's deployment method). That chart's default liveness/readiness probes expect one; without it, the Collector pod crash-loops on failed health checks even though the actual pipeline config is correct. `values-otel-collector.yaml` sets `extensions.health_check` and `service.extensions: [health_check]` for exactly this reason. If you're adapting the Collector config from elsewhere and it's missing this, check `kubectl get pods -l app.kubernetes.io/name=opentelemetry-collector` for a high restart count as the tell.

**Grafana Alloy uses `loki.source.kubernetes`, not the older hostPath-mount pattern.** Older Grafana Agent/Alloy examples tail `/var/log/pods` via a privileged container with `runAsUser: 0`. `values-alloy.yaml` uses the current recommended approach instead — `loki.source.kubernetes` tails pod logs via the Kubernetes API directly, so it needs only the standard `pods`/`pods/log`/`namespaces` RBAC grants (already included when `rbac.create: true`, the chart default) and no privileged security context. `discovery.kubernetes` is scoped to `spec.nodeName` so each Alloy DaemonSet pod only watches pods on its own node — without that scoping, every Alloy pod would watch every pod cluster-wide.

**Diagnosing "Kong reports success but nothing shows up downstream."** Kong's own logs only confirm that its immediate HTTP peer (the Collector) returned `2xx` — they say nothing about whether the Collector's own exporters (to Loki, to Tempo) succeeded. If a signal is missing, check the Collector's logs next:

```bash
kubectl logs -n observability -l app.kubernetes.io/name=opentelemetry-collector --since=2m
```

## Reproducing the missing-metrics symptom on demand

```bash
task break-servicemonitor-label   # removes the release label
task validate                     # metrics target now shows ABSENT
task fix-servicemonitor-label     # restores it
```

## Useful tasks

| Task | What it does |
|---|---|
| `task status` | Quick health check across Kong, the observability namespace, ServiceMonitors, and Konnect DP sync state |
| `task check-kong-version` | Execs into the running pod and prints the actual Kong Gateway version |
| `task konnect-nodes` | Shows DP connection/sync status against the real Konnect control plane |
| `task grafana-password` | Prints the Grafana admin password |
| `task down` / `task reset` | Tear down the kind cluster (`reset` also rebuilds). Does not delete the Konnect control plane. |
| `task konnect-teardown` | Deletes the Konnect control plane created by `task konnect-setup` |

## In-cluster FQDNs

Every hostname the components use to reach each other. Useful when adapting this config to a different cluster or namespace layout, or troubleshooting connectivity directly.

| Component | In-cluster FQDN | Port | Used by |
|---|---|---|---|
| Kong Gateway proxy | `kong-kong-proxy.kong.svc.cluster.local` | `80` (HTTP), `443` (HTTPS) | External traffic, `task generate-traffic` |
| Kong Gateway status/metrics | `kong-kong-proxy.kong.svc.cluster.local` | `8100` (container port, not exposed on the Service) | Prometheus ServiceMonitor scrape |
| OTel Collector (OTLP receiver) | `otel-collector-opentelemetry-collector.observability.svc.cluster.local` | `4318` (HTTP), `4317` (gRPC) | Kong's `opentelemetry` plugin (`traces_endpoint`, `access_logs.endpoint`) |
| Tempo (OTLP receiver) | `tempo.observability.svc.cluster.local` | `4317` (gRPC) | OTel Collector's `otlp/tempo` exporter |
| Tempo (query API) | `tempo.observability.svc.cluster.local` | `3200` | Grafana Tempo datasource, `validate.sh` |
| Loki gateway (OTLP + query ingest + push) | `loki-gateway.observability.svc.cluster.local` | `80` | OTel Collector's `otlphttp/loki` exporter, Grafana Alloy's `loki.write`, Grafana Loki datasource, `validate.sh` |
| Prometheus | `kube-prometheus-stack-prometheus.observability.svc.cluster.local` | `9090` | Grafana Prometheus datasource, Tempo's metrics-generator remote-write, `validate.sh` |
| Grafana | `kube-prometheus-stack-grafana.observability.svc.cluster.local` | `80` | Browser access, via the MetalLB external IP from `task urls` |

External access (MetalLB-assigned LoadBalancer IPs, printed by `task urls`): Grafana and Kong's proxy each get a real IP reachable from your machine — no port-forwarding needed.

## Taking it to production

This reference is tuned for a small demo cluster. Before running any of it for real, change:

- **Trace sampling.** `values-otel-collector.yaml`'s `tail_sampling` baseline is 100% (every trace kept), so every log line's "View trace" link always resolves. In production, lower the baseline (keeping errors/slow requests at 100%) — accept that a sampled-out request's log will reference a trace Tempo no longer holds.
- **Body logging.** Not included here at all — see [above](#not-included-requestresponse-body-capture). If you add it, scope to specific routes, not globally.
- **Storage and sizing.** `values-loki.yaml` and `values-tempo.yaml` use local filesystem storage, no persistence, and testing-only schema shortcuts (`useTestSchema`) — see the ⚠️ warnings in each file and in Notes below. Real deployments need object storage (S3/GCS/Azure), proper retention, and replication.

## Cleanup

```bash
task down              # removes the local kind cluster
task konnect-teardown  # also deletes the Konnect control plane
```

## Notes

- This targets a kind cluster with MetalLB for LoadBalancer IPs — no port-forwarding required. On a different cluster type, adjust `metallb-config.yaml`'s address pool, or skip MetalLB and use your platform's native LoadBalancer/Ingress.
- `values-dp.yaml.tpl` is the committable Kong DP values template. `konnect-setup.sh` renders it into `values-dp.yaml` (gitignored) via `envsubst`, filling in the real Konnect control-plane endpoint hostnames — which it also writes to `.env` as `CONTROL_PLANE_ENDPOINT` / `CONTROL_PLANE_TELEMETRY` after creating the control plane. Never commit `.env` or `values-dp.yaml`.
- **`values-loki.yaml` uses `useTestSchema: true` and `storage: filesystem` — testing/demo shortcuts, not production config.** A production Loki deployment needs an explicit `schemaConfig` (retention period, index prefix, storage backend) and almost certainly real object storage (S3/GCS/Azure), not the local filesystem. Don't copy this file as-is into a production environment — see [Loki's schema_config docs](https://grafana.com/docs/loki/latest/configuration/#schema_config).
- **`values-tempo.yaml` uses `persistence.enabled: false` and the chart's default local-filesystem trace storage — also testing/demo only.** Traces are stored in a non-persistent volume and are lost on every pod restart. A production Tempo deployment needs `persistence.enabled: true` with a real PVC, and almost certainly a real object storage backend (S3/GCS/Azure) instead of local disk — see [Tempo's storage docs](https://grafana.com/docs/tempo/latest/configuration/#storage).
