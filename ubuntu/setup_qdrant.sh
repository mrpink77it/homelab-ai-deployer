#!/usr/bin/env bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

INSTALL_DIR="/opt/qdrant"
SERVICE_FILE="/etc/systemd/system/qdrant.service"
CURRENT_USER="${SUDO_USER:-root}"

echo "[*] Creazione directory in $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR/config" "$INSTALL_DIR/data"

echo "[*] Recupero dell'ultimo binario stabile di Qdrant da GitHub..."
DOWNLOAD_URL=$(curl -s https://api.github.com/repos/qdrant/qdrant/releases/latest | grep "browser_download_url" | grep "x86_64-unknown-linux-gnu.tar.gz" | cut -d '"' -f 4)

if [ -z "$DOWNLOAD_URL" ]; then
  echo "[-] Errore nel recupero dell'URL di download da GitHub."
  exit 1
fi

echo "[*] Download da: $DOWNLOAD_URL"
curl -L "$DOWNLOAD_URL" -o /tmp/qdrant.tar.gz

echo "[*] Estrazione del binario..."
tar -xzf /tmp/qdrant.tar.gz -C "$INSTALL_DIR"
rm /tmp/qdrant.tar.gz
chmod +x "$INSTALL_DIR/qdrant"

echo "[*] Creazione file di configurazione..."
cat << 'EOF' > "$INSTALL_DIR/config/config.yaml"
storage:
  storage_path: /opt/qdrant/data
service:
  http_port: 6333
  grpc_port: 6334
EOF

echo "[*] Configurazione permessi..."
chown -R "$CURRENT_USER:$CURRENT_USER" "$INSTALL_DIR"

echo "[*] Creazione unit file systemd in $SERVICE_FILE..."
cat << EOF > "$SERVICE_FILE"
[Unit]
Description=Qdrant Vector Database Native Binary
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/qdrant --config-path $INSTALL_DIR/config/config.yaml
Restart=always
RestartSec=5
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "[*] Abilitazione e avvio del servizio..."
systemctl daemon-reload
systemctl enable qdrant.service
systemctl start qdrant.service

echo "================================================================="
echo "[OK] Qdrant installato e avviato nativamente!"
echo " Endpoint HTTP: http://127.0.0.1:6333"
echo " Stato servizio: sudo systemctl status qdrant"
echo " Log in tempo reale: sudo journalctl -u qdrant -f"
echo "================================================================="
