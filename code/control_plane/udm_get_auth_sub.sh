#!/usr/bin/env bash
# get_auth_sub.sh
# Send N requests from the UDM container to UDR, each for a RANDOM IMSI in [START, END].
# Usage:
#   ./udm_get_auth_sub.sh <NUM_REQUESTS> <START_IMSI> <END_IMSI> [--mode seq|par] [--concurrency N] [--container NAME]
# Examples:
#   ./udm_get_auth_sub.sh 50 208950000000033 208950000000100
#   ./udm_get_auth_sub.sh 200 208950000000033 208950000000100 --mode par --concurrency 8
#
# Optional env:
#   UDR_BASE="http://oai-udr:8080"    # base URL of UDR (default)
#   INSTALL_MISSING="true"            # attempt to install curl in the container if missing

set -u

print_usage() {
  echo "Usage: $0 <NUM_REQUESTS> <START_IMSI> <END_IMSI> [--mode seq|par] [--concurrency N] [--container NAME]"
  echo "Examples:"
  echo "  $0 50 208950000000033 208950000000100"
  echo "  $0 200 208950000000033 208950000000100 --mode par --concurrency 8"
  echo "Optional env: UDR_BASE, INSTALL_MISSING"
}

# --- Args ---
if [ $# -lt 3 ]; then
  print_usage; exit 1
fi
NUM_REQ="$1"; START_IMSI="$2"; END_IMSI="$3"; shift 3

# Validate numeric
if ! [[ "$NUM_REQ" =~ ^[0-9]+$ ]] || [ "$NUM_REQ" -le 0 ]; then
  echo "Error: <NUM_REQUESTS> must be a positive integer."; exit 1
fi
if ! [[ "$START_IMSI" =~ ^[0-9]+$ && "$END_IMSI" =~ ^[0-9]+$ ]]; then
  echo "Error: START_IMSI and END_IMSI must be numeric."; exit 1
fi

# Convert to integers safely (ignore leading zeros)
START_NUM=$((10#$START_IMSI))
END_NUM=$((10#$END_IMSI))
if [ "$START_NUM" -gt "$END_NUM" ]; then
  echo "Error: START_IMSI must be <= END_IMSI."; exit 1
fi

MODE="seq"
CONCURRENCY=4
CONTAINER="oai-udm"

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --concurrency) CONCURRENCY="${2:-}"; shift 2 ;;
    --container) CONTAINER="${2:-}"; shift 2 ;;
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

UDR_BASE="${UDR_BASE:-http://oai-udr:8080}"
INSTALL_MISSING="${INSTALL_MISSING:-true}"

# --- Verify container is running ---
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Error: container '$CONTAINER' not found or not running."; exit 1
fi

# --- Ensure curl is present in container (optional) ---
ensure_curl() {
  if docker exec "$CONTAINER" sh -lc 'command -v curl >/dev/null 2>&1'; then
    return 0
  fi
  [ "$INSTALL_MISSING" = "true" ] || return 0
  docker exec "$CONTAINER" sh -lc '
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
  ' >/dev/null 2>&1 || true
}
ensure_curl

RANGE_SIZE=$(( END_NUM - START_NUM + 1 ))

# One request for a RANDOM IMSI in the range
send_random() {
  local idx="$1" total="$2"
  # Pick random offset in [0, RANGE_SIZE-1]
  local offset=$(( RANDOM % RANGE_SIZE ))
  local imsi_num=$(( START_NUM + offset ))
  local imsi_pad
  imsi_pad="$(printf '%015d' "$imsi_num")"

  local url="${UDR_BASE}/nudr-dr/v1/subscription-data/${imsi_pad}/authentication-data/authentication-subscription"

  local code
  code="$(docker exec "$CONTAINER" sh -lc \
    "curl --http2-prior-knowledge -sS -o /dev/null -w '%{http_code}' -H 'Accept: application/json' -H 'Expect:' \"$url\"" \
    2>/dev/null || echo "000")"

  if [ "$code" = "200" ]; then
    echo "[$idx/$total] OK    imsi=${imsi_pad} http=$code"
  else
    echo "[$idx/$total] FAIL  imsi=${imsi_pad} http=$code"
  fi
}

if [ "$MODE" = "seq" ]; then
  for ((i=1; i<=NUM_REQ; i++)); do
    send_random "$i" "$NUM_REQ"
    sleep 0.2
  done
else
  active=0
  for ((i=1; i<=NUM_REQ; i++)); do
    send_random "$i" "$NUM_REQ" &
    active=$((active+1))
    if [ "$active" -ge "$CONCURRENCY" ]; then
      wait -n
      active=$((active-1))
    fi
  done
  wait
fi
