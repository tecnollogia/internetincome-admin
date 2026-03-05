# InternetIncome EarnApp Admin (Guida Passo-Passo)

Questa versione usa solo **EarnApp + proxy + Docker** con dashboard web.

## 0) Errore che hai ora (`requirements.txt` mancante)
Se vedi:
```bash
ERROR: Could not open requirements file: No such file or directory: 'requirements.txt'
```
sei quasi sicuramente nella repo sbagliata (zip di `engageub/InternetIncome` originale).

Devi usare la tua repo personalizzata:
- `https://github.com/tecnollogia/internetincome-admin`

## 1) Installazione consigliata (script unico smart)
Su server Linux/Raspberry:

```bash
cd /home/server/income-mio
rm -rf internetincome-admin
git clone https://github.com/tecnollogia/internetincome-admin.git
cd internetincome-admin
chmod +x auto_everything.sh
./auto_everything.sh
```

Lo script apre un menu intelligente:
- `1` prima installazione completa
- `2` aggiorna solo proxy + restart stack
- `3` retune performance/scaling (senza restart)
- `4` start stack
- `5` stop stack
- `6` status (container, servizio web, link)

In modalità installazione:
- installa Docker + Python + dipendenze
- chiede i proxy all'inizio
- normalizza `ip:port:user:pass` in `socks5://...`
- applica tuning automatico in base a RAM/CPU (MAX_STACKS auto)
- avvia dashboard web + stack EarnApp

Durante l'esecuzione lo script mostra:
- step `START / IN CORSO / DONE` con secondi trascorsi
- log completo persistente in `auto_everything.log`

## 2) Avvio manuale (se non vuoi script automatico)

### 2.1 Clona repo corretta
```bash
git clone https://github.com/tecnollogia/internetincome-admin.git
cd internetincome-admin
```

### 2.2 Installa Docker
```bash
sudo apt-get update
sudo apt-get -y install docker.io
sudo systemctl enable --now docker
```

### 2.3 Installa dashboard
```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### 2.4 Inserisci proxy
Modifica `proxies.txt` (uno per riga), esempio:
```text
socks5://user:pass@ip:port
```

### 2.5 Avvia stack
```bash
bash internetIncome.sh --start
```

### 2.6 Avvia dashboard
```bash
python app.py
```
Apri: `http://IP_SERVER:8080`

## 3) Gestione
```bash
bash internetIncome.sh --start
bash internetIncome.sh --delete
bash internetIncome.sh --deleteBackup
```

## 4) Dove trovi i link EarnApp
File:
- `earnapp-links.txt`

Dashboard:
- sezione `EarnApp Links`
- sezione `EarnApp / Container / Proxy`

## 5) Config importanti (`properties.conf`)
- `USE_PROXIES=true`
- `USE_SOCKS5_DNS=true` (consigliato con socks5)
- `DELAY_BETWEEN_TUN_AND_EARNAPP_SEC='30'`
- `START_DELAY_SEC='4'`
- `AUTO_HEAL=true`
- `ENABLE_HOST_GUARD=true`
- `AUTO_REBOOT_ON_CRITICAL=true`
- `MAX_STACKS='all'` = usa tutti i proxy disponibili

Nota:
- 1 stack = 1 proxy + 1 container `tun` + 1 container `earnapp`

## 6) Troubleshooting rapido

### A) `requirements.txt` non trovato
Sei nella cartella sbagliata. Verifica:
```bash
pwd
ls
```
Devi vedere `app.py`, `requirements.txt`, `auto_everything.sh`.

### B) Docker non parte
```bash
sudo systemctl status docker
sudo systemctl restart docker
```

### C) Dashboard non apre
```bash
ss -lntp | grep 8080
```
Se chiusa, avvia:
```bash
source .venv/bin/activate
python app.py
```

### D) Nessun nodo parte
- controlla formato proxy
- usa `socks5://...`
- prova pochi proxy inizialmente (3-5)
- leggi output `bash internetIncome.sh --start`
