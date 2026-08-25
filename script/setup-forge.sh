#!/bin/bash
# ==============================================================================
# Installazione Stable Diffusion WebUI Forge (Ottimizzato per 8GB VRAM)
# Ambiente: Bare-Metal / LXC (Debian/Ubuntu)
# ==============================================================================

set -euo pipefail

# Variabili
FORGE_DIR="/opt/sd-forge"
FORGE_REPO="https://github.com/lllyasviel/stable-diffusion-webui-forge.git"
SERVICE_FILE="/etc/systemd/system/homelab-ai-forge.service"
API_URL="http://127.0.0.1:7860/sdapi/v1/sd-models"

echo "[1/5] Aggiornamento sistema e installazione dipendenze..."
apt-get update -y
apt-get install -y wget git python3 python3-venv python3-pip libgl1 libglib2.0-0 bc curl

echo "[2/5] Clonazione repository Forge in $FORGE_DIR..."
if [ ! -d "$FORGE_DIR" ]; then
    git clone "$FORGE_REPO" "$FORGE_DIR"
else
    echo "Directory già esistente, eseguo pull per aggiornamento..."
    cd "$FORGE_DIR" && git pull
fi

if ! id -u forge > /dev/null 2>&1; then
    echo "[3/5] Creazione utente di sistema 'forge'..."
    useradd -r -s /bin/false forge
fi

chown -R forge:forge "$FORGE_DIR"

echo "[4/5] Generazione del servizio systemd..."
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Stable Diffusion WebUI Forge (Homelab AI)
After=network.target

[Service]
Type=simple
User=forge
WorkingDirectory=$FORGE_DIR
ExecStart=/bin/bash $FORGE_DIR/webui.sh --api --listen --port 7860
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now homelab-ai-forge

echo "[5/5] Attendendo l'inizializzazione di Forge..."
echo "ATTENZIONE: Il primo avvio richiede il download di svariati GB (PyTorch, modelli)."
echo "L'operazione può durare 10-20 minuti a seconda della connessione."
echo "Non chiudere questo terminale..."

TIMEOUT=1800 # Timeout di 30 minuti (1800 secondi)
ELAPSED=0
SLEEP_INTERVAL=10

# Watchdog di avvio
while true; do
    # 1. Controlla se il servizio è andato in crash
    if systemctl is-failed --quiet homelab-ai-forge; then
        echo -e "\n\n[ERRORE CRITICO] Il servizio homelab-ai-forge è andato in crash!"
        echo "Ultime 20 righe del log per il debug:"
        journalctl -u homelab-ai-forge -n 20 --no-pager
        exit 1
    fi

    # 2. Controlla se l'API risponde
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL" || true)
    
    if [ "$HTTP_STATUS" -eq 200 ] || [ "$HTTP_STATUS" -eq 404 ]; then
        # Se risponde qualcosa, il webserver Gradio/FastAPI è in piedi
        echo -e "\n\n[SUCCESSO] Forge è pienamente operativo e l'API è in ascolto!"
        break
    fi

    # 3. Aggiorna i contatori
    sleep $SLEEP_INTERVAL
    ELAPSED=$((ELAPSED + SLEEP_INTERVAL))
    echo -n "."

    # 4. Controllo Timeout
    if [ $ELAPSED -gt $TIMEOUT ]; then
        echo -e "\n\n[TIMEOUT] Sono passati 30 minuti e l'API non è ancora pronta."
        echo "Controlla i log manualmente con: journalctl -u homelab-ai-forge -f"
        exit 1
    fi
done

echo "========================================================================"
echo "Installazione completata e validata!"
echo "Endpoint API disponibile per Open WebUI: http://127.0.0.1:7860"
echo "========================================================================"
