#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

SERVICE_FILE="/etc/systemd/system/llama-cpu.service"
MODEL_DIR="/home/alex/llama_models"
PORT=8082
THREADS=8

if [ ! -f "/opt/llama.cpp/build/bin/llama-server" ]; then
  echo "[-] Errore: Binario llama-server non trovato in /opt/llama.cpp. Esegui prima setup_vulkan_llama.sh."
  exit 1
fi

echo "[*] Creazione directory modelli se non esiste..."
mkdir -p "$MODEL_DIR"

echo "[*] Generazione del file systemd in $SERVICE_FILE..."
cat << EOF_SERVICE > "$SERVICE_FILE"
[Unit]
Description=Llama.cpp CPU Support Server (Port $PORT)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/llama.cpp/build/bin
ExecStart=/opt/llama.cpp/build/bin/llama-server --host 127.0.0.1 --port $PORT --models-dir $MODEL_DIR -ngl 0 -t $THREADS --cache-type-k q4_0 --cache-type-v q4_0
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_SERVICE

echo "[*] Ricarico systemd, abilito e avvio il servizio..."
systemctl daemon-reload
systemctl enable llama-cpu.service
systemctl start llama-cpu.service

echo "================================================================="
echo "[OK] Servizio Llama CPU avviato con successo sulla porta $PORT!"
echo " Stato: sudo systemctl status llama-cpu"
echo " Log: sudo journalctl -u llama-cpu -f"
echo "================================================================="
