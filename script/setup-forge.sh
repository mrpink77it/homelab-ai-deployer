#!/bin/bash
# ==============================================================================
# Installazione Stable Diffusion WebUI Forge (Ottimizzato per 8GB VRAM)
# Ambiente: Bare-Metal / LXC (Debian 13) - Homelab AI Deployer
# ==============================================================================

set -euo pipefail

# Variabili
FORGE_DIR="/opt/sd-forge"
FORGE_REPO="https://github.com/lllyasviel/stable-diffusion-webui-forge.git"
SERVICE_FILE="/etc/systemd/system/homelab-ai-forge.service"
API_URL="http://127.0.0.1:7860/sdapi/v1/sd-models"
LOG_PID=""

cleanup() {
    if [ -n "$LOG_PID" ]; then
        kill $LOG_PID 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

echo "[1/7] PULIZIA PROFONDA: Rimozione servizi, file e utente precedenti..."
if systemctl is-active --quiet homelab-ai-forge 2>/dev/null; then
    echo "  -> Arresto del servizio attivo..."
    systemctl stop homelab-ai-forge
fi

if systemctl is-enabled --quiet homelab-ai-forge 2>/dev/null; then
    echo "  -> Disabilitazione del servizio..."
    systemctl disable homelab-ai-forge
fi

if [ -f "$SERVICE_FILE" ]; then
    echo "  -> Rimozione file unit systemd..."
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
fi

if [ -d "$FORGE_DIR" ]; then
    echo "  -> Rimozione distruttiva della directory $FORGE_DIR..."
    rm -rf "$FORGE_DIR"
fi

if id -u forge > /dev/null 2>&1; then
    echo "  -> Chiusura processi residui e rimozione utente 'forge'..."
    killall -9 -u forge 2>/dev/null || true
    userdel -r forge 2>/dev/null || true
fi

echo "[2/7] Aggiornamento sistema e installazione dipendenze..."
apt-get update -y
apt-get install -y wget git python3 python3-venv python3-pip libgl1 libglib2.0-0 bc curl psmisc google-perftools

echo "[3/7] Installazione 'uv' (Gestore Python ultra-veloce)..."
curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh

echo "[4/7] Creazione utente 'forge' e clonazione repository sicura..."
useradd -r -m -s /bin/false forge
chown -R forge:forge /home/forge

# Creiamo la directory e assegniamo i permessi PRIMA del clone
mkdir -p "$FORGE_DIR"
chown -R forge:forge "$FORGE_DIR"

# Forziamo l'utente forge a clonare per aggirare i limiti di root in LXC unprivileged
su -s /bin/bash forge -c "git clone \"$FORGE_REPO\" \"$FORGE_DIR\""

echo "[5/7] Generazione ambiente Python 3.10 isolato tramite uv..."
# Generiamo il venv con seed per avere pip e setuptools
su -s /bin/bash forge -c "cd $FORGE_DIR && uv venv --seed -p 3.10.14 venv"

# FIX: Downgrade di setuptools per permettere la compilazione di OpenAI CLIP (pkg_resources)
su -s /bin/bash forge -c "cd $FORGE_DIR && venv/bin/pip install 'setuptools<70'"

echo "[6/7] Generazione del servizio systemd..."
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Stable Diffusion WebUI Forge (Homelab AI)
After=network.target

[Service]
Type=simple
User=forge
WorkingDirectory=$FORGE_DIR
Environment="PYTHON=$FORGE_DIR/venv/bin/python"
ExecStart=/bin/bash $FORGE_DIR/webui.sh --api --listen --port 7860
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now homelab-ai-forge

echo "[7/7] Avvio monitoraggio dell'installazione pulita..."
echo "ATTENZIONE: Verranno scaricati i componenti Pytorch e i Modelli Base."
echo "Visualizzazione dei log in tempo reale in corso..."
echo "------------------------------------------------------------------------"

journalctl -u homelab-ai-forge -f -n 20 &
LOG_PID=$!

TIMEOUT=1800
ELAPSED=0
SLEEP_INTERVAL=5

while true; do
    if systemctl is-failed --quiet homelab-ai-forge; then
        echo -e "\n\n[ERRORE CRITICO] Il servizio homelab-ai-forge è andato in crash!"
        exit 1
    fi

    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL" || true)
    
    if [ "$HTTP_STATUS" -eq 200 ] || [ "$HTTP_STATUS" -eq 404 ]; then
        echo -e "\n\n[SUCCESSO] Forge è pienamente operativo e l'API è in ascolto!"
        break
    fi

    sleep $SLEEP_INTERVAL
    ELAPSED=$((ELAPSED + SLEEP_INTERVAL))

    if [ $ELAPSED -gt $TIMEOUT ]; then
        echo -e "\n\n[TIMEOUT] Sono passati 30 minuti e l'API non è ancora pronta."
        exit 1
    fi
done

echo "========================================================================"
echo "Installazione Completata e Validata!"
echo "Endpoint API disponibile per Open WebUI: http://127.0.0.1:7860"
echo "========================================================================"
