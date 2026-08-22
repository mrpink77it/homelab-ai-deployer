#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Manager Script (NVIDIA - Ubuntu/Debian Stable Stack)
# Repo: mrpink77it/homelab-ai-deployer
# Version: V.2.1.0 (Advanced Service Dashboard & Port Configuration Inspector)
# ==============================================================================

set -euo pipefail

trap 'echo -e "\n\033[1;31m[ERRORE FATALE] Lo script manager-nvidia.sh si è interrotto alla riga $LINENO. Verifica di averlo avviato con privilegi elevati (sudo).\033[0m\n"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

VERSION="2.1.0"
LOG_FILE="/var/log/homelab-ai-nvidia.log"
INSTALL_DIR="/opt/homelab-ai"
LLAMA_DIR="${INSTALL_DIR}/llama.cpp"
MODELS_DIR="${INSTALL_DIR}/models"
WEBUI_DIR="${INSTALL_DIR}/open-webui"
UNSLOTH_ENV="/root/unsloth_env"

SERVICE_NAME="homelab-ai-backend"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
FRONTEND_SERVICE_FILE="/etc/systemd/system/homelab-ai-frontend.service"
JUPYTER_SERVICE_FILE="/etc/systemd/system/homelab-ai-jupyter.service"

PORT_CONFIG="/etc/homelab-ai/ports.conf"
mkdir -p /etc/homelab-ai

if [ ! -f "$PORT_CONFIG" ]; then
    cat <<EOF > "$PORT_CONFIG"
LLAMACPP_PORT=8080
OPENWEBUI_PORT=3000
JUPYTER_PORT=8888
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
    log_info "Configurazione e abilitazione repository non-free (supporto avanzato DEB822 / sources.list)..."
    
    if grep -q "debian" /etc/os-release; then
        for sfile in /etc/apt/sources.list.d/*.sources; do
            if [ -f "$sfile" ]; then
                if grep -q "^Components:" "$sfile"; then
                    for comp in contrib non-free non-free-firmware; do
                        if ! grep -q "$comp" "$sfile"; then
                            sed -i "/^Components:/ s/$/ $comp/" "$sfile"
                        fi
                    done
                fi
            fi
        done
        if [ -f /etc/apt/sources.list ]; then
            sed -i 's/\bmain\b/main contrib non-free non-free-firmware/g' /etc/apt/sources.list || true
        fi
        for lfile in /etc/apt/sources.list.d/*.list; do
            [ -f "$lfile" ] && sed -i 's/\bmain\b/main contrib non-free non-free-firmware/g' "$lfile" || true
        done
    elif grep -q "ubuntu" /etc/os-release; then
        apt-get install -y software-properties-common -qq || true
        add-apt-repository -y restricted universe multiverse || true
    fi

    log_get_update() { apt-get update -qq; }
    log_get_update
    
    if ! apt-cache policy nvidia-cuda-toolkit | grep -q "Candidate: [^ ]"; then
        for sfile in /etc/apt/sources.list.d/*.sources; do
            [ -f "$sfile" ] && sed -i 's/Components: *\(.*\)/Components: \1 contrib non-free non-free-firmware/' "$sfile"
        done
        apt-get update -qq
    fi

    apt-get install -y curl wget git build-essential cmake zstd ffmpeg python3-pip python3-dev pciutils nvidia-cuda-toolkit whiptail -qq
    log_info "Dipendenze di sistema installate con successo."
}

compile_llama_cuda() {
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    log_info "Verifica e configurazione percorsi CUDA..."
    
    if [ -d "/usr/local/cuda" ]; then
        export CUDAToolkit_ROOT="/usr/local/cuda"
        export PATH="$PATH:/usr/local/cuda/bin"
    elif [ -d "/usr" ] && [ -f "/usr/bin/nvcc" ]; then
        export CUDAToolkit_ROOT="/usr"
    fi

    if ! command -v nvcc &> /dev/null && [ ! -f "${CUDAToolkit_ROOT}/bin/nvcc" ]; then
        log_err "Compilatore nvcc (CUDA Toolkit) non trovato!"
        whiptail --title "Errore CUDA" --msgbox "Toolkit CUDA non rilevato nel sistema. Assicurati che i repository non-free siano attivi." 10 60
        return 1
    fi

    log_info "Clonazione e compilazione di llama.cpp con supporto CUDA..."
    mkdir -p "${LLAMA_DIR}"
    
    if [ -d "${LLAMA_DIR}/.git" ]; then
        git -C "${LLAMA_DIR}" pull
    else
        git clone https://github.com/ggerganov/llama.cpp.git "${LLAMA_DIR}"
    fi
    
    cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" \
        -DGGML_CUDA=ON \
        -DGGML_BUILD_TESTS=OFF \
        -DGGML_NO_LLAMA_UI=ON \
        -DCUDAToolkit_ROOT="${CUDAToolkit_ROOT:-/usr/local/cuda}"

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

    "$UV_BIN" venv "${WEBUI_DIR}/venv" --python 3.12 --seed --allow-existing
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
                echo -e "${GREEN}Installazione dipendenze Whisper...${NC}"
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
                whiptail --title "OpenClaw" --msgbox "Preparazione installazione OpenClaw..." 10 65
                ;;
            5)
                clear
                echo -e "${GREEN}Configurazione ambiente Unsloth & Jupyter Lab...${NC}"
                if [ ! -d "$UNSLOTH_ENV" ]; then python3 -m venv "$UNSLOTH_ENV"; fi
                "$UNSLOTH_ENV/bin/pip" install --upgrade pip wheel "setuptools<82"
                "$UNSLOTH_ENV/bin/pip" install -U jupyterlab unsloth unsloth-zoo trl xformers

                # Creazione servizio systemd per Jupyter
                cat <<EOF > "${JUPYTER_SERVICE_FILE}"
[Unit]
Description=Homelab AI Jupyter Lab Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
Environment="PATH=${UNSLOTH_ENV}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=${UNSLOTH_ENV}/bin/jupyter lab --ip=0.0.0.0 --port=${JUPYTER_PORT:-8888} --no-browser --allow-root --ServerApp.token=''
Restart=always
RestartSec=5
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                systemctl enable homelab-ai-jupyter
                systemctl restart homelab-ai-jupyter
                echo -e "${GREEN}Jupyter Lab configurato e avviato sulla porta ${JUPYTER_PORT:-8888}.${NC}"
                read -rp "Premi INVIO per continuare..."
                ;;
            6)
                break
                ;;
        esac
    done
}

manage_ports_and_bindings() {
    while true; do
        source "$PORT_CONFIG"
        
        SERVICE_TO_EDIT=$(whiptail --title "Gestione Porte & Variazioni Systemd" \
            --menu "Seleziona il servizio di cui configurare porta e variazioni:" 17 75 4 \
            "LLAMACPP_PORT" "llama.cpp Backend (Attuale: $LLAMACPP_PORT)" \
            "OPENWEBUI_PORT" "Open WebUI Frontend (Attuale: $OPENWEBUI_PORT)" \
            "JUPYTER_PORT" "Jupyter Lab / Unsloth (Attuale: ${JUPYTER_PORT:-8888})" \
            "BACK" "Torna al Menu Principale" 3>&1 1>&2 2>&3)
            
        if [ $? -ne 0 ] || [ "$SERVICE_TO_EDIT" = "BACK" ]; then break; fi

        CURRENT_VAL=$(eval echo "\$$SERVICE_TO_EDIT")
        NEW_PORT=$(whiptail --title "Modifica Porta: $SERVICE_TO_EDIT" \
            --inputbox "Inserisci il nuovo numero di porta per $SERVICE_TO_EDIT:" 10 50 "$CURRENT_VAL" 3>&1 1>&2 2>&3)
            
        if [ $? -eq 0 ] && [ -n "$NEW_PORT" ]; then
            # Mostra anteprima delle variazioni sui file di configurazione
            PREVIEW_MSG="Variazioni che verranno applicate:\n\n"
            PREVIEW_MSG+="1. Aggiornamento file centrale: ${PORT_CONFIG}\n   ${SERVICE_TO_EDIT}=${CURRENT_VAL} -> ${NEW_PORT}\n\n"
            
            if [ "$SERVICE_TO_EDIT" = "LLAMACPP_PORT" ]; then
                PREVIEW_MSG+="2. Modifica file di servizio Systemd: ${SERVICE_FILE}\n   Aggiornamento parametro --port ${NEW_PORT}\n"
            elif [ "$SERVICE_TO_EDIT" = "OPENWEBUI_PORT" ]; then
                PREVIEW_MSG+="2. Modifica file di servizio Systemd: ${FRONTEND_SERVICE_FILE}\n   Aggiornamento variabili PORT=${NEW_PORT}, WEBUI_PORT=${NEW_PORT}\n"
            elif [ "$SERVICE_TO_EDIT" = "JUPYTER_PORT" ]; then
                PREVIEW_MSG+="2. Modifica file di servizio Systemd: ${JUPYTER_SERVICE_FILE}\n   Aggiornamento parametro --port=${NEW_PORT}\n"
            fi

            if (whiptail --title "Conferma Variazioni Systemd" --yesno "$PREVIEW_MSG" 16 70); then
                # Salva nel file di configurazione porte
                sed -i "s/^${SERVICE_TO_EDIT}=.*/${SERVICE_TO_EDIT}=${NEW_PORT}/" "$PORT_CONFIG"
                source "$PORT_CONFIG"

                # Applica le modifiche direttamente ai file di servizio corrispondenti
                if [ "$SERVICE_TO_EDIT" = "LLAMACPP_PORT" ] && [ -f "$SERVICE_FILE" ]; then
                    sed -i "s/--port [0-9]*/--port ${NEW_PORT}/" "$SERVICE_FILE"
                    systemctl daemon-reload
                    systemctl restart "${SERVICE_NAME}" 2>/dev/null || true
                elif [ "$SERVICE_TO_EDIT" = "OPENWEBUI_PORT" ] && [ -f "$FRONTEND_SERVICE_FILE" ]; then
                    sed -i "s/Environment=\"PORT=[0-9]*\"/Environment=\"PORT=${NEW_PORT}\"/" "$FRONTEND_SERVICE_FILE"
                    sed -i "s/Environment=\"WEBUI_PORT=[0-9]*\"/Environment=\"WEBUI_PORT=${NEW_PORT}\"/" "$FRONTEND_SERVICE_FILE"
                    systemctl daemon-reload
                    systemctl restart homelab-ai-frontend 2>/dev/null || true
                elif [ "$SERVICE_TO_EDIT" = "JUPYTER_PORT" ] && [ -f "$JUPYTER_SERVICE_FILE" ]; then
                    sed -i "s/--port=[0-9]*/--port=${NEW_PORT}/" "$JUPYTER_SERVICE_FILE"
                    systemctl daemon-reload
                    systemctl restart homelab-ai-jupyter 2>/dev/null || true
                fi
                whiptail --title "Successo" --msgbox "Porta modificata e file di servizio aggiornati con successo!" 10 50
            fi
        fi
    done
}

manage_service_dashboard() {
    while true; do
        source "$PORT_CONFIG"
        local IP=$(hostname -I | awk '{print $1}')
        [ -z "$IP" ] && IP="127.0.0.1"

        # Stato dei servizi
        check_status() {
            systemctl is-active --quiet "$1" && echo "ATTIVO" || echo "FERMO"
        }
        check_enabled() {
            systemctl is-enabled --quiet "$1" && echo "ABILITATO" || echo "DISABILITATO"
        }

        s_back_st=$(check_status "${SERVICE_NAME}")
        s_back_en=$(check_enabled "${SERVICE_NAME}")
        
        s_front_st=$(check_status "homelab-ai-frontend")
        s_front_en=$(check_enabled "homelab-ai-frontend")

        s_jup_st="NON INSTALLATO"
        s_jup_en="-"
        if [ -f "$JUPYTER_SERVICE_FILE" ]; then
            s_jup_st=$(check_status "homelab-ai-jupyter")
            s_jup_en=$(check_enabled "homelab-ai-jupyter")
        fi

        MENU_TEXT="Indirizzo IP di Sistema: $IP\n\n"
        MENU_TEXT+="[1] llama.cpp Backend\n    Stato: $s_back_st ($s_back_en) | URL: http://$IP:$LLAMACPP_PORT\n\n"
        MENU_TEXT+="[2] Open WebUI Frontend\n    Stato: $s_front_st ($s_front_en) | URL: http://$IP:$OPENWEBUI_PORT\n\n"
        if [ -f "$JUPYTER_SERVICE_FILE" ]; then
            MENU_TEXT+="[3] Jupyter Lab / Unsloth\n    Stato: $s_jup_st ($s_jup_en) | URL: http://$IP:${JUPYTER_PORT:-8888}\n\n"
        else
            MENU_TEXT+="[3] Jupyter Lab / Unsloth (Non installato)\n\n"
        fi
        MENU_TEXT+="Seleziona un servizio da gestire (Avvia, Ferma, Abilita/Disabilita):"

        SRV_CHOICE=$(whiptail --title "Dashboard & Controllo Servizi di Sistema" \
            --menu "$MENU_TEXT" 21 78 5 \
            "1" "Gestisci llama.cpp Backend" \
            "2" "Gestisci Open WebUI Frontend" \
            "3" "Gestisci Jupyter Lab / Unsloth" \
            "ALL_RESTART" "Riavvia tutti i servizi attivi" \
            "BACK" "Torna al Menu Principale" 3>&1 1>&2 2>&3)

        if [ $? -ne 0 ] || [ "$SRV_CHOICE" = "BACK" ]; then break; fi

        if [ "$SRV_CHOICE" = "ALL_RESTART" ]; then
            systemctl restart "${SERVICE_NAME}" homelab-ai-frontend 2>/dev/null || true
            [ -f "$JUPYTER_SERVICE_FILE" ] && systemctl restart homelab-ai-jupyter 2>/dev/null || true
            whiptail --title "Completato" --msgbox "Tutti i servizi installati sono stati riavviati." 8 50
            continue
        fi

        TARGET_SERVICE=""
        TARGET_NAME=""
        if [ "$SRV_CHOICE" = "1" ]; then
            TARGET_SERVICE="${SERVICE_NAME}"
            TARGET_NAME="llama.cpp Backend"
        elif [ "$SRV_CHOICE" = "2" ]; then
            TARGET_SERVICE="homelab-ai-frontend"
            TARGET_NAME="Open WebUI Frontend"
        elif [ "$SRV_CHOICE" = "3" ]; then
            if [ ! -f "$JUPYTER_SERVICE_FILE" ]; then
                whiptail --title "Avviso" --msgbox "Il servizio Jupyter Lab non è installato. Configuralo dal menu dei servizi avanzati." 10 60
                continue
            fi
            TARGET_SERVICE="homelab-ai-jupyter"
            TARGET_NAME="Jupyter Lab"
        fi

        if [ -n "$TARGET_SERVICE" ]; then
            ACTION=$(whiptail --title "Controllo: $TARGET_NAME" \
                --menu "Seleziona l'azione da eseguire sul servizio:" 13 60 4 \
                "START" "Avvia il servizio" \
                "STOP" "Ferma il servizio" \
                "RESTART" "Riavvia il servizio" \
                "TOGGLE_ENABLE" "Abilita/Disabilita avvio automatico (Boot)" 3>&1 1>&2 2>&3)
                
            if [ $? -eq 0 ]; then
                case "$ACTION" in
                    "START") systemctl start "$TARGET_SERVICE" ;;
                    "STOP") systemctl stop "$TARGET_SERVICE" ;;
                    "RESTART") systemctl restart "$TARGET_SERVICE" ;;
                    "TOGGLE_ENABLE")
                        if systemctl is-enabled --quiet "$TARGET_SERVICE"; then
                            systemctl disable "$TARGET_SERVICE"
                            whiptail --title "Systemd" --msgbox "Avvio automatico disabilitato per $TARGET_NAME." 8 50
                        else
                            systemctl enable "$TARGET_SERVICE"
                            whiptail --title "Systemd" --msgbox "Avvio automatico abilitato per $TARGET_NAME." 8 50
                        fi
                        ;;
                esac
            fi
        fi
    done
}

show_dashboard_banner() {
    source "$PORT_CONFIG"
    local IP=$(hostname -I | awk '{print $1}')
    [ -z "$IP" ] && IP="127.0.0.1"
    local GPU=$(lspci | grep -iE 'vga|3d|display' | grep -i nvidia | head -n 1)
    whiptail --title "Dashboard NVIDIA" --msgbox "IP: $IP\nGPU: $GPU\n\nURL Backend: http://$IP:$LLAMACPP_PORT\nURL WebUI: http://$IP:$OPENWEBUI_PORT" 16 75
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

run_uninstall() {
    if (whiptail --title "Disinstalla" --yesno "Vuoi rimuovere i servizi?" 10 50); then
        systemctl stop "${SERVICE_NAME}" homelab-ai-frontend homelab-ai-jupyter 2>/dev/null || true
        rm -f "${SERVICE_FILE}" "${FRONTEND_SERVICE_FILE}" "${JUPYTER_SERVICE_FILE}"
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
            "5" "Gestione & Controllo Servizi Attivi (Stato, IP, HTTP, Avvio/Ferma)" \
            "6" "Scarica / Gestisci Modelli GGUF" \
            "7" "Configurazione Avanzata Porte & Variazioni Systemd" \
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
            "5") manage_service_dashboard ;;
            "6") manage_models ;;
            "7") manage_ports_and_bindings ;;
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
