#!/usr/bin/env bash
# ==============================================================================
# Script: manager-amd.sh
# Versione: 1.0.1
# Descrizione: Gestore deployment, frontend, servizi systemd e ciclo AI per GPU AMD
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configurazione Variabili Globali
# ------------------------------------------------------------------------------
VERSION="1.0.1"
INSTALL_DIR="/opt/homelab-ai"
MODELS_DIR="${INSTALL_DIR}/models"
BACKEND_DIR="${INSTALL_DIR}/backend"
FRONTEND_DIR="${INSTALL_DIR}/frontend"
LOG_DIR="/var/log"

# Colori
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_CYAN='\033[1;36m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'

# ------------------------------------------------------------------------------
# Funzioni di Utilità
# ------------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${C_RED}[ERRORE] Questo script richiede i privilegi di root. Usa sudo.${C_RESET}"
        exit 1
    fi
}

setup_directories() {
    echo -e "${C_CYAN}>>> Creazione struttura directory in ${INSTALL_DIR}...${C_RESET}"
    mkdir -p "${MODELS_DIR}" "${BACKEND_DIR}" "${FRONTEND_DIR}"
}

# ------------------------------------------------------------------------------
# Installazione Componenti (Backend e Frontend)
# ------------------------------------------------------------------------------
install_backend() {
    echo -e "${C_CYAN}>>> Installazione Backend (llama.cpp - Ottimizzazione AMD/ROCm)...${C_RESET}"
    
    # Per AMD, scarichiamo l'ultima release precompilata con supporto ROCm da ggerganov/llama.cpp
    # Se fallisce o non c'è, fa fallback sulla versione CPU/Vulkan
    cd "${BACKEND_DIR}"
    
    echo -e "${C_YELLOW}Recupero ultima versione di llama.cpp...${C_RESET}"
    LATEST_RELEASE=$(curl -s https://api.github.com/repos/ggerganov/llama.cpp/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    # URL del binario precompilato (esempio: ubuntu-x64-rocm)
    DOWNLOAD_URL="https://github.com/ggerganov/llama.cpp/releases/download/${LATEST_RELEASE}/llama-${LATEST_RELEASE}-bin-ubuntu-x64-rocm.zip"
    
    if curl --output /dev/null --silent --head --fail "$DOWNLOAD_URL"; then
        echo -e "${C_GREEN}Trovata release ROCm. Download in corso...${C_RESET}"
        wget -q --show-progress -O llama-rocm.zip "$DOWNLOAD_URL"
        apt-get install -y unzip >/dev/null
        unzip -o llama-rocm.zip -d ./ >/dev/null
        rm llama-rocm.zip
        # Rinomina per standardizzazione (il binario estratto varia nome, cerchiamo llama-server)
        find . -name "llama-server" -exec mv {} ./llama-server-amd \;
        chmod +x llama-server-amd
    else
        echo -e "${C_YELLOW}Release ROCm precompilata non trovata. Si raccomanda la compilazione manuale. Verrà scaricata la versione base.${C_RESET}"
        # Fallback alla versione base per continuità script
        DOWNLOAD_URL_BASE="https://github.com/ggerganov/llama.cpp/releases/download/${LATEST_RELEASE}/llama-${LATEST_RELEASE}-bin-ubuntu-x64.zip"
        wget -q --show-progress -O llama-base.zip "$DOWNLOAD_URL_BASE"
        unzip -o llama-base.zip -d ./ >/dev/null
        rm llama-base.zip
        find . -name "llama-server" -exec mv {} ./llama-server-amd \;
        chmod +x llama-server-amd
    fi
    echo -e "${C_GREEN}Backend installato con successo.${C_RESET}"
}

download_model() {
    echo -e "${C_CYAN}>>> Download Modello GGUF (Qwen2.5-Coder-7B-Instruct)...${C_RESET}"
    cd "${MODELS_DIR}"
    MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf"
    MODEL_FILE="qwen2.5-coder-7b-instruct-q4_k_m.gguf"

    if [[ -f "$MODEL_FILE" ]]; then
        echo -e "${C_GREEN}Modello già presente: $MODEL_FILE${C_RESET}"
    else
        wget --show-progress -O "$MODEL_FILE" "$MODEL_URL"
    fi
}

install_frontend() {
    echo -e "${C_CYAN}>>> Installazione Open WebUI (Frontend)...${C_RESET}"
    
    # [FIX 1.0.1] - Esportiamo il PATH unificato per assicurarci che uv veda i comandi di sistema
    export PATH="/root/.cargo/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    
    if ! command -v uv &> /dev/null; then
        echo -e "${C_YELLOW}Installazione gestore rapido 'uv'...${C_RESET}"
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi

    cd "${FRONTEND_DIR}"
    
    echo -e "${C_YELLOW}Creazione ambiente virtuale Python e installazione dipendenze...${C_RESET}"
    uv venv .venv
    
    # Eseguiamo uv pip install puntando esplicitamente al python del venv
    VIRTUAL_ENV="${FRONTEND_DIR}/.venv" uv pip install open-webui
    
    echo -e "${C_GREEN}Frontend Open WebUI installato correttamente.${C_RESET}"
}

# ------------------------------------------------------------------------------
# Configurazione Servizi Systemd
# ------------------------------------------------------------------------------
setup_services() {
    echo -e "${C_CYAN}>>> Configurazione Servizi Systemd...${C_RESET}"
    
    # 1. Backend Service (llama.cpp)
    cat <<EOF > /etc/systemd/system/homelab-ai-backend.service
[Unit]
Description=Homelab AI Backend (llama.cpp - AMD)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${BACKEND_DIR}
# Variabili per abilitare l'accelerazione AMD se disponibile
Environment="HSA_OVERRIDE_GFX_VERSION=10.3.0"
ExecStart=${BACKEND_DIR}/llama-server-amd -m ${MODELS_DIR}/qwen2.5-coder-7b-instruct-q4_k_m.gguf --host 127.0.0.1 --port 8080 -c 4096 -ngl 99
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    # 2. Frontend Service (Open WebUI)
    cat <<EOF > /etc/systemd/system/homelab-ai-frontend.service
[Unit]
Description=Homelab AI Frontend (Open WebUI)
After=network.target homelab-ai-backend.service

[Service]
Type=simple
User=root
WorkingDirectory=${FRONTEND_DIR}
Environment="PATH=/root/.cargo/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="OLLAMA_BASE_URL=http://127.0.0.1:8080"
Environment="WEBUI_AUTH=False"
Environment="HOST=0.0.0.0"
Environment="PORT=3000"
ExecStart=${FRONTEND_DIR}/.venv/bin/open-webui serve
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable homelab-ai-backend homelab-ai-frontend
    systemctl start homelab-ai-backend homelab-ai-frontend

    echo -e "${C_GREEN}Servizi avviati. Open WebUI sarà disponibile su http://<INDIRIZZO_IP>:3000${C_RESET}"
}

# ------------------------------------------------------------------------------
# Menu Principale TUI
# ------------------------------------------------------------------------------
main_menu() {
    if ! command -v whiptail &> /dev/null; then
        apt-get update -qq && apt-get install -y whiptail
    fi

    local choice
    choice=$(whiptail --title "Homelab AI - Controller AMD (v${VERSION})" \
        --menu "\nSeleziona un'operazione per l'ambiente AMD:" 16 70 5 \
        "1" "Esegui Installazione Completa (Backend + Frontend)" \
        "2" "Riavvia Servizi (Applica modifiche)" \
        "3" "Mostra Log Backend (llama.cpp)" \
        "4" "Mostra Log Frontend (Open WebUI)" \
        "5" "Esci al Menu Principale" \
        3>&1 1>&2 2>&3) || exit 0

    case "$choice" in
        1)
            setup_directories
            install_backend
            download_model
            install_frontend
            setup_services
            whiptail --title "Completato" --msgbox "Installazione AMD completata con successo!\nAccedi a Open WebUI sulla porta 3000." 8 60
            main_menu
            ;;
        2)
            systemctl restart homelab-ai-backend homelab-ai-frontend
            whiptail --title "Riavvio" --msgbox "Servizi riavviati." 8 40
            main_menu
            ;;
        3)
            journalctl -u homelab-ai-backend -f
            ;;
        4)
            journalctl -u homelab-ai-frontend -f
            ;;
        5)
            exit 0
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Entrypoint
# ------------------------------------------------------------------------------
check_root
main_menu
