#!/bin/bash
# ==============================================================================
# Installazione Completa e Definitiva Stable Diffusion WebUI Forge
# Ambiente: Bare-Metal / LXC (Debian 13)
# ==============================================================================

set -euo pipefail

FORGE_DIR="/opt/sd-forge"
SERVICE_FILE="/etc/systemd/system/homelab-ai-forge.service"
API_URL="http://127.0.0.1:7860/sdapi/v1/sd-models"
LOG_PID=""

cleanup() {
    if [ -n "$LOG_PID" ]; then
        kill $LOG_PID 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

echo "[1/6] Pulizia totale installazione precedente..."
systemctl stop homelab-ai-forge 2>/dev/null || true
systemctl disable homelab-ai-forge 2>/dev/null || true
rm -f "$SERVICE_FILE"
rm -rf "$FORGE_DIR"
systemctl daemon-reload

echo "[2/6] Installazione dipendenze di sistema su Debian 13..."
apt-get update -y
apt-get install -y wget git libgl1 libglib2.0-0 bc curl psmisc google-perftools python3-full

echo "[3/6] Installazione di 'uv' e preparazione utente..."
curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh

if ! id -u forge > /dev/null 2>&1; then
    useradd -r -m -s /bin/false forge
fi
mkdir -p "$FORGE_DIR"
chown -R forge:forge "$FORGE_DIR" /home/forge

echo "[4/6] Clonazione repository Forge..."
su -s /bin/bash forge -c "git clone https://github.com/lllyasviel/stable-diffusion-webui-forge.git \"$FORGE_DIR\""

echo "[5/6] Creazione venv, ambienti Python e pre-installazione pacchetti stabili..."
su -s /bin/bash forge -c "cd $FORGE_DIR && uv venv --python 3.10.14 venv"

su -s /bin/bash forge -c "$FORGE_DIR/venv/bin/python -m ensurepip --upgrade"
su -s /bin/bash forge -c "$FORGE_DIR/venv/bin/python -m pip install --upgrade pip"
su -s /bin/bash forge -c "$FORGE_DIR/venv/bin/python -m pip install 'setuptools<70' wheel ftfy regex tqdm"
# Installazione pacchetti stabili e blocco versioni NumPy/OpenCV anti-conflitto
su -s /bin/bash forge -c "$FORGE_DIR/venv/bin/python -m pip install 'numpy<2' 'opencv-python==4.11.0.86'"
su -s /bin/bash forge -c "$FORGE_DIR/venv/bin/python -m pip install --no-build-isolation --no-deps https://github.com/openai/CLIP/archive/d50d76daa670286dd6cacf3bcd80b5e4823fc8e1.zip"

echo "[6/6] Configurazione systemd con skip-install e avvio del monitoraggio..."
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Stable Diffusion WebUI Forge (Homelab AI)
After=network.target

[Service]
Type=simple
User=forge
WorkingDirectory=$FORGE_DIR
Environment="PYTHON=$FORGE_DIR/venv/bin/python"
Environment="PIP_NO_BUILD_ISOLATION=1"
Environment="SD_WEBUI_REQS_FILE="
ExecStart=/bin/bash $FORGE_DIR/webui.sh --api --listen --port 7860 --skip-install
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now homelab-ai-forge

echo "------------------------------------------------------------------------"
echo "ATTENZIONE: Verranno scaricati i componenti PyTorch e i Modelli Base."
echo "Visualizzazione dei log in tempo reale (premi Ctrl+C per uscire dal log)..."
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
echo "Installazione Completata e Validata con successo!"
echo "Endpoint API disponibile per Open WebUI: http://127.0.0.1:7860"
echo "========================================================================"
