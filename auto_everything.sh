#!/usr/bin/env bash

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

PROPERTIES_FILE="$BASE_DIR/properties.conf"
PROXIES_FILE="$BASE_DIR/proxies.txt"
VENV_DIR="$BASE_DIR/.venv"
WEB_SERVICE="internetincome-web.service"

log() {
  printf '[auto] %s\n' "$*"
}

warn() {
  printf '[auto][warn] %s\n' "$*"
}

die() {
  printf '[auto][error] %s\n' "$*" >&2
  exit 1
}

run_root() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

require_linux() {
  [ "$(uname -s)" = "Linux" ] || die "script supportato solo su Linux"
}

set_prop() {
  local key="$1"
  local value="$2"
  if grep -qE "^${key}=" "$PROPERTIES_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$PROPERTIES_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >>"$PROPERTIES_FILE"
  fi
}

get_default_stack_cap() {
  local mem_kb cpu_count mem_mb cap_by_mem cap_by_cpu cap
  mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  cpu_count="$(nproc 2>/dev/null || echo 1)"
  mem_mb=$((mem_kb / 1024))

  # budget conservativo per stack su macchine deboli
  cap_by_mem=$((mem_mb / 320))
  cap_by_cpu=$((cpu_count * 2))
  [ "$cap_by_mem" -lt 1 ] && cap_by_mem=1
  [ "$cap_by_cpu" -lt 1 ] && cap_by_cpu=1
  cap="$cap_by_mem"
  [ "$cap_by_cpu" -lt "$cap" ] && cap="$cap_by_cpu"
  [ "$cap" -gt 80 ] && cap=80
  printf '%s\n' "$cap"
}

normalize_proxy() {
  local raw="$1"
  if [[ "$raw" == *"://"* ]]; then
    printf '%s\n' "$raw"
    return 0
  fi

  IFS=':' read -r p1 p2 p3 p4 extra <<<"$raw"
  if [ -n "${extra:-}" ]; then
    return 1
  fi

  if [ -n "${p1:-}" ] && [ -n "${p2:-}" ] && [ -n "${p3:-}" ] && [ -n "${p4:-}" ]; then
    printf 'socks5://%s:%s@%s:%s\n' "$p3" "$p4" "$p1" "$p2"
    return 0
  fi

  if [ -n "${p1:-}" ] && [ -n "${p2:-}" ]; then
    printf 'socks5://%s:%s\n' "$p1" "$p2"
    return 0
  fi

  return 1
}

collect_proxies() {
  local tmp_file
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"' EXIT

  cat <<'EOF'
Incolla i proxy (uno per riga), poi scrivi END e premi Invio.
Formati accettati:
- socks5://user:pass@ip:port
- http://user:pass@ip:port
- ip:port:user:pass   (convertito in socks5://...)
EOF

  local count=0
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    [ "$line" = "END" ] && break
    [ "${line:0:1}" = "#" ] && continue

    if normalized="$(normalize_proxy "$line")"; then
      printf '%s\n' "$normalized" >>"$tmp_file"
      count=$((count + 1))
    else
      warn "proxy ignorato (formato non valido): $line"
    fi
  done

  [ "$count" -gt 0 ] || die "nessun proxy valido ricevuto"
  cp "$tmp_file" "$PROXIES_FILE"
  log "salvati $count proxy in $PROXIES_FILE"
}

install_system_deps() {
  log "installo dipendenze di sistema..."
  run_root apt-get update
  run_root apt-get -y install docker.io python3 python3-venv python3-pip curl jq
  run_root systemctl enable --now docker || true
}

setup_python_env() {
  log "configuro ambiente python..."
  if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
  fi
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  pip install --upgrade pip >/dev/null
  pip install -r requirements.txt >/dev/null
}

apply_smart_profile() {
  local cap
  cap="$(get_default_stack_cap)"

  log "applico profilo smart (scalabile e low-disturbance)..."
  set_prop "USE_PROXIES" "true"
  set_prop "USE_SOCKS5_DNS" "true"
  set_prop "CHECK_PROXY_BEFORE_START" "true"
  set_prop "ENABLE_LOGS" "false"
  set_prop "AUTO_HEAL" "true"
  set_prop "ENABLE_HOST_GUARD" "true"
  set_prop "AUTO_REBOOT_ON_CRITICAL" "true"
  set_prop "DELAY_BETWEEN_TUN_AND_EARNAPP_SEC" "'30'"
  set_prop "START_DELAY_SEC" "'4'"
  set_prop "MAX_STACKS" "'$cap'"
  set_prop "EARNAPP_CPUS" "'0.35'"
  set_prop "TUN_CPUS" "'0.20'"
  set_prop "EARNAPP_MEMORY" "'192m'"
  set_prop "TUN_MEMORY" "'96m'"
  set_prop "PIDS_LIMIT" "'120'"
}

ask_scaling_override() {
  local cap answer
  cap="$(get_default_stack_cap)"
  printf 'Cap auto suggerito per questa macchina: %s stack. Vuoi cambiarlo? [invio=no]: ' "$cap"
  read -r answer || true
  if [ -n "${answer:-}" ]; then
    if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ]; then
      set_prop "MAX_STACKS" "'$answer'"
      log "MAX_STACKS impostato a $answer"
    else
      warn "valore non valido, mantengo cap automatico"
      set_prop "MAX_STACKS" "'$cap'"
    fi
  fi
}

setup_web_service() {
  if command -v systemctl >/dev/null 2>&1; then
    log "configuro servizio dashboard systemd..."
    run_root tee "/etc/systemd/system/$WEB_SERVICE" >/dev/null <<EOF
[Unit]
Description=InternetIncome EarnApp Web Console
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$BASE_DIR
Environment=WEB_HOST=0.0.0.0
Environment=WEB_PORT=8080
ExecStart=$BASE_DIR/.venv/bin/python $BASE_DIR/app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    run_root systemctl daemon-reload
    run_root systemctl enable --now "$WEB_SERVICE"
  else
    warn "systemd non disponibile, avvio dashboard in background"
    nohup "$BASE_DIR/.venv/bin/python" "$BASE_DIR/app.py" >/tmp/internetincome-web.log 2>&1 &
  fi
}

start_stack() {
  log "avvio stack EarnApp..."
  bash "$BASE_DIR/internetIncome.sh" --delete >/dev/null 2>&1 || true
  bash "$BASE_DIR/internetIncome.sh" --start
}

stop_stack() {
  log "stop stack EarnApp..."
  bash "$BASE_DIR/internetIncome.sh" --delete || true
}

show_status() {
  log "stato servizi/container..."
  if command -v systemctl >/dev/null 2>&1; then
    run_root systemctl --no-pager --full status "$WEB_SERVICE" || true
  fi
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' || true
  if [ -f "$BASE_DIR/earnapp-links.txt" ]; then
    log "link EarnApp:"
    cat "$BASE_DIR/earnapp-links.txt"
  fi
}

show_result() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  log "completato."
  [ -n "$ip" ] && log "dashboard: http://$ip:8080"
  [ -f "$BASE_DIR/earnapp-links.txt" ] && log "link in: $BASE_DIR/earnapp-links.txt"
}

first_install_flow() {
  collect_proxies
  install_system_deps
  setup_python_env
  apply_smart_profile
  ask_scaling_override
  setup_web_service
  start_stack
  show_result
}

update_proxies_flow() {
  collect_proxies
  apply_smart_profile
  start_stack
  show_result
}

retune_only_flow() {
  apply_smart_profile
  ask_scaling_override
  log "profilo aggiornato. Riavvia stack da menu per applicarlo."
}

menu() {
  cat <<'EOF'

==== InternetIncome Smart Auto Script ====
1) Prima installazione completa (consigliato)
2) Aggiorna solo proxy + restart stack
3) Retune performance/scaling (senza restart)
4) Start stack
5) Stop stack
6) Status
7) Esci
EOF
  printf 'Seleziona opzione [1-7]: '
}

main() {
  require_linux
  [ -f "$BASE_DIR/internetIncome.sh" ] || die "internetIncome.sh non trovato nella cartella corrente"
  [ -f "$BASE_DIR/app.py" ] || die "app.py non trovato nella cartella corrente"
  [ -f "$BASE_DIR/requirements.txt" ] || die "requirements.txt non trovato nella cartella corrente"

  while true; do
    menu
    read -r choice
    case "${choice:-}" in
      1) first_install_flow ;;
      2) update_proxies_flow ;;
      3) retune_only_flow ;;
      4) start_stack ;;
      5) stop_stack ;;
      6) show_status ;;
      7) exit 0 ;;
      *) warn "opzione non valida" ;;
    esac
  done
}

main "$@"

