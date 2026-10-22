#!/usr/bin/env bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

INSTALL_DIR="/opt/surrealdb"
DATA_DIR="$INSTALL_DIR/data"
BIN_DIR="$INSTALL_DIR/bin"
SERVICE_FILE="/etc/systemd/system/surrealdb.service"
CURRENT_USER="${SUDO_USER:-root}"

echo "[*] Creazione della struttura directory in $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$DATA_DIR"
mkdir -p "$BIN_DIR"

echo "[*] Installazione del binario di SurrealDB in $INSTALL_DIR/bin..."
# Scarica temporaneamente e sposta il binario nel path dedicato in /opt/surrealdb/bin
curl -sSf https://install.surrealdb.com | sh
if [ -f "/usr/local/bin/surreal" ]; then
  mv /usr/local/bin/surreal "$BIN_DIR/surreal"
elif [ -f "$HOME/.surrealdb/surreal" ]; then
  mv "$HOME/.surrealdb/surreal" "$BIN_DIR/surreal"
else
  # Fallback: scarica direttamente il binario se lo script di installazione globale non ha piazzato il file atteso
  curl -L https://github.com/surrealdb/surrealdb/releases/latest/download/surreal-linux-amd64.tar.gz -o /tmp/surreal.tar.gz
  tar -xzf /tmp/surreal.tar.gz -C /tmp
  mv /tmp/surreal "$BIN_DIR/surreal"
  rm -f /tmp/surreal.tar.gz
fi

chmod +x "$BIN_DIR/surreal"

echo "[*] Configurazione del servizio systemd con home in $INSTALL_DIR..."
cat << EOF > "$SERVICE_FILE"
[Unit]
Description=SurrealDB Server (Home in /opt/surrealdb)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$BIN_DIR/surreal start --log info --user root --pass root file://$DATA_DIR/surreal.db
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable surrealdb.service
systemctl restart surrealdb.service

chown -R "$CURRENT_USER:$CURRENT_USER" "$INSTALL_DIR"

echo ""
echo "[OK] SurrealDB installato con successo interamente in $INSTALL_DIR."
echo "--------------------------------------------------------"
echo " Home directory: $INSTALL_DIR"
echo " Binario:        $BIN_DIR/surreal"
echo " Database file:  $DATA_DIR/surreal.db"
echo " Servizio HTTP:  http://127.0.0.1:8000"
echo "--------------------------------------------------------"
