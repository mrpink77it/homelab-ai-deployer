#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

COLIBRI_DIR="/opt/colibri"
SERVICE_FILE="/etc/systemd/system/colibri-engine.service"
MODEL_DIR="/root/llama_models"
PORT=8083

echo "=== 1. Disattivazione vecchio servizio llama-cpu (se presente) ==="
if systemctl is-active --quiet llama-cpu.service 2>/dev/null; then
  echo "[*] Arresto e disabilitazione llama-cpu.service..."
  systemctl stop llama-cpu.service || true
  systemctl disable llama-cpu.service || true
  rm -f /etc/systemd/system/llama-cpu.service
  systemctl daemon-reload
  echo "[OK] llama-cpu rimosso dai servizi systemd."
fi

echo "=== 2. Installazione dipendenze di base e Python 3 ==="
apt-get update && apt-get install -y git build-essential gcc g++ make python3 python3-pip

echo "=== 3. Download/Aggiornamento repository Colibri ==="
if [ ! -d "$COLIBRI_DIR" ]; then
  echo "[*] Clonazione di Colibri in $COLIBRI_DIR..."
  git clone https://github.com/JustVugg/colibri.git "$COLIBRI_DIR"
else
  echo "[*] Aggiornamento repository esistente in $COLIBRI_DIR..."
  cd "$COLIBRI_DIR" && git pull
fi

echo "=== 4. Compilazione Colibri (C nativo via Make) ==="
cd "$COLIBRI_DIR"
make clean || true
make -j$(nproc)

echo "=== 5. Configurazione ed avvio del servizio systemd con il launcher Python (Porta $PORT) ==="
if [ ! -f "$COLIBRI_DIR/c/coli" ]; then
  echo "[-] Errore: Launcher c/coli non trovato."
  exit 1
fi

cat << EOF_SERVICE > "$SERVICE_FILE"
[Unit]
Description=Colibri MoE Engine Launcher (Port $PORT)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$COLIBRI_DIR
ExecStart=python3 $COLIBRI_DIR/c/coli serve --model $MODEL_DIR --port $PORT
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_SERVICE

systemctl daemon-reload
systemctl enable colibri-engine.service
systemctl restart colibri-engine.service

echo ""
echo "================================================================="
echo "[OK] Script completato con successo!"
echo " Motore Colibri (CPU Only) avviato tramite launcher Python."
echo " Endpoint HTTP API: http://127.0.0.1:$PORT"
echo " Directory Modelli: $MODEL_DIR"
echo " Stato: sudo systemctl status colibri-engine"
echo " Log in tempo reale: sudo journalctl -u colibri-engine -f"
echo "================================================================="
