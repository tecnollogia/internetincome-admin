#!/usr/bin/env bash

set -euo pipefail

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
NOCOLOUR="\033[0m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PROPERTIES_FILE="properties.conf"
PROXIES_FILE="proxies.txt"
CONTAINERS_FILE="containernames.txt"
EARNAPP_FILE="earnapp.txt"
PROCESS_ID_FILE="process.pid"
DNS_FILE="resolv.conf"
EARNAPP_DATA_DIR="earnappdata"
PROXY_HEALTH_FILE="proxy-health.log"

EARNAPP_IMAGE_DEFAULT="fazalfarhan01/earnapp:lite"
TUN_IMAGE_DEFAULT="xjasonlyu/tun2socks:v2.6.0"
SOCKS5_DNS_IMAGE_DEFAULT="ghcr.io/heiher/hev-socks5-tunnel:latest"

run_docker() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo docker "$@"
  else
    echo -e "${RED}Docker is not accessible for current user and sudo is unavailable.${NOCOLOUR}"
    exit 1
  fi
}

random_hex() {
  tr -dc 'a-f0-9' </dev/urandom | head -c "$1"
}

require_file() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo -e "${RED}Required file $path is missing.${NOCOLOUR}"
    exit 1
  fi
}

to_mb() {
  local value="${1:-}"
  value="${value,,}"
  if [ -z "$value" ]; then
    echo 0
    return
  fi
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "$value"
    return
  fi
  if [[ "$value" =~ ^([0-9]+)m$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  if [[ "$value" =~ ^([0-9]+)g$ ]]; then
    echo "$((BASH_REMATCH[1] * 1024))"
    return
  fi
  echo 0
}

parse_proxy_host_port() {
  local proxy="$1"
  local no_scheme="${proxy#*://}"
  local host_port="${no_scheme##*@}"
  local host="${host_port%:*}"
  local port="${host_port##*:}"
  echo "$host" "$port"
}

proxy_reachable() {
  local proxy="$1"
  local host port
  read -r host port < <(parse_proxy_host_port "$proxy")
  if [ -z "$host" ] || [ -z "$port" ]; then
    return 1
  fi
  timeout 4 bash -c "</dev/tcp/$host/$port" >/dev/null 2>&1
}

load_properties() {
  require_file "$PROPERTIES_FILE"
  sed -i 's/\r//g' "$PROPERTIES_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$PROPERTIES_FILE"
  set +a

  EARNAPP_IMAGE="${EARNAPP_IMAGE:-$EARNAPP_IMAGE_DEFAULT}"
  TUN_IMAGE="${TUN_IMAGE:-$TUN_IMAGE_DEFAULT}"
  SOCKS5_DNS_IMAGE="${SOCKS5_DNS_IMAGE:-$SOCKS5_DNS_IMAGE_DEFAULT}"
  DEVICE_NAME="${DEVICE_NAME:-linux-node}"
  USE_PROXIES="${USE_PROXIES:-false}"
  USE_SOCKS5_DNS="${USE_SOCKS5_DNS:-true}"
  ENABLE_LOGS="${ENABLE_LOGS:-false}"
  EARNAPP="${EARNAPP:-true}"
  START_DELAY_SEC="${START_DELAY_SEC:-3}"
  DELAY_BETWEEN_TUN_AND_EARNAPP_SEC="${DELAY_BETWEEN_TUN_AND_EARNAPP_SEC:-5}"
  CHECK_PROXY_BEFORE_START="${CHECK_PROXY_BEFORE_START:-true}"
  MAX_STACKS="${MAX_STACKS:-}"

  if [ "$EARNAPP" != "true" ]; then
    echo -e "${RED}EARNAPP must be true for this script variant.${NOCOLOUR}"
    exit 1
  fi
}

make_dns_file() {
  cat >"$DNS_FILE" <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 9.9.9.9
EOF
}

docker_log_args() {
  if [ "${ENABLE_LOGS}" = "true" ]; then
    echo "--log-driver=json-file --log-opt max-size=100k --log-opt max-file=2"
  else
    echo "--log-driver=none"
  fi
}

proxy_lines() {
  sed -i 's/\r//g' "$PROXIES_FILE"
  grep -vE '^\s*#|^\s*$' "$PROXIES_FILE"
}

ensure_no_running_state() {
  if [ -f "$CONTAINERS_FILE" ]; then
    echo -e "${RED}$CONTAINERS_FILE already exists. Run --delete before --start.${NOCOLOUR}"
    exit 1
  fi
}

record_container() {
  echo "$1" >>"$CONTAINERS_FILE"
}

get_or_create_uuid() {
  local index="$1"
  local uuid

  mkdir -p "$EARNAPP_DATA_DIR"

  if [ -f "$EARNAPP_FILE" ]; then
    uuid="$(sed -n "${index}p" "$EARNAPP_FILE" || true)"
  else
    uuid=""
  fi

  if [ -z "$uuid" ]; then
    uuid="sdk-node-$(random_hex 32)"
    echo "$uuid" >>"$EARNAPP_FILE"
  fi

  printf "%s" "$uuid"
}

compute_auto_max_stacks() {
  local mem_total_kb cpu_count stack_mem_mb max_by_mem max_by_cpu
  mem_total_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  cpu_count="$(nproc 2>/dev/null || echo 1)"

  local earn_mb tun_mb
  earn_mb="$(to_mb "${EARNAPP_MEMORY:-192m}")"
  tun_mb="$(to_mb "${TUN_MEMORY:-96m}")"
  stack_mem_mb=$((earn_mb + tun_mb + 64))
  if [ "$stack_mem_mb" -lt 200 ]; then
    stack_mem_mb=200
  fi

  max_by_mem=$(((mem_total_kb / 1024) / stack_mem_mb))
  max_by_cpu=$((cpu_count * 2))

  if [ "$max_by_mem" -lt 1 ]; then
    max_by_mem=1
  fi
  if [ "$max_by_cpu" -lt 1 ]; then
    max_by_cpu=1
  fi

  if [ "$max_by_mem" -lt "$max_by_cpu" ]; then
    echo "$max_by_mem"
  else
    echo "$max_by_cpu"
  fi
}

start_tun_container() {
  local idx="$1"
  local proxy="$2"
  local session="$3"
  local log_args="$4"

  local tun_name="tun${session}_${idx}"

  if ! [[ "$proxy" =~ ^(http|https|socks4|socks5):// ]]; then
    echo -e "${RED}Invalid proxy format on line $idx: $proxy${NOCOLOUR}"
    return 1
  fi

  local tun_resources=()
  [ -n "${TUN_CPUS:-}" ] && tun_resources+=(--cpus "$TUN_CPUS")
  [ -n "${TUN_MEMORY:-}" ] && tun_resources+=(--memory "$TUN_MEMORY")
  [ -n "${PIDS_LIMIT:-}" ] && tun_resources+=(--pids-limit "$PIDS_LIMIT")
  [ -n "${TUN_PLATFORM:-}" ] && tun_resources+=(--platform "$TUN_PLATFORM")

  for attempt in 1 2 3; do
    if [ "$USE_SOCKS5_DNS" = "true" ] && [[ "$proxy" == socks5://* ]]; then
      local socks_no_scheme socks_addr socks_port socks_user socks_pass socks_hostport socks_creds
      socks_no_scheme="${proxy#socks5://}"
      if [[ "$socks_no_scheme" == *@* ]]; then
        socks_creds="${socks_no_scheme%@*}"
        socks_hostport="${socks_no_scheme#*@}"
        socks_user="${socks_creds%%:*}"
        socks_pass="${socks_creds#*:}"
      else
        socks_hostport="$socks_no_scheme"
        socks_user=""
        socks_pass=""
      fi
      socks_addr="${socks_hostport%%:*}"
      socks_port="${socks_hostport##*:}"

      if run_docker run -d \
        --name "$tun_name" \
        --restart=always \
        --mount type=bind,source=/dev/net/tun,target=/dev/net/tun \
        --mount type=bind,source="$SCRIPT_DIR/$DNS_FILE",target=/etc/resolv.conf,readonly \
        --cap-add=NET_ADMIN \
        -e LOG_LEVEL="${TUN_LOG_LEVEL:-warn}" \
        -e SOCKS5_ADDR="$socks_addr" \
        -e SOCKS5_PORT="$socks_port" \
        -e SOCKS5_USERNAME="$socks_user" \
        -e SOCKS5_PASSWORD="$socks_pass" \
        $log_args \
        "${tun_resources[@]}" \
        --no-healthcheck \
        "$SOCKS5_DNS_IMAGE" >/dev/null; then
        record_container "$tun_name"
        printf "%s" "$tun_name"
        return 0
      fi
    else
      if run_docker run -d \
        --name "$tun_name" \
        --restart=always \
        --mount type=bind,source=/dev/net/tun,target=/dev/net/tun \
        --mount type=bind,source="$SCRIPT_DIR/$DNS_FILE",target=/etc/resolv.conf,readonly \
        --cap-add=NET_ADMIN \
        -e PROXY="$proxy" \
        -e EXTRA_COMMANDS='ip rule add iif lo ipproto udp dport 53 lookup main;' \
        -e LOGLEVEL="${TUN_LOG_LEVEL:-warn}" \
        $log_args \
        "${tun_resources[@]}" \
        "$TUN_IMAGE" >/dev/null; then
        record_container "$tun_name"
        printf "%s" "$tun_name"
        return 0
      fi
    fi
    sleep $((attempt * 2))
  done

  echo -e "${RED}Failed starting $tun_name${NOCOLOUR}"
  return 1
}

start_earnapp_container() {
  local idx="$1"
  local session="$2"
  local log_args="$3"
  local network_arg="$4"

  local earn_name="earnapp${session}_${idx}"
  local uuid
  uuid="$(get_or_create_uuid "$idx")"
  mkdir -p "$EARNAPP_DATA_DIR/data$idx"

  local earn_resources=()
  [ -n "${EARNAPP_CPUS:-}" ] && earn_resources+=(--cpus "$EARNAPP_CPUS")
  [ -n "${EARNAPP_MEMORY:-}" ] && earn_resources+=(--memory "$EARNAPP_MEMORY")
  [ -n "${PIDS_LIMIT:-}" ] && earn_resources+=(--pids-limit "$PIDS_LIMIT")
  [ -n "${EARNAPP_PLATFORM:-}" ] && earn_resources+=(--platform "$EARNAPP_PLATFORM")

  for attempt in 1 2 3; do
    if run_docker run -d \
      --name "$earn_name" \
      --restart=always \
      --health-interval=24h \
      --mount type=bind,source="$SCRIPT_DIR/$EARNAPP_DATA_DIR/data$idx",target=/etc/earnapp \
      --mount type=bind,source="$SCRIPT_DIR/$DNS_FILE",target=/etc/resolv.conf,readonly \
      -e EARNAPP_UUID="$uuid" \
      -e EARNAPP_DEVICE_NAME="$DEVICE_NAME-$idx" \
      $network_arg \
      $log_args \
      "${earn_resources[@]}" \
      "$EARNAPP_IMAGE" >/dev/null; then
      record_container "$earn_name"
      echo "https://earnapp.com/r/$uuid"
      return 0
    fi
    sleep $((attempt * 2))
  done

  echo -e "${RED}Failed starting $earn_name${NOCOLOUR}"
  return 1
}

start_stack() {
  load_properties
  ensure_no_running_state

  if ! command -v docker >/dev/null 2>&1; then
    echo -e "${RED}Docker is not installed.${NOCOLOUR}"
    echo "Install Docker first, then retry."
    exit 1
  fi

  : >"$PROXY_HEALTH_FILE"
  echo "$$" >"$PROCESS_ID_FILE"
  trap 'rm -f "$PROCESS_ID_FILE"' EXIT

  make_dns_file

  local log_args
  log_args="$(docker_log_args)"
  local session
  session="$(random_hex 8)"

  echo -e "${YELLOW}Pulling required images...${NOCOLOUR}"
  run_docker pull "$EARNAPP_IMAGE" >/dev/null

  if [ "$USE_PROXIES" = "true" ]; then
    require_file "$PROXIES_FILE"
    run_docker pull "$TUN_IMAGE" >/dev/null
    if [ "$USE_SOCKS5_DNS" = "true" ]; then
      run_docker pull "$SOCKS5_DNS_IMAGE" >/dev/null
    fi
  fi

  local max_stacks
  if [ "${MAX_STACKS:-}" = "all" ]; then
    max_stacks=999999
  elif [ -n "$MAX_STACKS" ]; then
    max_stacks="$MAX_STACKS"
  else
    max_stacks="$(compute_auto_max_stacks)"
  fi

  if [ "$USE_PROXIES" = "true" ]; then
    local idx=0
    local started=0
    local urls_file="earnapp-links.txt"
    rm -f "$urls_file"

    while IFS= read -r proxy; do
      idx=$((idx + 1))

      if [ "$started" -ge "$max_stacks" ]; then
        echo -e "${YELLOW}Reached MAX_STACKS=$max_stacks, skipping remaining proxies.${NOCOLOUR}"
        break
      fi

      if [ "$CHECK_PROXY_BEFORE_START" = "true" ]; then
        if ! proxy_reachable "$proxy"; then
          echo "$(date +"%F %T")|$idx|offline|$proxy" >>"$PROXY_HEALTH_FILE"
          echo -e "${RED}Proxy #$idx unreachable, skipped.${NOCOLOUR}"
          continue
        fi
      fi

      echo -e "${YELLOW}Starting proxy stack #$idx${NOCOLOUR}"
      local tun_name
      if ! tun_name="$(start_tun_container "$idx" "$proxy" "$session" "$log_args")"; then
        echo "$(date +"%F %T")|$idx|tun_failed|$proxy" >>"$PROXY_HEALTH_FILE"
        continue
      fi

      # Stagger EarnApp startup to avoid network bursts on low-end devices.
      sleep "$DELAY_BETWEEN_TUN_AND_EARNAPP_SEC"

      local url
      if url="$(start_earnapp_container "$idx" "$session" "$log_args" "--network=container:$tun_name")"; then
        echo "$url" | tee -a "$urls_file" >/dev/null
        echo "$(date +"%F %T")|$idx|online|$proxy" >>"$PROXY_HEALTH_FILE"
        started=$((started + 1))
      else
        echo "$(date +"%F %T")|$idx|earnapp_failed|$proxy" >>"$PROXY_HEALTH_FILE"
      fi

      sleep "$START_DELAY_SEC"
    done < <(proxy_lines)

    if [ ! -f "$urls_file" ]; then
      echo -e "${RED}No stack started. Check proxies and config.${NOCOLOUR}"
      exit 1
    fi

    echo -e "${GREEN}Started $started EarnApp node(s) with proxies.${NOCOLOUR}"
    echo -e "${GREEN}Claim links saved to $urls_file${NOCOLOUR}"
  else
    echo -e "${YELLOW}Starting direct EarnApp stack (no proxy)...${NOCOLOUR}"
    local url
    url="$(start_earnapp_container "1" "$session" "$log_args" "")"
    echo "$url" | tee "earnapp-links.txt" >/dev/null
    echo -e "${GREEN}Started 1 EarnApp node (direct connection).${NOCOLOUR}"
    echo -e "${GREEN}Claim link: $url${NOCOLOUR}"
  fi
}

delete_stack() {
  rm -f "$PROCESS_ID_FILE"

  if [ -f "$CONTAINERS_FILE" ]; then
    while IFS= read -r container; do
      [ -z "$container" ] && continue
      run_docker rm -f "$container" >/dev/null 2>&1 || true
    done <"$CONTAINERS_FILE"
    rm -f "$CONTAINERS_FILE"
  fi

  rm -f "$DNS_FILE" "earnapp-links.txt"
  echo -e "${GREEN}Containers removed.${NOCOLOUR}"
}

delete_backup() {
  if [ -f "$CONTAINERS_FILE" ]; then
    echo -e "${RED}Containers state exists. Run --delete first.${NOCOLOUR}"
    exit 1
  fi

  rm -rf "$EARNAPP_DATA_DIR"
  rm -f "$EARNAPP_FILE" "$PROXY_HEALTH_FILE"
  echo -e "${GREEN}EarnApp local data removed.${NOCOLOUR}"
}

install_docker() {
  if ! command -v apt-get >/dev/null 2>&1; then
    echo -e "${RED}Automatic install supports Debian/Ubuntu only.${NOCOLOUR}"
    exit 1
  fi

  if command -v sudo >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get -y install docker.io
  else
    apt-get update
    apt-get -y install docker.io
  fi

  echo -e "${GREEN}Docker installation command completed.${NOCOLOUR}"
  docker --version || true
}

case "${1:-}" in
  --start)
    start_stack
    ;;
  --delete)
    delete_stack
    ;;
  --deleteBackup)
    delete_backup
    ;;
  --install)
    install_docker
    ;;
  *)
    echo -e "Valid options: ${YELLOW}--start${NOCOLOUR}, ${YELLOW}--delete${NOCOLOUR}, ${YELLOW}--deleteBackup${NOCOLOUR}, ${YELLOW}--install${NOCOLOUR}"
    exit 1
    ;;
esac
