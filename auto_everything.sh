#!/usr/bin/env bash

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

PROPERTIES_FILE="$BASE_DIR/properties.conf"
PROXIES_FILE="$BASE_DIR/proxies.txt"
VENV_DIR="$BASE_DIR/.venv"
WEB_SERVICE="internetincome-web.service"
LOG_FILE="$BASE_DIR/auto_everything.log"

touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  printf '[auto][%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

warn() {
  printf '[auto][warn] %s\n' "$*"
}

die() {
  printf '[auto][%s][error] %s\n' "$(date '+%H:%M:%S')" "$*" >&2
  exit 1
}

trap 'printf "[auto][%s][error] comando fallito: %s (linea %s)\n" "$(date "+%H:%M:%S")" "$BASH_COMMAND" "$LINENO" >&2' ERR

run_step() {
  local label="$1"
  shift
  local start now elapsed
  start="$(date +%s)"
  log "START: $label"

  "$@" &
  local pid=$!
  while kill -0 "$pid" >/dev/null 2>&1; do
    sleep 5
    now="$(date +%s)"
    elapsed=$((now - start))
    log "IN CORSO: $label (${elapsed}s)"
  done

  local rc=0
  if ! wait "$pid"; then
    rc=$?
  fi
  now="$(date +%s)"
  elapsed=$((now - start))
  if [ "$rc" -eq 0 ]; then
    log "DONE: $label (${elapsed}s)"
  else
    die "FAIL: $label (rc=$rc, ${elapsed}s). Guarda log: $LOG_FILE"
  fi
}

run_step_with_timeout() {
  local label="$1"
  local timeout_sec="$2"
  shift 2
  run_step "$label (timeout ${timeout_sec}s)" timeout --foreground "$timeout_sec" "$@"
}

try_step_with_timeout() {
  local label="$1"
  local timeout_sec="$2"
  shift 2
  local start now elapsed
  start="$(date +%s)"
  log "START: $label (timeout ${timeout_sec}s)"

  timeout --foreground "$timeout_sec" "$@" &
  local pid=$!
  while kill -0 "$pid" >/dev/null 2>&1; do
    sleep 5
    now="$(date +%s)"
    elapsed=$((now - start))
    log "IN CORSO: $label (${elapsed}s)"
  done

  local rc=0
  if ! wait "$pid"; then
    rc=$?
  fi
  now="$(date +%s)"
  elapsed=$((now - start))
  if [ "$rc" -eq 0 ]; then
    log "DONE: $label (${elapsed}s)"
  else
    warn "FAIL: $label (rc=$rc, ${elapsed}s)"
  fi
  return "$rc"
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
  trap 'if [ -n "${tmp_file:-}" ] && [ -f "${tmp_file:-}" ]; then rm -f "${tmp_file:-}"; fi' EXIT

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
  run_step "apt-get update" run_root apt-get update
  run_step "apt-get install docker/python/jq" run_root apt-get -y install docker.io python3 python3-venv python3-pip curl jq
  run_step "enable/start docker service" run_root systemctl enable --now docker
}

setup_python_env() {
  log "configuro ambiente python..."
  command -v python3 >/dev/null 2>&1 || die "python3 non trovato"
  python3 --version || true
  command -v pip3 >/dev/null 2>&1 && pip3 --version || true

  log "controllo rete verso PyPI..."
  if ! curl -I -m 10 -s https://pypi.org/simple/ >/dev/null; then
    warn "PyPI non raggiungibile ora. Possibili lentezze/timeout su pip."
  else
    log "PyPI raggiungibile."
  fi

  if [ ! -d "$VENV_DIR" ]; then
    run_step "creazione virtualenv" python3 -m venv "$VENV_DIR"
  else
    log "virtualenv gia esistente: $VENV_DIR"
  fi
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  python --version || true
  pip --version || true

  [ -f "$BASE_DIR/requirements.txt" ] || die "requirements.txt non trovato in $BASE_DIR"
  log "requirements rilevato, righe: $(wc -l < "$BASE_DIR/requirements.txt")"

  export PIP_DISABLE_PIP_VERSION_CHECK=1
  export PIP_PROGRESS_BAR=off

  # pip update can hang on slow mirrors, so keep a hard timeout.
  try_step_with_timeout "upgrade pip" 180 pip install --upgrade pip --retries 2 --timeout 30 || true

  # requirements install with retry/fallback and hard timeout to avoid endless stalls.
  if ! try_step_with_timeout "install requirements (attempt 1)" 300 pip install -r requirements.txt --retries 2 --timeout 30 -v; then
    warn "tentativo 1 fallito/timeout, riprovo con --no-cache-dir"
    run_step_with_timeout "install requirements (attempt 2)" 300 pip install -r requirements.txt --retries 2 --timeout 30 --no-cache-dir -v
  fi
}

apply_smart_profile() {
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
  set_prop "MAX_STACKS" "'all'"
  set_prop "EARNAPP_CPUS" "'0.35'"
  set_prop "TUN_CPUS" "'0.20'"
  set_prop "EARNAPP_MEMORY" "'192m'"
  set_prop "TUN_MEMORY" "'96m'"
  set_prop "PIDS_LIMIT" "'120'"
}

ask_scaling_override() {
  local cap answer
  cap="$(get_default_stack_cap)"
  printf "Modalita attuale: tutti i proxy (MAX_STACKS='all').\n"
  printf 'Suggerimento prudente per questa macchina: %s stack.\n' "$cap"
  printf "Inserisci un limite numerico (oppure invio per usare TUTTI i proxy): "
  read -r answer || true
  if [ -n "${answer:-}" ]; then
    if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ]; then
      set_prop "MAX_STACKS" "'$answer'"
      log "MAX_STACKS impostato a $answer"
    else
      warn "valore non valido, mantengo MAX_STACKS='all'"
      set_prop "MAX_STACKS" "'all'"
    fi
  else
    set_prop "MAX_STACKS" "'all'"
    log "MAX_STACKS impostato a 'all' (tutti i proxy)"
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
  run_step "delete stack precedente" bash "$BASE_DIR/internetIncome.sh" --delete || true
  run_step "start stack earnapp" bash "$BASE_DIR/internetIncome.sh" --start
  run_step "docker ps snapshot" docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
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
  log "log completo: $LOG_FILE"
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
  log "log file: $LOG_FILE"
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
