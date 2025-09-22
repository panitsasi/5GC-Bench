#!/usr/bin/env bash
# ausf_generate_auth.sh
# Send N POSTs from AUSF to UDM to generate auth vectors for RANDOM IMSIs in a fixed range.
#
# Usage:
#   ./ausf_generate_auth.sh <NUM_REQUESTS> [--mode seq|par] [--concurrency N] [--container NAME] [--ausf-id UUID] [--sn-name NAME] [--auth-type NAME]
# Examples:
#   ./ausf_generate_auth.sh 50
#   ./ausf_generate_auth.sh 200 --mode par --concurrency 8
#
# Env overrides (optional):
#   RANGE_START=208950000000033
#   RANGE_END=208950000000100
#   UDM_BASE=http://oai-udm:8080
#   INSTALL_MISSING=true

set -u

print_usage() {
  echo "Usage: $0 <NUM_REQUESTS> [--mode seq|par] [--concurrency N] [--container NAME] [--ausf-id UUID] [--sn-name NAME] [--auth-type NAME]"
  echo "Examples:"
  echo "  $0 50"
  echo "  $0 200 --mode par --concurrency 8"
}

# ---- Args ----
if [ $# -lt 1 ]; then
  print_usage; exit 1
fi
NUM_REQ="$1"; shift
if ! [[ "$NUM_REQ" =~ ^[0-9]+$ ]] || [ "$NUM_REQ" -le 0 ]; then
  echo "Error: <NUM_REQUESTS> must be a positive integer."; exit 1
fi

MODE="seq"
CONCURRENCY=4
CONTAINER="oai-ausf"
AUSF_ID="345b8da7-6cb3-44bd-9125-ccc4586fa75c"
SN_NAME="5G:mnc095.mcc208.3gppnetwork.org"
AUTH_TYPE="5G_AKA"

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --concurrency) CONCURRENCY="${2:-}"; shift 2 ;;
    --container) CONTAINER="${2:-}"; shift 2 ;;
    --ausf-id) AUSF_ID="${2:-}"; shift 2 ;;
    --sn-name) SN_NAME="${2:-}"; shift 2 ;;
    --auth-type) AUTH_TYPE="${2:-}"; shift 2 ;;
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

# ---- Config (overridable via env) ----
RANGE_START="${RANGE_START:-208950000000033}"
RANGE_END="${RANGE_END:-208950000000100}"
UDM_BASE="${UDM_BASE:-http://oai-udm:8080}"
INSTALL_MISSING="${INSTALL_MISSING:-true}"

# Validate range numbers (as integers; ignore leading zeros safely)
START_NUM=$((10#$RANGE_START))
END_NUM=$((10#$RANGE_END))
if [ "$START_NUM" -gt "$END_NUM" ]; then
  echo "Error: RANGE_START must be <= RANGE_END."; exit 1
fi
RANGE_SIZE=$(( END_NUM - START_NUM + 1 ))

# Ensure AUSF container is running
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Error: container '$CONTAINER' not found or not running."; exit 1
fi

# Ensure curl exists in AUSF (optional auto-install)
ensure_curl() {
  if docker exec "$CONTAINER" sh -lc 'command -v curl >/dev/null 2>&1'; then return 0; fi
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

send_one_random() {
  local idx="$1" total="$2"
  local offset=$(( RANDOM % RANGE_SIZE ))
  local imsi_num=$(( START_NUM + offset ))
  local imsi_pad
  imsi_pad="$(printf '%015d' "$imsi_num")"

  local url="${UDM_BASE}/nudm-ueau/v1/${imsi_pad}/security-information/generate-auth-data"
  local payload
  payload=$(printf '{"servingNetworkName":"%s","authType":"%s","ausfInstanceId":"%s"}' "$SN_NAME" "$AUTH_TYPE" "$AUSF_ID")

  local code
  code="$(docker exec -e PAYLOAD="$payload" "$CONTAINER" sh -lc \
    "curl --http2-prior-knowledge -sS -o /dev/null -w '%{http_code}' -i -X POST \"$url\" \
      -H 'Content-Type: application/json' -H 'Accept: application/json' -H 'Expect:' \
      -d \"\$PAYLOAD\"" \
    2>/dev/null || echo "000")"

  if [ "$code" = "200" ] || [ "$code" = "201" ]; then
    echo "[$idx/$total] OK    imsi=${imsi_pad} http=$code"
  else
    echo "[$idx/$total] FAIL  imsi=${imsi_pad} http=$code"
  fi
}

if [ "$MODE" = "seq" ]; then
  for ((i=1; i<=NUM_REQ; i++)); do
    send_one_random "$i" "$NUM_REQ"
    sleep 0.2
  done
else
  # Parallel without 'wait -n': manage our own PID queue for portability
  pids=()
  for ((i=1; i<=NUM_REQ; i++)); do
    send_one_random "$i" "$NUM_REQ" &
    pids+=("$!")
    if [ "${#pids[@]}" -ge "$CONCURRENCY" ]; then
      wait "${pids[0]}" 2>/dev/null || true
      pids=("${pids[@]:1}")
    fi
  done
  # wait remaining
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
fi
