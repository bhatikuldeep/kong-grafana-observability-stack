# Kong Gateway DP values for Konnect hybrid mode. Template — rendered into
# values-dp.yaml (gitignored, contains real hostnames) by konnect-setup.sh
# via envsubst, using values from .env.
image:
  repository: kong/kong-gateway
  tag: "${KONG_IMAGE_TAG}"

env:
  role: data_plane
  database: "off"
  konnect_mode: "on"
  vitals: "off"

  cluster_control_plane: "${CONTROL_PLANE_ENDPOINT}"
  cluster_server_name: "${CONTROL_PLANE_ENDPOINT}"
  cluster_telemetry_endpoint: "${CONTROL_PLANE_TELEMETRY}:443"
  cluster_telemetry_server_name: "${CONTROL_PLANE_TELEMETRY}"
  cluster_mtls: pki
  cluster_cert: /etc/secrets/kong-cluster-cert/tls.crt
  cluster_cert_key: /etc/secrets/kong-cluster-cert/tls.key
  lua_ssl_trusted_certificate: system

  # Lets the pre-function plugin require cjson.safe for body parsing.
  # Requires Kong Gateway 3.10+.
  untrusted_lua: strict

  # Without this the OTel plugin exports no spans and Tempo stays empty.
  tracing_instrumentations: all
  tracing_sampling_rate: "1.0"

  # Per-request logging happens via the OTLP access log path; nginx's own
  # access log is turned off so it isn't logged twice.
  proxy_access_log: "off"

secretVolumes:
  - kong-cluster-cert

admin:
  enabled: false
manager:
  enabled: false
ingressController:
  enabled: false

proxy:
  enabled: true
  type: LoadBalancer
  http:
    enabled: true
  tls:
    enabled: true

# Status listener serves /metrics on :8100.
status:
  enabled: true
  http:
    enabled: true
    containerPort: 8100

# ServiceMonitor — the release label MUST match the kube-prometheus-stack
# Helm release name, or Prometheus will silently ignore this ServiceMonitor.
serviceMonitor:
  enabled: true
  interval: 15s
  labels:
    release: kube-prometheus-stack

replicaCount: 2
