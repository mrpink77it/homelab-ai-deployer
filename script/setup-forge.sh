#!/bin/bash
# ==============================================================================
# Installazione Completa e Definitiva Stable Diffusion WebUI Forge
# Ambiente: Bare-Metal / LXC (Debian 13) - UI Animata, Fix & Modelli Inclusi
# ==============================================================================
set -euo pipefail
FORGE_DIR="/opt/sd-forge"
SERVICE_FILE="/etc/systemd/system/homelab-ai-forge.service"
API_URL="http://127.0.0.1:7860/sdapi/v1/sd-models"
MODELS_DIR="$FORGE_DIR/models/Stable-diffusion"
LOG_PID=""
SPINNER_PID=""

# Funzione per pulire i processi in background se l'utente preme Ctrl+C
cleanup() {
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null || true
    fi
    if [ -n "$LOG_PID" ]; then
        kill "$LOG_PID" 2>/dev/null || true
    fi
    tput cnorm 2>/dev/null || true # Ripristina il cursore
}
trap cleanup EXIT INT TERM

# --- FUNZIONI UX (SPINNER ANIMATO) --
start_spinner() {
    local msg="$1"
    tput civis 2>/dev/null || true # Nasconde il cursore
    (
        spin_chars='\|/-'
        while true; do
            for (( i=0; i<${#spin_chars}; i++ )); do
                sleep 0.15
                echo -en "\r\033[K${msg} \033[36m[${spin_chars:$i:1}]\033[0m"
            done
        done
    ) &
    SPINNER_PID=$!
}

stop_spinner() {
    local msg="$1"
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi
    echo -en "\r\033[K${msg} \033[32m[Completato]\033[0m\n"
    tput cnorm 2>/dev/null || true # Mostra il cursore
}
# ------------------------------------

start_spinner "[1/7] Pulizia totale installazione precedente..."
systemctl stop homelab-ai-forge 2>/dev/null || true
systemctl disable homelab-ai-forge 2>/dev/null || true
rm -f "$SERVICE_FILE"
rm -rf "$FORGE_DIR"
systemctl daemon-reload
stop_spinner "[1/7] Pulizia totale installazione precedente..."

start_spinner "[2/7] Installazione dipendenze di sistema su Debian 13..."
apt-get update -y > /dev/null 2>&1
apt-get install -y wget git libgl1 libglib2.0-0 bc curl psmisc google-perftools python3-full > /dev/null 2>&1
stop_spinner "[2/7] Installazione dipendenze di sistema su Debian 13..."

start_spinner "[3/7] Installazione di 'uv' e preparazione utente..."
curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh > /dev/null 2>&1
if ! id -u forge > /dev/null 2>&1; then
    useradd -r -m -s /bin/false forge
fi
mkdir -p "$FORGE_DIR"
chown -R forge:forge "$FORGE_DIR" /home/forge
stop_spinner "[3/7] Installazione di 'uv' e preparazione utente..."

start_spinner "[4/7] Clonazione repository Forge..."
su -s /bin/bash forge -c "git clone -q https://github.com/lllyasviel/stable-diffusion-webui-forge.git \"$FORGE_DIR\""
stop_spinner "[4/7] Clonazione repository Forge..."

start_spinner "[5/7] Creazione venv e download dei requisiti Forge (può richiedere minuti)..."
su -s /bin/bash forge -c "cd $FORGE_DIR && uv venv --python 3.10.14 venv > /dev/null 2>&1"
su -s /bin/bash forge -c "$FORGE_DIR/venv/bin/python -m ensurepip --upgrade > /dev/null 2>&1"
su -s /bin/bash forge -c "$FORGE_DIR/venv/bin/python -m pip install --disable-pip-version-check --upgrade pip -q"
su -s /bin/bash forge -c "$FORGE_DIR/venv/bin/python -m pip install --disable-pip-version-check -q 'setuptools<70' wheel"
su -s /bin/bash forge -c "cd $FORGE_DIR && venv/bin/pip install --disable-pip-version-check -q -r requirements_versions.txt"
stop_spinner "[5/7] Creazione venv e download dei requisiti Forge..."

start_spinner "[5.5/7] Applicazione fix definitivo (NumPy, Triton e Joblib)..."
su -s /bin/bash forge -c "$FORGE_DIR/venv/bin/python -m pip uninstall --disable-pip-version-check -y numpy opencv-python"
su -s /bin/bash forge -c "$FORGE_DIR/venv/bin/python -m pip install --disable-pip-version-check -q 'numpy==1.26.4' 'opencv-python-headless' triton joblib"
stop_spinner "[5.5/7] Applicazione fix definitivo (NumPy, Triton e Joblib)..."

start_spinner "[6/7] Download Modelli (~20GB totali). L'operazione richiederà diversi minuti..."
# Usiamo i mirror stabili di HuggingFace. L'uso dei prefissi 01, 02 e 03 imposta Juggernaut come modello di default 
su -s /bin/bash forge -c "curl -L -s -o \"$MODELS_DIR/01-Juggernaut-XL-v9.safetensors\" \"https://huggingface.co/RunDiffusion/Juggernaut-XL-v9/resolve/main/Juggernaut-XL_v9_RunDiffusion.safetensors\""
su -s /bin/bash forge -c "curl -L -s -o \"$MODELS_DIR/02-RealVisXL-Lightning.safetensors\" \"https://huggingface.co/SG161222/RealVisXL_V4.0_Lightning/resolve/main/RealVisXL_V4.0_Lightning.safetensors\""
su -s /bin/bash forge -c "curl -L -s -o \"$MODELS_DIR/03-Animagine-XL-3.1.safetensors\" \"https://huggingface.co/cagliostrolab/animagine-xl-3.1/resolve/main/animagine-xl-3.1.safetensors\""
stop_spinner "[6/7] Download Modelli SDXL (Juggernaut, RealVisXL, Animagine)..."

start_spinner "[7/7] Configurazione systemd e abilitazione servizio..."
cat << EOF > "$SERVICE_FILE"
[Unit]
Description=Stable Diffusion WebUI Forge (Homelab AI)
After=network.target
[Service]
Type=simple
User=forge
WorkingDirectory=$FORGE_DIR
Environment="PYTHON=$FORGE_DIR/venv/bin/python"
Environment="PIP_NO_BUILD_ISOLATION=1"
ExecStart=/bin/bash $FORGE_DIR/webui.sh --api --listen --port 7860 --skip-install
Restart=on-failure
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now homelab-ai-forge > /dev/null 2>&1
stop_spinner "[7/7] Configurazione systemd e abilitazione servizio..."

echo ""
echo "------------------------------------------------------------------------"
echo -e "\033[33mATTENZIONE: Forge si sta avviando con l'ambiente blindato.\033[0m"
echo "Visualizzazione dei log in tempo reale (premi Ctrl+C per uscire dal log)..."
echo "------------------------------------------------------------------------"
journalctl -u homelab-ai-forge -f -n 20 &
LOG_PID=$!
TIMEOUT=1800
ELAPSED=0
SLEEP_INTERVAL=5

while true; do
    if systemctl is-failed --quiet homelab-ai-forge; then
        echo -e "\n\n\033[31m[ERRORE CRITICO] Il servizio homelab-ai-forge è andato in crash!\033[0m"
        exit 1
    fi
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL" || true)
    if [ "$HTTP_STATUS" -eq 200 ] || [ "$HTTP_STATUS" -eq 404 ]; then
        echo -e "\n\n\033[32m[SUCCESSO] Forge è pienamente operativo e l'API è in ascolto!\033[0m"
        break
    fi
    sleep $SLEEP_INTERVAL
    ELAPSED=$((ELAPSED + SLEEP_INTERVAL))
    if [ $ELAPSED -gt $TIMEOUT ]; then
        echo -e "\n\n\033[31m[TIMEOUT] Sono passati 30 minuti e l'API non è ancora pronta.\033[0m"
        exit 1
    fi
done

# Uccidiamo il log follower per stampare il footer pulito
kill "$LOG_PID" 2>/dev/null || true
LOG_PID=""
MACHINE_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "========================================================================"
echo -e "\033[32mInstallazione Completata e Validata con successo!\033[0m"
echo "Interfaccia Web ed endpoint API disponibili agli indirizzi:"
echo -e " - Locale: \033[36mhttp://127.0.0.1:7860\033[0m"
if [ -n "$MACHINE_IP" ]; then
    echo -e " - Rete:   \033[36mhttp://${MACHINE_IP}:7860\033[0m"
fi
echo "========================================================================"
