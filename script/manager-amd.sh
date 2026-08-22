#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Manager Script (AMD - Ubuntu/Debian Stable Stack)
# Repo: mrpink77it/homelab-ai-deployer
# Version: V.2.0.0 (Full Featured + Advanced Services)
# ==============================================================================

set -euo pipefail

trap 'echo -e "\n\033[1;31m[ERRORE FATALE] Lo script manager-amd.sh si è interrotto alla riga $LINENO. Verifica di averlo avviato con privilegi elevati (sudo).\033[0m\n"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

VERSION="2.0.0"
LOG_FILE="/var/log/homelab-ai-amd.log"
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
    log_info "Verifica pacchetti base di sistema..."
    apt-get update || true
    apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" \
        build-essential cmake git curl wget pkg-config pciutils gnupg zstd ffmpeg \
        libvulkan-dev vulkan-tools python3 python3-pip python3-venv python3-dev whiptail \
        libffi-dev libssl-dev libomp-dev || true
    
    apt-get remove --purge -y hipcc rocminfo "rocm-*" "libhip*" "libamdhip*" >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true
}

get_amd_gpu_profile() {
    local gpu_info
    gpu_info=$(lspci | grep -iE 'vga|3d|display' | grep -i amd || true)
    local target="gfx1030" 
    local override=""

    if echo "$gpu_info" | grep -qiE 'navi 10|5700|5600'; then
        target="gfx1030"
        override="10.3.0"
    elif echo "$gpu_info" | grep -qiE 'navi 2|6700|6800|6900|6500'; then
        target="gfx1030"
    elif echo "$gpu_info" | grep -qiE 'navi 3|7900|7800|7600'; then
        target="gfx1100"
    elif echo "$gpu_info" | grep -qiE 'vega|radeon vii'; then
        target="gfx900,gfx906"
    elif echo "$gpu_info" | grep -qiE 'polaris|rx 580|rx 570|rx 480'; then
        target="gfx803"
        override="8.0.3"
    fi
    echo "${target}|${override}"
}

ensure_hipcc_toolchain() {
    local HIPCC_BIN="/opt/rocm/bin/hipcc"
    if [[ ! -x "$HIPCC_BIN" ]]; then
        mkdir -p /etc/apt/keyrings
        wget -q -O - https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/rocm.gpg
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/6.2 noble main" > /etc/apt/sources.list.d/rocm.list
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/amdgpu/6.2/ubuntu noble main" > /etc/apt/sources.list.d/amdgpu.list
        apt-get update || true
        apt-get install -y rocm-dev rocm-hip-sdk || true
    fi
    return 0
}

compile_llama() {
    local type="$1"
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    
    if [[ ! -d "${LLAMA_DIR}" ]]; then
        git clone https://github.com/ggerganov/llama.cpp.git "${LLAMA_DIR}"
    else
        git -C "${LLAMA_DIR}" pull
    fi

    if [[ -f "${LLAMA_DIR}/ggml/src/ggml-cuda/vendors/hip.h" ]]; then
        sed -i 's/typedef __hip_fp8_e4m3 __nv_fp8_e4m3;/typedef uint8_t __nv_fp8_e4m3;/g' "${LLAMA_DIR}/ggml/src/ggml-cuda/vendors/hip.h" || true
        sed -i 's/typedef __hip_fp8_e5m2 __nv_fp8_e5m2;/typedef uint8_t __nv_fp8_e5m2;/g' "${LLAMA_DIR}/ggml/src/ggml-cuda/vendors/hip.h" || true
    fi

    rm -rf "${LLAMA_DIR}/build"
    local gpu_profile target override
    gpu_profile=$(get_amd_gpu_profile)
    target=$(echo "$gpu_profile" | cut -d'|' -f1)
    override=$(echo "$gpu_profile" | cut -d'|' -f2)

    case "${type}" in
        "vulkan")
            cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" -DGGML_VULKAN=ON
            cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
            ;;
        "rocm"|"rocm_exp")
            ensure_hipcc_toolchain
            local ROCM_PREFIX="/opt/rocm"
            export PATH="${ROCM_PREFIX}/bin:${ROCM_PREFIX}/llvm/bin:${PATH}"
            if [[ "${type}" == "rocm_exp" && -n "${override}" ]]; then
                export HSA_OVERRIDE_GFX_VERSION="${override}"
            fi
            cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" -DGGML_HIP=ON -DAMDGPU_TARGETS=${target} -DROCM_PATH=${ROCM_PREFIX}
            cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
            ;;
    esac

    auto_setup_systemd_service "${type}" "${override}"
}

auto_setup_systemd_service() {
    source "$PORT_CONFIG"
    local type="$1"
    local override="$2"
    local host="0.0.0.0"
    local port="$LLAMACPP_PORT"
    local model_path="${MODELS_DIR}/model.gguf"

    local env_directives=""
    if [[ "${type}" == "rocm" || "${type}" == "rocm_exp" ]]; then
        env_directives="Environment=\"PATH=/opt/rocm/bin:/opt/rocm/llvm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\""
        env_directives+=$'\n'
        env_directives+="Environment=\"LD_LIBRARY_PATH=/opt/rocm/lib:/opt/rocm/lib64\""
        if [[ -n "${override}" ]]; then
            env_directives+=$'\n'
            env_directives+="Environment=\"HSA_OVERRIDE_GFX_VERSION=${override}\""
        fi
    fi

    cat <<EOF > "${SERVICE_FILE}"
[Unit]
Description=Homelab AI Backend Service (llama.cpp AMD)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
${env_directives}
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
}

install_open_webui() {
    source "$PORT_CONFIG"
    mkdir -p "${WEBUI_DIR}"
    if ! command -v uv &> /dev/null; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi
    export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
    
    if [[ ! -d "${WEBUI_DIR}/venv" ]]; then
        uv venv -p 3.11 "${WEBUI_DIR}/venv"
    fi
    
    source "${WEBUI_DIR}/venv/bin/activate"
    uv pip install --upgrade pip
    uv pip install open-webui
    deactivate

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
    whiptail --title "Successo" --msgbox "Open WebUI installato sulla porta $OPENWEBUI_PORT!" 10 60
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

        PORT_CHOICE=$(whiptail --title "Gestione Porte & Stato Servizi AMD" \
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
    local GPU=$(lspci | grep -iE 'vga|3d|display' | grep -i amd | head -n 1)
    whiptail --title "Dashboard AMD" --msgbox "IP: $IP\nGPU: $GPU\nPorta Backend: $LLAMACPP_PORT\nPorta WebUI: $OPENWEBUI_PORT" 15 70
}

manage_models() {
    while true; do
        MODEL_CHOICE=$(whiptail --title "Gestione Modelli GGUF (AMD)" \
            --menu "Scegli l'operazione:" 15 75 3 \
            "ACTIVATE_GGUF" "Attiva GGUF su llama.cpp" \
            "DOWNLOAD_GGUF" "Scarica GGUF da HuggingFace" \
            "BACK" "Torna indietro" 3>&1 1>&2 2>&3)
        if [ $? -ne 0 ]; then break; fi
        case "$MODEL_CHOICE" in
            "ACTIVATE_GGUF")
                mkdir -p "$MODELS_DIR"
                GGUF_LIST=()
                while IFS= read -r file; do
                    GGUF_LIST+=("$(basename "$file")" "file")
                done < <(find "$MODELS_DIR" -maxdepth 1 -name "*.gguf")
                if [ ${#GGUF_LIST[@]} -gt 0 ]; then
                    SEL=$(whiptail --title "Modelli" --menu "Seleziona:" 15 60 4 "${GGUF_LIST[@]}" 3>&1 1>&2 2>&3)
                    if [ $? -eq 0 ] && [ -n "$SEL" ]; then
                        ln -sf "${MODELS_DIR}/$SEL" "${MODELS_DIR}/model.gguf"
                        systemctl restart "${SERVICE_NAME}" 2>/dev/null || true
                    fi
                else
                    whiptail --title "Info" --msgbox "Nessun modello trovato in $MODELS_DIR" 8 40
                fi
                ;;
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
    local action=$(whiptail --title "Gestione Servizi" \
        --menu "Seleziona azione:" 15 70 4 \
        "1" "Avvia Servizi" \
        "2" "Ferma Servizi" \
        "3" "Riavvia Servizi" \
        "4" "Indietro" 3>&1 1>&2 2>&3)
    case "$action" in
        1) systemctl start "${SERVICE_NAME}" homelab-ai-frontend 2>/dev/null || true ;;
        2) systemctl stop "${SERVICE_NAME}" homelab-ai-frontend 2>/dev/null || true ;;
        3) systemctl restart "${SERVICE_NAME}" homelab-ai-frontend 2>/dev/null || true ;;
    esac
}

select_backend() {
    local choice=$(whiptail --title "Backend AMD" \
        --menu "Scegli il backend:" 15 70 3 \
        "1" "Vulkan (Raccomandato)" \
        "2" "ROCm Sperimentale" \
        "3" "ROCm Ufficiale" 3>&1 1>&2 2>&3)
    case "$choice" in
        1) compile_llama "vulkan" ;;
        2) compile_llama "rocm_exp" ;;
        3) compile_llama "rocm" ;;
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
        exec "${SCRIPT_DIR}/manager-amd.sh"
    fi
}

main_menu() {
    while true; do
        choice=$(whiptail --title "Homelab AI - AMD Management Console (v${VERSION})" \
            --menu "Ambiente: $(detect_environment)\nScegli un'operazione:" 22 80 12 \
            "A" "Express Auto-Deploy (Tutto in un click - Vulkan)" \
            "1" "Seleziona/Compila Backend Llama.cpp (3 Architetture)" \
            "2" "Installa / Configura Open WebUI (Frontend)" \
            "3" "Scarica / Gestisci Modelli GGUF" \
            "4" "Gestione Servizi Avanzati (OCR, Audio, Web Search, OpenClaw, Unsloth)" \
            "5" "Gestione Servizi di Sistema (Avvia/Ferma/Riavvia)" \
            "6" "Gestione Porte & Stato Servizi Attivi" \
            "7" "Mostra Dashboard di Sistema (Banner)" \
            "8" "Visualizza Log di Sistema" \
            "9" "Aggiorna Repository (Manager e Script)" \
            "0" "Disinstalla Stack Homelab AI" \
            3>&1 1>&2 2>&3)

        if [ $? -ne 0 ]; then return_to_main; fi

        case "$choice" in
            "A") install_dependencies; compile_llama "vulkan"; install_open_webui ;;
            "1") select_backend; read -rp "Invio..." ;;
            "2") install_open_webui ;;
            "3") manage_models ;;
            "4") deploy_advanced_services_menu ;;
            "5") manage_service_menu ;;
            "6") manage_ports ;;
            "7") show_dashboard_banner; read -rp "Invio..." ;;
            "8") clear; tail -n 50 "${LOG_FILE}" || true; read -rp "Invio..." ;;
            "9") update_repo ;;
            "0") run_uninstall ;;
            *) return_to_main ;;
        esac
    done
}

check_root
init_env
install_dependencies
main_menu
