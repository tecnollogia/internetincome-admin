#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${1:-$HOME/internetincome}"
BRANCH="${2:-main}"
WEB_PORT="${WEB_PORT:-8080}"

sudo apt-get update
sudo apt-get -y install wget unzip python3 python3-venv python3-pip docker.io curl
sudo systemctl enable --now docker

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

wget -O internetincome.zip "https://github.com/engageub/InternetIncome/archive/refs/heads/${BRANCH}.zip"
unzip -o internetincome.zip

SRC_DIR="$INSTALL_DIR/InternetIncome-${BRANCH}"
if [ ! -d "$SRC_DIR" ]; then
  echo "Source dir not found: $SRC_DIR"
  exit 1
fi

cd "$SRC_DIR"
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

sudo tee /etc/systemd/system/internetincome-web.service >/dev/null <<EOF
[Unit]
Description=InternetIncome EarnApp Web Console
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$SRC_DIR
Environment=WEB_HOST=0.0.0.0
Environment=WEB_PORT=$WEB_PORT
ExecStart=$SRC_DIR/.venv/bin/python $SRC_DIR/app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now internetincome-web.service

echo "Installed at: $SRC_DIR"
echo "Web UI: http://$(hostname -I | awk '{print $1}'):$WEB_PORT"
