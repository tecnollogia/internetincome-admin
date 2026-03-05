#!/usr/bin/env bash

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

PROPERTIES_FILE="$BASE_DIR/properties.conf"
PROXIES_FILE="$BASE_DIR/proxies.txt"

log() {
  printf '[auto] %s\n' "$*"
}

run_root() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
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
- ip:port:user:pass   (convertito automaticamente in socks5://...)
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
      log "proxy ignorato (formato non valido): $line"
    fi
  done

  if [ "$count" -eq 0 ]; then
    log "nessun proxy valido ricevuto, annullo."
    exit 1
  fi

  cp "$tmp_file" "$PROXIES_FILE"
  log "salvati $count proxy in $PROXIES_FILE"
}

ensure_dependencies() {
  log "installo dipendenze di sistema (docker/python)..."
  run_root apt-get update
  run_root apt-get -y install docker.io python3 python3-venv python3-pip curl
  run_root systemctl enable --now docker || true
}

setup_python_env() {
  log "configuro ambiente python..."
  if [ ! -d ".venv" ]; then
    python3 -m venv .venv
  fi
  # shellcheck disable=SC1091
  source .venv/bin/activate
  pip install --upgrade pip >/dev/null
  pip install -r requirements.txt >/dev/null
}

setup_properties() {
  if [ ! -f "$PROPERTIES_FILE" ]; then
    cp "$BASE_DIR/properties.conf" "$PROPERTIES_FILE"
  fi

  log "applico profilo ottimizzato/scalabile..."
  set_prop "USE_PROXIES" "true"
  set_prop "USE_SOCKS5_DNS" "true"
  set_prop "CHECK_PROXY_BEFORE_START" "true"
  set_prop "ENABLE_LOGS" "false"
  set_prop "AUTO_HEAL" "true"
  set_prop "ENABLE_HOST_GUARD" "true"
  set_prop "AUTO_REBOOT_ON_CRITICAL" "true"
  set_prop "DELAY_BETWEEN_TUN_AND_EARNAPP_SEC" "'30'"
  set_prop "START_DELAY_SEC" "'4'"
}

setup_web_service() {
  if command -v systemctl >/dev/null 2>&1; then
    log "installo servizio systemd dashboard..."
    run_root tee /etc/systemd/system/internetincome-web.service >/dev/null <<EOF
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
    run_root systemctl enable --now internetincome-web.service
  else
    log "systemd non disponibile, avvio dashboard in background..."
    nohup "$BASE_DIR/.venv/bin/python" "$BASE_DIR/app.py" >/tmp/internetincome-web.log 2>&1 &
  fi
}

start_stack() {
  log "riavvio stack earnapp..."
  bash "$BASE_DIR/internetIncome.sh" --delete >/dev/null 2>&1 || true
  bash "$BASE_DIR/internetIncome.sh" --start
}

show_result() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  log "completato."
  [ -n "$ip" ] && log "dashboard: http://$ip:8080"
  if [ -f "$BASE_DIR/earnapp-links.txt" ]; then
    log "link earnapp salvati in: $BASE_DIR/earnapp-links.txt"
  fi
}

main() {
  collect_proxies
  ensure_dependencies
  setup_python_env
  setup_properties
  setup_web_service
  start_stack
  show_result
}

main "$@"

