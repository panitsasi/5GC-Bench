#!/usr/bin/env bash
# Usage:
#   ./nrf_discovery_requests.sh <NUM_REQUESTS> [--mode seq|par] [--concurrency N]
# Examples:
#   ./nrf_discovery_requests.sh 10
#   ./nrf_discovery_requests.sh 50 --mode par --concurrency 8
#
# Optional env:
#   NRF_BASE="http://oai-nrf:8080"
#   TARGET_NF="AMF"
#   INSTALL_MISSING="true"

set -u

print_usage() {
  echo "Usage: $0 <NUM_REQUESTS> [--mode seq|par] [--concurrency N]"
  echo "Examples:"
  echo "  $0 10"
  echo "  $0 50 --mode par --concurrency 8"
  echo "Optional env: NRF_BASE, TARGET_NF, INSTALL_MISSING"
}

if [ $# -lt 1 ]; then
  print_usage; exit 1
fi

NUM_REQUESTS="$1"; shift
if ! [[ "$NUM_REQUESTS" =~ ^[0-9]+$ ]] || [ "$NUM_REQUESTS" -le 0 ]; then
  echo "Error: <NUM_REQUESTS> must be a positive integer."; print_usage; exit 1
fi

MODE="seq"
CONCURRENCY=4
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --concurrency) CONCURRENCY="${2:-}"; shift 2 ;;
    -h|--help) print_usage; exit 0 ;;
    *) echo "Unknown arg: $1"; print_usage; exit 1 ;;
  esac
done

if [[ "$MODE" != "seq" && "$MODE" != "par" ]]; then
  echo "Error: --mode must be 'seq' or 'par'."; exit 1
fi
if ! [[ "$CONCURRENCY" =~ ^[0-9]+$ ]] || [ "$CONCURRENCY" -lt 1 ]; then
  echo "Error: --concurrency must be a positive integer."; exit 1
fi

NRF_BASE="${NRF_BASE:-http://oai-nrf:8080}"
TARGET_NF="${TARGET_NF:-AMF}"
INSTALL_MISSING="${INSTALL_MISSING:-true}"

CANDIDATES=( oai-amf oai-smf oai-udm oai-udr oai-ausf oai-upf )
RUNNING="$(docker ps --format '{{.Names}}')"
SENDERS=()
for c in "${CANDIDATES[@]}"; do
  if echo "$RUNNING" | grep -qx "$c"; then SENDERS+=("$c"); fi
done
if [ ${#SENDERS[@]} -eq 0 ]; then
  echo "Error: none of the expected OAI containers are running: ${CANDIDATES[*]}"; exit 1
fi

infer_req_type() {
  case "$1" in
    *-amf*|amf*)   echo "AMF" ;;
    *-smf*|smf*)   echo "SMF" ;;
    *-udm*|udm*)   echo "UDM" ;;
    *-udr*|udr*)   echo "UDR" ;;
    *-ausf*|ausf*) echo "AUSF" ;;
    *-upf*|upf*)   echo "UPF" ;;
    *)             echo "NF"  ;;
  esac
}

ensure_curl() {
  local container="$1"
  if docker exec "$container" sh -lc 'command -v curl >/dev/null 2>&1'; then return 0; fi
  [ "$INSTALL_MISSING" = "true" ] || return 0
  docker exec "$container" sh -lc '
    set -e
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update >/dev/null && apt-get install -y curl >/dev/null
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache curl >/dev/null
    elif command -v yum >/dev/null 2>&1; then
      yum install -y curl >/dev/null
    else
      exit 9
    fi
  ' || return 9
}

# Preflight
for s in "${SENDERS[@]}"; do
  ensure_curl "$s" >/dev/null 2>&1 || true
done

send_one() {
  local idx="$1" total="$2"
  local sender="${SENDERS[$RANDOM % ${#SENDERS[@]}]}"
  local req_nf; req_nf="$(infer_req_type "$sender")"

  if ! docker exec "$sender" sh -lc 'command -v curl >/dev/null 2>&1'; then
    echo "[$idx/$total] SKIP  sender=$sender requester=$req_nf target=$TARGET_NF reason=no-curl"
    return 0
  fi

  local url="${NRF_BASE}/nnrf-disc/v1/nf-instances?target-nf-type=${TARGET_NF}&requester-nf-type=${req_nf}"
  local code
  code="$(docker exec "$sender" sh -lc \
    "curl --http2-prior-knowledge -sS -o /dev/null -w '%{http_code}' -H 'Accept: application/json' \"$url\"" \
    2>/dev/null || echo "000")"

  if [ "$code" = "200" ]; then
    echo "[$idx/$total] OK    sender=$sender requester=$req_nf target=$TARGET_NF http=$code"
  else
    echo "[$idx/$total] FAIL  sender=$sender requester=$req_nf target=$TARGET_NF http=$code"
  fi
}

if [ "$MODE" = "seq" ]; then
  for ((i=1; i<=NUM_REQUESTS; i++)); do
    send_one "$i" "$NUM_REQUESTS"
    sleep 1
  done
else
  active=0
  for ((i=1; i<=NUM_REQUESTS; i++)); do
    send_one "$i" "$NUM_REQUESTS" &
    active=$((active+1))
    if [ "$active" -ge "$CONCURRENCY" ]; then
      wait -n
      active=$((active-1))
    fi
  done
  wait
fi
