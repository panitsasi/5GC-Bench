#!/usr/bin/env bash
# nrf_register_vnfs.sh
# Usage:
#   ./nrf_register_vnfs.sh <NUM_REGISTRATIONS> [--mode seq|par] [--concurrency N] [--nf-types CSV]
# Examples:
#   ./nrf_register_vnfs.sh 10
#   ./nrf_register_vnfs.sh 50 --mode par --concurrency 8
#   ./nrf_register_vnfs.sh 20 --nf-types AMF,SMF,UPF --mode par
#
# Optional env:
#   NRF_BASE="http://oai-nrf:8080"
#   NET_BASE_IP="192.168.70"
#   PORT_DEFAULT="8080"

set -u

print_usage() {
  echo "Usage: $0 <NUM_REGISTRATIONS> [--mode seq|par] [--concurrency N] [--nf-types CSV]"
  echo
  echo "Examples:"
  echo "  $0 10"
  echo "  $0 50 --mode par --concurrency 8"
  echo "  $0 20 --nf-types AMF,SMF,UPF --mode par"
  echo
}

if [ $# -lt 1 ]; then
  echo "Error: missing <NUM_REGISTRATIONS> argument."
  echo
  print_usage
  echo "Example run:"
  echo "  $0 10 --mode par --concurrency 4"
  exit 1
fi

NUM="$1"; shift
if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [ "$NUM" -le 0 ]; then
  echo "Error: <NUM_REGISTRATIONS> must be a positive integer."
  exit 1
fi

MODE="seq"
CONCURRENCY=4
NF_TYPES_CSV="AMF,SMF,UDM,UDR,AUSF,UPF,PCF"

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --concurrency) CONCURRENCY="${2:-}"; shift 2 ;;
    --nf-types) NF_TYPES_CSV="${2:-}"; shift 2 ;;
    -h|--help) print_usage; exit 0 ;;
    *) echo "Unknown arg: $1"; print_usage; exit 1 ;;
  esac
done

NRF_BASE="${NRF_BASE:-http://oai-nrf:8080}"
NET_BASE_IP="${NET_BASE_IP:-192.168.70}"
PORT_DEFAULT="${PORT_DEFAULT:-8080}"

# Candidate sender containers
CANDIDATES=( oai-amf oai-smf oai-udm oai-udr oai-ausf oai-upf )
RUNNING="$(docker ps --format '{{.Names}}')"
SENDERS=()
for c in "${CANDIDATES[@]}"; do
  if echo "$RUNNING" | grep -qx "$c"; then SENDERS+=("$c"); fi
done
[ ${#SENDERS[@]} -eq 0 ] && { echo "No OAI containers running."; exit 1; }

IFS=',' read -r -a REG_NF_TYPES <<< "$NF_TYPES_CSV"

gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    date +%s%N | sha256sum | cut -c1-32 | sed 's/\(..\)/\1-/g;s/-$//'
  fi
}

short_id() { echo "$1" | tr -d '-' | cut -c1-8; }

build_services_json() {
  local nf="$1" ip="$2" port="$3"
  case "$nf" in
    AMF)  echo "\"nfServices\":[{\"serviceInstanceId\":\"namf-comm\",\"serviceName\":\"namf-comm\",\"scheme\":\"http\",\"apiPrefix\":\"/namf-comm\",\"versions\":[{\"apiVersionInUri\":\"v1\",\"apiFullVersion\":\"1.0.0\"}],\"nfServiceStatus\":\"REGISTERED\",\"ipEndPoints\":[{\"ipv4Address\":\"$ip\",\"transport\":\"TCP\",\"port\":$port}]}]" ;;
    SMF)  echo "\"nfServices\":[{\"serviceInstanceId\":\"nsmf-pdusession\",\"serviceName\":\"nsmf-pdusession\",\"scheme\":\"http\",\"apiPrefix\":\"/nsmf-pdusession\",\"versions\":[{\"apiVersionInUri\":\"v1\",\"apiFullVersion\":\"1.0.0\"}],\"nfServiceStatus\":\"REGISTERED\",\"ipEndPoints\":[{\"ipv4Address\":\"$ip\",\"transport\":\"TCP\",\"port\":$port}]}]" ;;
    UDM)  echo "\"nfServices\":[{\"serviceInstanceId\":\"nudm-ueau\",\"serviceName\":\"nudm-ueau\",\"scheme\":\"http\",\"apiPrefix\":\"/nudm-ueau\",\"versions\":[{\"apiVersionInUri\":\"v1\",\"apiFullVersion\":\"1.0.0\"}],\"nfServiceStatus\":\"REGISTERED\",\"ipEndPoints\":[{\"ipv4Address\":\"$ip\",\"transport\":\"TCP\",\"port\":$port}]}]" ;;
    UDR)  echo "\"nfServices\":[{\"serviceInstanceId\":\"nudr-dr\",\"serviceName\":\"nudr-dr\",\"scheme\":\"http\",\"apiPrefix\":\"/nudr-dr\",\"versions\":[{\"apiVersionInUri\":\"v1\",\"apiFullVersion\":\"1.0.0\"}],\"nfServiceStatus\":\"REGISTERED\",\"ipEndPoints\":[{\"ipv4Address\":\"$ip\",\"transport\":\"TCP\",\"port\":$port}]}]" ;;
    AUSF) echo "\"nfServices\":[{\"serviceInstanceId\":\"nausf-auth\",\"serviceName\":\"nausf-auth\",\"scheme\":\"http\",\"apiPrefix\":\"/nausf-auth\",\"versions\":[{\"apiVersionInUri\":\"v1\",\"apiFullVersion\":\"1.0.0\"}],\"nfServiceStatus\":\"REGISTERED\",\"ipEndPoints\":[{\"ipv4Address\":\"$ip\",\"transport\":\"TCP\",\"port\":$port}]}]" ;;
    UPF)  echo "\"nfServices\":[{\"serviceInstanceId\":\"nupf\",\"serviceName\":\"nupf\",\"scheme\":\"http\",\"apiPrefix\":\"/nupf\",\"versions\":[{\"apiVersionInUri\":\"v1\",\"apiFullVersion\":\"1.0.0\"}],\"nfServiceStatus\":\"REGISTERED\",\"ipEndPoints\":[{\"ipv4Address\":\"$ip\",\"transport\":\"TCP\",\"port\":$port}]}]" ;;
    PCF)  echo "\"nfServices\":[{\"serviceInstanceId\":\"npcf-policyauthorization\",\"serviceName\":\"npcf-policyauthorization\",\"scheme\":\"http\",\"apiPrefix\":\"/npcf-policyauthorization\",\"versions\":[{\"apiVersionInUri\":\"v1\",\"apiFullVersion\":\"1.0.0\"}],\"nfServiceStatus\":\"REGISTERED\",\"ipEndPoints\":[{\"ipv4Address\":\"$ip\",\"transport\":\"TCP\",\"port\":$port}]}]" ;;
    *)    echo "\"nfServices\":[]" ;;
  esac
}

register_one() {
  local idx="$1" total="$2"
  local sender="${SENDERS[$RANDOM % ${#SENDERS[@]}]}"
  local requester="${sender#oai-}" && requester=$(echo "$requester" | tr '[:lower:]' '[:upper:]')

  local nf="${REG_NF_TYPES[$RANDOM % ${#REG_NF_TYPES[@]}]}"
  local uuid="$(gen_uuid)"
  local sid="$(short_id "$uuid")"
  local ip="${NET_BASE_IP}.$(( (RANDOM % 200) + 50 ))"
  local name="TEST-${nf}-${sid}"
  local services
  services="$(build_services_json "$nf" "$ip" "$PORT_DEFAULT")"

  local common="\"nfInstanceId\":\"$uuid\",\"nfType\":\"$nf\",\"nfStatus\":\"REGISTERED\",\"nfInstanceName\":\"$name\",\"ipv4Addresses\":[\"$ip\"],\"heartBeatTimer\":30"
  local extra=""
  [ "$nf" = "AMF" ] && extra=",\"amfInfo\":{\"amfRegionId\":\"10\",\"amfSetId\":\"1\",\"guamiList\":[{\"plmnId\":{\"mcc\":\"208\",\"mnc\":\"95\"},\"amfId\":\"200:1:1\"}]},\"sNssais\":[{\"sst\":1,\"sd\":\"aaaaaa\"}]"
  local payload="{${common}${extra},${services}}"
  local url="${NRF_BASE}/nnrf-nfm/v1/nf-instances/${uuid}?requester-nf-type=${requester}"

  local code
  code="$(docker exec "$sender" sh -lc \
    "curl --http2-prior-knowledge -sS -o /dev/null -w '%{http_code}' -i -X PUT \"$url\" -H 'Content-Type: application/json' -H 'Accept: application/json' -d '$payload'" \
    2>/dev/null || echo "000")"

  if [ "$code" = "200" ] || [ "$code" = "201" ]; then
    echo "[$idx/$total] OK    sender=$sender requester=$requester nf=$nf uuid=$uuid http=$code"
  else
    echo "[$idx/$total] FAIL  sender=$sender requester=$requester nf=$nf http=$code"
  fi
}

# Run loop
if [ "$MODE" = "seq" ]; then
  for ((i=1; i<=NUM; i++)); do
    register_one "$i" "$NUM"
    sleep 0.5
  done
else
  active=0
  for ((i=1; i<=NUM; i++)); do
    register_one "$i" "$NUM" &
    active=$((active+1))
    if [ "$active" -ge "$CONCURRENCY" ]; then
      wait -n
      active=$((active-1))
    fi
  done
  wait
fi
