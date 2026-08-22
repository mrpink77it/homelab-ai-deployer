#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Manager Script (NVIDIA - Ubuntu/Debian Stable Stack)
# Repo: mrpink77it/homelab-ai-deployer
# Version: V.2.0.2 (Full Featured + Advanced Services + Fix UV Absolute Venv)
# ==============================================================================

set -euo pipefail

trap 'echo -e "\n\033[1;31m[ERRORE FATALE] Lo script manager-nvidia.sh si è interrotto alla riga $LINENO. Verifica di averlo avviato con privilegi elevati (sudo).\033[0m\n"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

VERSION="2.0.2"
LOG_FILE="/var/log/homelab-ai-nvidia.log"
INSTALL_DIR="/opt/homelab-ai"
LLAMA_DIR="${INSTALL_DIR}/llama.cpp"
MODELS_DIR="${INSTALL_DIR}/models"
WEBUI_DIR="${INSTALL_DIR}/open-webui"
UNSLOTH_ENV="/root/unsloth_env"

SERVICE_NAME="homelab-ai-backend"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
FRONTEND_SERVICE_FILE="/etc/systemd/system/homelab-ai-frontend.service"

PORT_CONFIG="/etc/homelab-ai/ports.conf"
mkdir -p /etc/homelab-ai

if [ ! -f "$PORT_CONFIG" ]; then
    cat <<EOF > "$PORT_CONFIG"
LLAMACPP_PORT=8080
OPENWEBUI_PORT=3000
EOF
fi
source "$PORT_CONFIG"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    local level="$1"
    local msg="$2"
    if touch "${LOG_FILE}" 2>/dev/null; then
        echo -e "$(date "+%Y-%m-%d %H:%M:%S") [${level}] ${msg}" | tee -a "${LOG_FILE}"
    else
        echo -e "$(date "+%Y-%m-%d %H:%M:%S") [${level}] ${msg}"
    fi
}

log_info() { log "INFO" "${GREEN}$1${NC}"; }
log_warn() { log "WARN" "${YELLOW}$1${NC}"; }
log_err()  { log "ERROR" "${RED}$1${NC}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "Lo script richiede i privilegi di root. Avvialo con sudo."
        exit 1
    fi
}

detect_environment() {
    if [[ -f /proc/1/environ ]] && grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
        echo "LXC (Proxmox)"
    else
        echo "Bare-Metal / Standard VM"
    fi
}

init_env() {
    mkdir -p "$(dirname "$LOG_FILE")" "${MODELS_DIR}" "${WEBUI_DIR}"
    touch "${LOG_FILE}" || true
}

return_to_main() {
    clear
    echo -e "${GREEN}Ritorno al menu principale...${NC}"
    sleep 1
    if [ -f "./main.sh" ]; then exec ./main.sh
    elif [ -f "../main.sh" ]; then cd .. && exec ./main.sh
    else exit 0; fi
}

install_dependencies() {
    export DEBIAN_FRONTEND=noninteractive
    log_info "Aggiornamento e installazione dipendenze di sistema NVIDIA..."
    apt-get update -qq
    apt-get install -y curl wget git build-essential cmake zstd ffmpeg python3-pip python3-dev pciutils whiptail -qq
}

compile_llama_cuda() {
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    log_info "Clonazione e compilazione di llama.cpp con supporto CUDA..."
    mkdir -p "${LLAMA_DIR}"
    
    if [ -d "${LLAMA_DIR}/.git" ]; then
        git -C "${LLAMA_DIR}" pull
    else
        git clone https://github.com/ggerganov/llama.cpp.git "${LLAMA_DIR}"
    fi
    
    cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" -DGGML_CUDA=ON
    cmake --build "${LLAMA_DIR}/build" --config Release -j$(nproc)
    
    local host="0.0.0.0"
    local port="$LLAMACPP_PORT"
    local model_path="${MODELS_DIR}/model.gguf"

    cat <<EOF > "${SERVICE_FILE}"
[Unit]
Description=Homelab AI Backend Service (llama.cpp CUDA)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${LLAMA_DIR}/build/bin/llama-server --host ${host} --port ${port} -m "${model_path}" -ngl 99
Restart=always
RestartSec=5
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"
    systemctl restart "${SERVICE_NAME}" || true
    log_info "llama.cpp compilato e servizio avviato sulla porta $port."
}

install_open_webui() {
    source "$PORT_CONFIG"
    log_info "Installazione di Ollama e Open WebUI..."
    if ! command -v zstd &> /dev/null; then apt-get install -y zstd -qq; fi
    if ! command -v ollama &> /dev/null; then curl -fsSL https://ollama.com/install.sh | sh; fi
    if ! command -v uv &> /dev/null; then curl -LsSf https://astral.sh/uv/install.sh | sh; fi

    local UV_BIN="$HOME/.local/bin/uv"
    [ ! -f "$UV_BIN" ] && UV_BIN="/root/.local/bin/uv"

    mkdir -p "$WEBUI_DIR"
    cd "$WEBUI_DIR"

    log_info "Creazione ambiente virtuale venv assoluto in ${WEBUI_DIR}/venv..."
    "$UV_BIN" venv "${WEBUI_DIR}/venv" --python 3.12 --seed --allow-existing

    log_info "Installazione Open WebUI tramite uv pip con percorso assoluto..."
    "${WEBUI_DIR}/venv/bin/python" -m pip install --upgrade pip
    "$UV_BIN" pip install open-webui --python "${WEBUI_DIR}/venv/bin/python"

    cat <<EOF > "${FRONTEND_SERVICE_FILE}"
[Unit]
Description=Homelab AI Frontend Service (Open WebUI)
After=network.target ${SERVICE_NAME}.service

[Service]
Type=simple
User=root
WorkingDirectory=${WEBUI_DIR}
Environment="HOST=0.0.0.0"
Environment="PORT=$OPENWEBUI_PORT"
Environment="WEBUI_PORT=$OPENWEBUI_PORT"
Environment="OPENAI_API_BASE_URL=http://127.0.0.1:$LLAMACPP_PORT/v1"
ExecStart=${WEBUI_DIR}/venv/bin/open-webui serve
Restart=always
RestartSec=5
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable homelab-ai-frontend
    systemctl restart homelab-ai-frontend
    log_info "Open WebUI configurato e avviato sulla porta $OPENWEBUI_PORT."
    whiptail --title "Successo" --msgbox "Ollama e Open WebUI installati correttamente!" 10 60
}

deploy_advanced_services_menu() {
    while true; do
        ADV_CHOICE=$(whiptail --title "Homelab AI - Servizi Avanzati & Moduli" \
            --menu "Seleziona il modulo avanzato da configurare:" 18 75 6 \
            "1" "Configura Modelli Vision & OCR (Qwen2-VL / MiniCPM-V)" \
            "2" "Configura Whisper (Speech-to-Text & Audio Intelligence)" \
            "3" "Configura SearXNG (Web Search & RAG avanzato)" \
            "4" "Installa Agente Locale OpenClaw (Automazione Telegram)" \
            "5" "Configura Ambiente Vibe Coding & Unsloth / Jupyter Lab" \
            "6" "Torna al Menu Principale" \
            3>&1 1>&2 2>&3)
            
        if [ $? -ne 0 ]; then break; fi

        case $ADV_CHOICE in
            1)
                clear
                echo -e "${GREEN}Scaricamento modelli Ollama per OCR e Vision...${NC}"
                if command -v ollama &> /dev/null; then
                    ollama pull qwen2-vl:7b || true
                    ollama pull llama3.2-vision || true
                fi
                read -rp "Premi INVIO per continuare..."
                ;;
            2)
                clear
                echo -e "${GREEN}Installazione dipendenze Whisper per Audio Processing...${NC}"
                local UV_BIN="$HOME/.local/bin/uv"
                [ ! -f "$UV_BIN" ] && UV_BIN="/root/.local/bin/uv"
                if command -v "$UV_BIN" &> /dev/null; then
                    "$UV_BIN" pip install openai-whisper soundfile
                else
                    pip3 install openai-whisper soundfile
                fi
                read -rp "Premi INVIO per continuare..."
                ;;
            3)
                whiptail --title "SearXNG & RAG" --msgbox "Assicurati di impostare le variabili d'ambiente di SearXNG nel pannello di Open WebUI." 10 65
                ;;
            4)
                whiptail --title "OpenClaw" --msgbox "Preparazione installazione OpenClaw (Agente autonomo in configurazione)..." 10 65
                ;;
            5)
                clear
                echo -e "${GREEN}Configurazione ambiente Unsloth & Jupyter Lab...${NC}"
                if [ ! -d "$UNSLOTH_ENV" ]; then python3 -m venv "$UNSLOTH_ENV"; fi
                "$UNSLOTH_ENV/bin/pip" install --upgrade pip wheel "setuptools<82"
                "$UNSLOTH_ENV/bin/pip" install -U jupyterlab unsloth unsloth-zoo trl xformers
                read -rp "Premi INVIO per continuare..."
                ;;
            6)
                break
                ;;
        esac
    done
}

manage_ports() {
    while true; do
        source "$PORT_CONFIG"
        local s_llama="CHIUSA"
        ss -tulpn | grep -q ":$LLAMACPP_PORT " && s_llama="ATTIVO"
        local s_webui="CHIUSA"
        ss -tulpn | grep -q ":$OPENWEBUI_PORT " && s_webui="ATTIVO"

        PORT_CHOICE=$(whiptail --title "Gestione Porte & Stato Servizi NVIDIA" \
            --menu "Porte configurate:\n 1. llama.cpp : $LLAMACPP_PORT [$s_llama]\n 2. WebUI : $OPENWEBUI_PORT [$s_webui]" 16 70 3 \
            "CHANGE" "Modifica una porta" \
            "RESTART" "Riavvia i servizi" \
            "BACK" "Torna indietro" 3>&1 1>&2 2>&3)
        if [ $? -ne 0 ]; then break; fi
        case $PORT_CHOICE in
            "CHANGE")
                T_SRV=$(whiptail --title "Servizio" --menu "Seleziona:" 10 50 2 "LLAMACPP_PORT" "llama.cpp" "OPENWEBUI_PORT" "WebUI" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$T_SRV" ]; then
                    N_P=$(whiptail --title "Nuova Porta" --inputbox "Inserisci porta:" 8 40 3>&1 1>&2 2>&3)
                    if [ $? -eq 0 ] && [ -n "$N_P" ]; then
                        sed -i "s/^${T_SRV}=.*/${T_SRV}=${N_P}/" "$PORT_CONFIG"
                    fi
                fi
                ;;
            "RESTART")
                systemctl restart "${SERVICE_NAME}" homelab-ai-frontend 2>/dev/null || true
                ;;
            "BACK") break ;;
        esac
    done
}

show_dashboard_banner() {
    source "$PORT_CONFIG"
    local IP=$(hostname -I | awk '{print $1}')
    local GPU=$(lspci | grep -iE 'vga|3d|display' | grep -i nvidia | head -n 1)
    whiptail --title "Dashboard NVIDIA" --msgbox "IP: $IP\nGPU: $GPU\nPorta Backend: $LLAMACPP_PORT\nPorta WebUI: $OPENWEBUI_PORT" 15 70
}

manage_models() {
    while true; do
        M_CHOICE=$(whiptail --title "Gestione Modelli GGUF" --menu "Seleziona:" 12 60 2 \
            "DOWNLOAD_GGUF" "Scarica GGUF da HuggingFace" \
            "BACK" "Torna indietro" 3>&1 1>&2 2>&3)
        if [ $? -ne 0 ]; then break; fi
        case "$M_CHOICE" in
            "DOWNLOAD_GGUF")
                URL=$(whiptail --title "URL" --inputbox "URL GGUF:" 8 60 "https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$URL" ]; then
                    mkdir -p "$MODELS_DIR" && cd "$MODELS_DIR" && wget -c "$URL"
                fi
                ;;
            "BACK") break ;;
        esac
    done
}

manage_service_menu() {
    local act=$(whiptail --title "Servizi" --menu "Azione:" 12 50 3 \
        "1" "Avvia Servizi" "2" "Ferma Servizi" "3" "Riavvia Servizi" 3>&1 1>&2 2>&3)
    case "$act" in
        1) systemctl start "${SERVICE_NAME}" homelab-ai-frontend 2>/dev/null || true ;;
        2) systemctl stop "${SERVICE_NAME}" homelab-ai-frontend 2>/dev/null || true ;;
        3) systemctl restart "${SERVICE_NAME}" homelab-ai-frontend 2>/dev/null || true ;;
    esac
}

run_uninstall() {
    if (whiptail --title "Disinstalla" --yesno "Vuoi rimuovere i servizi?" 10 50); then
        systemctl stop "${SERVICE_NAME}" homelab-ai-frontend 2>/dev/null || true
        rm -f "${SERVICE_FILE}" "${FRONTEND_SERVICE_FILE}"
        systemctl daemon-reload
    fi
}

update_repo() {
    if [[ -d "${REPO_ROOT}/.git" ]]; then
        git -C "${REPO_ROOT}" pull origin main || true
        exec "${SCRIPT_DIR}/manager-nvidia.sh"
    fi
}

main_menu() {
    while true; do
        choice=$(whiptail --title "Homelab AI - NVIDIA Management Console (v${VERSION})" \
            --menu "Ambiente: $(detect_environment)\nScegli un'operazione:" 22 80 11 \
            "A" "Express Auto-Deploy (Tutto in un click)" \
            "1" "Installa Dipendenze di Sistema" \
            "2" "Installa Ollama & Open WebUI" \
            "3" "Compila llama.cpp (CUDA)" \
            "4" "Gestione Servizi Avanzati (OCR, Audio, Web Search, OpenClaw, Unsloth)" \
            "5" "Gestione Servizi di Sistema (Avvia/Ferma/Riavvia)" \
            "6" "Scarica / Gestisci Modelli GGUF" \
            "7" "Gestione Porte & Stato Servizi Attivi" \
            "8" "Mostra Dashboard di Sistema" \
            "9" "Visualizza Log di Sistema" \
            "10" "Aggiorna Repository" \
            "0" "Disinstalla Stack" \
            3>&1 1>&2 2>&3)

        if [ $? -ne 0 ]; then return_to_main; fi

        case "$choice" in
            "A") install_dependencies; compile_llama_cuda; install_open_webui ;;
            "1") install_dependencies; read -rp "Invio..." ;;
            "2") install_open_webui ;;
            "3") compile_llama_cuda ;;
            "4") deploy_advanced_services_menu ;;
            "5") manage_service_menu ;;
            "6") manage_models ;;
            "7") manage_ports ;;
            "8") show_dashboard_banner; read -rp "Invio..." ;;
            "9") clear; tail -n 50 "${LOG_FILE}" || true; read -rp "Invio..." ;;
            "10") update_repo ;;
            "0") run_uninstall ;;
            *) return_to_main ;;
        esac
    done
}

check_root
init_env
main_menu
