#!/usr/bin/env bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

CURRENT_USER="${SUDO_USER:-root}"
USER_HOME=$(eval echo "~$CURRENT_USER")
SERVICE_FILE="/etc/systemd/system/unsloth-studio.service"

echo "[*] Installazione di Unsloth Studio per l'utente $CURRENT_USER..."
sudo -u "$CURRENT_USER" bash -c 'curl -fsSL https://unsloth.ai/install.sh | sh' || echo "[*] Script di installazione eseguito."

echo "[*] Creazione dell'unità systemd globale in $SERVICE_FILE..."
cat << EOF_SERVICE > "$SERVICE_FILE"
[Unit]
Description=Unsloth Studio Global CUDA Service (Port 8888)
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
Environment=CUDA_DEVICE_ORDER=PCI_BUS_ID
Environment=CUDA_VISIBLE_DEVICES=0
ExecStart=$USER_HOME/.local/bin/unsloth studio --host 0.0.0.0 --port 8888
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_SERVICE

echo "[*] Ricarico systemd, abilito e avvio il servizio..."
systemctl daemon-reload
systemctl enable unsloth-studio.service
systemctl start unsloth-studio.service

echo "================================================================="
echo "[OK] Unsloth Studio installato e avviato come servizio globale!"
echo " Endpoint Web UI: http://127.0.0.1:8888"
echo " Stato servizio: sudo systemctl status unsloth-studio"
echo " Log in tempo reale: sudo journalctl -u unsloth-studio -f"
echo "================================================================="
