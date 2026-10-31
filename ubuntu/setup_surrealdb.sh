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

echo "[*] Creazione della struttura directory in $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$DATA_DIR"
mkdir -p "$BIN_DIR"

echo "[*] Installazione di SurrealDB tramite lo script ufficiale..."
curl -sSf https://install.surrealdb.com | sh

# Individua dove è stato posizionato il binario dal client ufficiale
FOUND_SURREAL=""
if [ -f "/usr/local/bin/surreal" ]; then
  FOUND_SURREAL="/usr/local/bin/surreal"
elif [ -f "$HOME/.surrealdb/surreal" ]; then
  FOUND_SURREAL="$HOME/.surrealdb/surreal"
elif [ -f "/root/.surrealdb/surreal" ]; then
  FOUND_SURREAL="/root/.surrealdb/surreal"
else
  FOUND_SURREAL=$(find / -name "surreal" -type f 2>/dev/null | grep -E '(\.surrealdb|bin/surreal)' | head -n 1 || true)
fi

if [ -z "$FOUND_SURREAL" ] || [ ! -f "$FOUND_SURREAL" ]; then
  echo "[-] Errore: Impossibile trovare il binario di SurrealDB dopo l'installazione."
  exit 1
fi

echo "[*] Copia del binario in $BIN_DIR/surreal..."
cp "$FOUND_SURREAL" "$BIN_DIR/surreal"
chmod +x "$BIN_DIR/surreal"

echo "[*] Configurazione del servizio systemd con persistenza SurrealKV..."
cat << EOF > "$SERVICE_FILE"
[Unit]
Description=SurrealDB Server (Home in /opt/surrealdb)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$BIN_DIR/surreal start --log info --user root --pass root surrealkv://$DATA_DIR/surreal.db
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable surrealdb.service
systemctl restart surrealdb.service

echo ""
echo "[OK] SurrealDB installato con successo interamente in $INSTALL_DIR."
echo "--------------------------------------------------------"
echo " Home directory: $INSTALL_DIR"
echo " Binario:        $BIN_DIR/surreal"
echo " Database dir:   $DATA_DIR"
echo " Servizio HTTP:  http://127.0.0.1:8000"
echo "--------------------------------------------------------"
