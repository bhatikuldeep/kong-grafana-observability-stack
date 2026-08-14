#!/usr/bin/env bash
# Creates a real Konnect control plane + DP client certificate via the
# Konnect API, then writes values-dp.yaml for the Kong Gateway Helm chart.
set -euo pipefail

cd "$(dirname "$0")"
[ -f .env ] || { echo "Missing .env — copy .env.example to .env and fill in KONNECT_TOKEN first."; exit 1; }
set -a; source .env; set +a

: "${KONNECT_TOKEN:?Set KONNECT_TOKEN in .env}"
: "${KONNECT_SERVER_URL:=eu.api.konghq.com}"
: "${CONTROL_PLANE_NAME:=kong-observability-demo}"
: "${KONG_IMAGE_TAG:=3.14.0.12}"

mkdir -p certs

if [ ! -f certs/tls.crt ]; then
  echo "Generating DP client certificate..."
  openssl req -new -x509 -nodes -newkey ec:<(openssl ecparam -name secp384r1) \
    -keyout certs/tls.key -out certs/tls.crt -days 1095 -subj "/CN=kong_clustering"
fi

if [ ! -f certs/control-plane.json ]; then
  echo "Creating Konnect control plane '$CONTROL_PLANE_NAME' (Self-Managed Hybrid)..."
  curl -sS -X POST "https://${KONNECT_SERVER_URL}/v2/control-planes" \
    --fail-with-body \
    -H "Authorization: Bearer ${KONNECT_TOKEN}" \
    --json "{\"name\": \"${CONTROL_PLANE_NAME}\"}" > certs/control-plane.json
  echo "Control plane created: $(python3 -c 'import json;print(json.load(open("certs/control-plane.json"))["id"])')"
else
  echo "Reusing existing control plane record at certs/control-plane.json"
fi

CONTROL_PLANE_ID=$(python3 -c 'import json;print(json.load(open("certs/control-plane.json"))["id"])')
CONTROL_PLANE_ENDPOINT=$(python3 -c 'import json;print(json.load(open("certs/control-plane.json"))["config"]["control_plane_endpoint"].replace("https://",""))')
CONTROL_PLANE_TELEMETRY=$(python3 -c 'import json;print(json.load(open("certs/control-plane.json"))["config"]["telemetry_endpoint"].replace("https://",""))')

# Persist the CP's real endpoint hostnames to .env, alongside KONNECT_TOKEN —
# values-dp.yaml.tpl stays a static, committable template with no real
# hostnames in it; envsubst fills them in from .env at apply time.
if grep -q '^CONTROL_PLANE_ENDPOINT=' .env; then
  sed -i.bak "s|^CONTROL_PLANE_ENDPOINT=.*|CONTROL_PLANE_ENDPOINT=${CONTROL_PLANE_ENDPOINT}|" .env && rm -f .env.bak
else
  echo "CONTROL_PLANE_ENDPOINT=${CONTROL_PLANE_ENDPOINT}" >> .env
fi
if grep -q '^CONTROL_PLANE_TELEMETRY=' .env; then
  sed -i.bak "s|^CONTROL_PLANE_TELEMETRY=.*|CONTROL_PLANE_TELEMETRY=${CONTROL_PLANE_TELEMETRY}|" .env && rm -f .env.bak
else
  echo "CONTROL_PLANE_TELEMETRY=${CONTROL_PLANE_TELEMETRY}" >> .env
fi

echo "Uploading DP client certificate to control plane..."
CERT=$(awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}' certs/tls.crt)
curl -sS -X POST "https://${KONNECT_SERVER_URL}/v2/control-planes/${CONTROL_PLANE_ID}/dp-client-certificates" \
  --fail-with-body \
  -H "Authorization: Bearer ${KONNECT_TOKEN}" \
  --json "{\"cert\": \"${CERT}\"}" > certs/dp-cert-upload.json || echo "  (cert may already be uploaded — continuing)"

kubectl create namespace kong --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret tls kong-cluster-cert --cert=certs/tls.crt --key=certs/tls.key -n kong \
  --dry-run=client -o yaml | kubectl apply -f -

# ── values-dp.yaml — rendered from the static, committable template ──
export KONG_IMAGE_TAG CONTROL_PLANE_ENDPOINT CONTROL_PLANE_TELEMETRY
envsubst '${KONG_IMAGE_TAG} ${CONTROL_PLANE_ENDPOINT} ${CONTROL_PLANE_TELEMETRY}' \
  < values-dp.yaml.tpl > values-dp.yaml

echo ""
echo "values-dp.yaml written (Kong Gateway ${KONG_IMAGE_TAG}). Control plane ID: ${CONTROL_PLANE_ID}"
echo "Next: task kong-dp-install"
