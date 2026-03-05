# InternetIncome EarnApp Admin Stack

Stack ottimizzato per Raspberry Pi e mini PC 4GB:
- solo EarnApp
- Docker + proxy
- dashboard admin moderna
- monitoraggio continuo + auto-healing
- host guard con escalation anti-crash (fino a reboot opzionale)

## Funzioni principali
- Start graduale degli stack (evita picchi su hardware debole)
- Routing DNS via SOCKS5 opzionale (`USE_SOCKS5_DNS=true`) per ridurre leak DNS e traffico incoerente
- Limiti CPU/RAM/PIDs per ogni container
- Check proxy pre-avvio e monitor online/offline continuo
- Storico downtime proxy (offline now + total offline)
- Auto-restart container con cooldown
- Host Guard: rileva condizioni critiche host (CPU/RAM/Disk/Load) e applica escalation automatica:
  - recycle stack (`--delete` + `--start`)
  - restart Docker
  - reboot host (se `AUTO_REBOOT_ON_CRITICAL=true`)
- Metriche host (CPU, RAM, uptime) e usage container in dashboard
- Salvataggio link EarnApp in `earnapp-links.txt`

## Clonazione con wget
```bash
wget -O main.zip https://github.com/engageub/InternetIncome/archive/refs/heads/main.zip
unzip -o main.zip
cd InternetIncome-main
```

## Quick start locale
```bash
sudo bash internetIncome.sh --install
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python app.py
```
Dashboard: `http://<ip-host>:8080`

## Setup totalmente automatico (chiede solo i proxy)
```bash
chmod +x auto_everything.sh
./auto_everything.sh
```
Lo script:
- chiede i proxy all'avvio (input multilinea fino a `END`)
- normalizza i formati (`ip:port:user:pass` -> `socks5://...`)
- installa Docker + Python + dipendenze
- applica config ottimizzata e scalabile
- avvia dashboard e stack EarnApp automaticamente

## Deploy automatico su Raspberry/Mini PC (wget + systemd)
Nel progetto è incluso:
- [setup_node.sh](/c:/Users/khan.dip.2008.IAV/Desktop/Progetto%20mio/InternetIncome/deploy/setup_node.sh)

Dopo aver copiato questa cartella sul nodo remoto (es. `scp`/`rsync`), esegui:
```bash
cd InternetIncome/deploy
bash setup_node.sh "$HOME/internetincome" main
```

Il setup:
- installa Docker + Python
- scarica il progetto con `wget`
- crea virtualenv
- installa dipendenze
- registra `internetincome-web.service` (auto-restart on boot)

## Dashboard admin
La web UI include:
- configurazione completa `properties.conf`
- editor proxy (`ip:port:user:pass` o URL con schema)
- stato live container/proxy
- test proxy on-demand
- eventi auto-heal
- azioni: Start / Stop / Delete Backup

## Formato proxy
Supportati:
```text
ip:port:user:pass
http://user:pass@ip:port
https://user:pass@ip:port
socks5://user:pass@ip:port
```

## File chiave
- Orchestratore: [internetIncome.sh](/c:/Users/khan.dip.2008.IAV/Desktop/Progetto%20mio/InternetIncome/internetIncome.sh)
- Backend dashboard: [app.py](/c:/Users/khan.dip.2008.IAV/Desktop/Progetto%20mio/InternetIncome/app.py)
- Frontend: [index.html](/c:/Users/khan.dip.2008.IAV/Desktop/Progetto%20mio/InternetIncome/templates/index.html), [app.js](/c:/Users/khan.dip.2008.IAV/Desktop/Progetto%20mio/InternetIncome/static/app.js), [style.css](/c:/Users/khan.dip.2008.IAV/Desktop/Progetto%20mio/InternetIncome/static/style.css)
- Config: [properties.conf](/c:/Users/khan.dip.2008.IAV/Desktop/Progetto%20mio/InternetIncome/properties.conf)
- Proxy list: [proxies.txt](/c:/Users/khan.dip.2008.IAV/Desktop/Progetto%20mio/InternetIncome/proxies.txt)

## Comandi runtime
```bash
bash internetIncome.sh --start
bash internetIncome.sh --delete
bash internetIncome.sh --deleteBackup
```

## Note operative
- `MAX_STACKS` vuoto => calcolo automatico in base a RAM/CPU
- `START_DELAY_SEC` riduce i picchi di avvio
- `DELAY_BETWEEN_TUN_AND_EARNAPP_SEC` rallenta l'innesco tra TUN e EarnApp per evitare burst
- `USE_SOCKS5_DNS=true` abilita tunnel DNS su proxy socks5 tramite `ghcr.io/heiher/hev-socks5-tunnel`
- `AUTO_HEAL=true` riavvia i container stopped automaticamente
- `PROXY_CHECK_INTERVAL_SEC` controlla periodicamente i proxy
- `ENABLE_HOST_GUARD=true` abilita la protezione host
- `AUTO_REBOOT_ON_CRITICAL=true` abilita reboot automatico come ultima risorsa
