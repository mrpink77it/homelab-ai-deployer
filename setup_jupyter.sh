#!/usr/bin/env bash
# ==============================================================================
# Installer & Checker Generico JupyterLab (LXC / VM / Baremetal)
# ==============================================================================

set -e

# Controllo permessi root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Errore: Questo script deve essere eseguito come root (o con sudo)."
  exit 1
fi

VENV_DIR="/opt/jupyter_env"
JUPYTER_BIN="$VENV_DIR/bin/jupyter"
NOTEBOOKS_DIR="/root/notebooks"
SERVICE_FILE="/etc/systemd/system/jupyter.service"

# Funzione per mostrare link, token e comandi di gestione
print_access_info() {
  local ip_addr token
  ip_addr=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' || hostname -I | awk '{print $1}')
  token=$("$JUPYTER_BIN" server list 2>/dev/null | grep -oP 'token=\K[a-z0-9]+' | head -n 1 || echo "")

  echo "📁 Cartella dei Notebook : $NOTEBOOKS_DIR"
  echo "🐍 Ambiente Virtuale Python: $VENV_DIR"
  echo -e "\n🌐 URL di collegamento:"
  if [ -n "$token" ]; then
      echo "👉 http://${ip_addr:-<IP_SERVER>}:8888/lab?token=$token"
  else
      echo "👉 http://${ip_addr:-<IP_SERVER>}:8888"
      echo "   (Nota: Nessun token rilevato, potrebbe essere configurata una password fissa)"
  fi
  echo -e "\n🛠️ Comandi utili:"
  echo "   • Stato servizio  : systemctl status jupyter"
  echo "   • Riavvia servizio: systemctl restart jupyter"
  echo "   • Visualizza log  : journalctl -u jupyter -f"
  echo "   • Imposta password: $JUPYTER_BIN lab password"
  echo "===================================================="
}

# ------------------------------------------------------------------------------
# 🔍 1. CONTROLLO SE JUPYTERLAB È GIÀ INSTALLATO
# ------------------------------------------------------------------------------
if [ -f "$JUPYTER_BIN" ] && [ -f "$SERVICE_FILE" ]; then
    echo "===================================================="
    echo "ℹ️  JUPYTERLAB È GIÀ INSTALLATO SU QUESTA MACCHINA"
    echo "===================================================="
    
    # Assicura che il demone sia attivo
    if ! systemctl is-active --quiet jupyter; then
        echo "▶️ Il servizio era arrestato. Avvio del demone JupyterLab..."
        systemctl start jupyter
        sleep 2
    else
        echo "✅ Il servizio JupyterLab è attivo e in esecuzione."
    fi

    print_access_info
    exit 0
fi

# ------------------------------------------------------------------------------
# 🚀 2. INSTALLAZIONE SE NON PRESENTE
# ------------------------------------------------------------------------------
echo "===================================================="
echo "      🚀 INSTALLAZIONE GENERICA JUPYTERLAB          "
echo "===================================================="

# Aggiornamento ed installazione pacchetti di sistema
echo "📦 Aggiornamento repository e installazione pacchetti di base..."
apt-get update -y
apt-get install -y python3-pip python3-venv curl iproute2

# Creazione cartella di lavoro
mkdir -p "$NOTEBOOKS_DIR"

# Creazione ambiente virtuale isolato
echo "🐍 Creazione dell'ambiente virtuale in $VENV_DIR..."
python3 -m venv "$VENV_DIR"

# Installazione di JupyterLab nel venv
echo "⬇️ Installazione di JupyterLab (attendi qualche secondo)..."
"$VENV_DIR/bin/pip" install --upgrade pip > /dev/null
"$VENV_DIR/bin/pip" install jupyterlab

# Configurazione servizio Systemd
echo "⚙️ Configurazione servizio Systemd (jupyter.service)..."
cat << EOF > "$SERVICE_FILE"
[Unit]
Description=JupyterLab Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$NOTEBOOKS_DIR
ExecStart=$JUPYTER_BIN lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Abilitazione e avvio del demone
echo "▶️ Abilitazione e avvio del servizio JupyterLab..."
systemctl daemon-reload
systemctl enable jupyter
systemctl restart jupyter

sleep 3

echo -e "\n===================================================="
echo "✅ INSTALLAZIONE E AVVIO COMPLETATI!"
print_access_info
