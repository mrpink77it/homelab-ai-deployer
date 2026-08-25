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
LOG_PID=""

# Funzione per pulire il processo di log se lo script viene chiuso forzatamente
cleanup() {
    if [ -n "$LOG_PID" ]; then
        kill $LOG_PID 2>/dev/null || true
    fi
}
# La direttiva trap cattura l'uscita (EXIT) o l'interruzione manuale (Ctrl+C)
trap cleanup EXIT INT TERM

echo "[1/6] Verifica e arresto di processi precedenti..."
if systemctl is-active --quiet homelab-ai-forge 2>/dev/null; then
    echo "Servizio Forge attualmente in esecuzione. Arresto in corso..."
    systemctl stop homelab-ai-forge
fi

echo "[2/6] Aggiornamento sistema e installazione dipendenze..."
apt-get update -y
apt-get install -y wget git python3 python3-venv python3-pip libgl1 libglib2.0-0 bc curl

echo "[3/6] Clonazione repository Forge in $FORGE_DIR..."
if [ ! -d "$FORGE_DIR" ]; then
    git clone "$FORGE_REPO" "$FORGE_DIR"
else
    echo "Directory già esistente, eseguo pull per aggiornamento..."
    cd "$FORGE_DIR" && git pull
fi

if ! id -u forge > /dev/null 2>&1; then
    echo "[4/6] Creazione utente di sistema 'forge'..."
    useradd -r -s /bin/false forge
fi

chown -R forge:forge "$FORGE_DIR"

echo "[5/6] Generazione del servizio systemd..."
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

echo "[6/6] Avvio monitoraggio dell'installazione..."
echo "ATTENZIONE: Il primo avvio richiede il download di svariati GB (PyTorch, modelli)."
echo "Visualizzazione dei log in tempo reale in corso..."
echo "------------------------------------------------------------------------"

# Lancia journalctl in background e salva l'ID del processo (PID)
journalctl -u homelab-ai-forge -f -n 20 &
LOG_PID=$!

TIMEOUT=1800 # Timeout di 30 minuti (1800 secondi)
ELAPSED=0
SLEEP_INTERVAL=5

# Watchdog di avvio (silenzioso, i log appaiono a schermo grazie al processo background)
while true; do
    # 1. Controlla se il servizio è andato in crash
    if systemctl is-failed --quiet homelab-ai-forge; then
        echo -e "\n\n[ERRORE CRITICO] Il servizio homelab-ai-forge è andato in crash!"
        exit 1
    fi

    # 2. Controlla se l'API risponde
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL" || true)
    
    if [ "$HTTP_STATUS" -eq 200 ] || [ "$HTTP_STATUS" -eq 404 ]; then
        echo -e "\n\n[SUCCESSO] Forge è pienamente operativo e l'API è in ascolto!"
        break
    fi

    # 3. Aggiorna i contatori
    sleep $SLEEP_INTERVAL
    ELAPSED=$((ELAPSED + SLEEP_INTERVAL))

    # 4. Controllo Timeout
    if [ $ELAPSED -gt $TIMEOUT ]; then
        echo -e "\n\n[TIMEOUT] Sono passati 30 minuti e l'API non è ancora pronta."
        exit 1
    fi
done

echo "========================================================================"
echo "Installazione completata e validata!"
echo "Endpoint API disponibile per Open WebUI: http://127.0.0.1:7860"
echo "========================================================================"
