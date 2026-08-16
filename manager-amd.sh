#!/usr/bin/env bash
# ==============================================================================
# Script: manager-amd.sh
# Descrizione: Gestore deployment, frontend, servizi systemd e ciclo AI per GPU AMD
# Ambienti: Bare-Metal & Proxmox LXC (Debian 13 / Ubuntu 24.04 LTS)
# ==============================================================================

set -euo pipefail

trap 'echo -e "\n\033[1;31m[ERRORE FATALE] Lo script manager-amd.sh si è interrotto alla riga $LINENO. Verifica di averlo avviato con privilegi elevati (sudo).\033[0m\n"' ERR

# ------------------------------------------------------------------------------
# Configurazione Variabili Globali
# ------------------------------------------------------------------------------
LOG_FILE="/var/log/homelab-ai-amd.log"
INSTALL_DIR="/opt/homelab-ai"
LLAMA_DIR="${INSTALL_DIR}/llama.cpp"
MODELS_DIR="${INSTALL_DIR}/models"
WEBUI_DIR="${INSTALL_DIR}/open-webui"

SERVICE_NAME="homelab-ai-backend"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
FRONTEND_SERVICE_FILE="/etc/systemd/system/homelab-ai-frontend.service"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ------------------------------------------------------------------------------
# Utility e Logging
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# Installazione Stack Sistema
# ------------------------------------------------------------------------------
install_dependencies() {
    export DEBIAN_FRONTEND=noninteractive
    export APT_LISTCHANGES_FRONTEND=none

    log_info "Verifica pacchetti base di sistema..."
    apt-get update || true
    apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" \
        build-essential cmake git curl wget pkg-config pciutils gnupg \
        libvulkan-dev vulkan-tools python3 python3-pip python3-venv python3-dev whiptail \
        libffi-dev libssl-dev libomp-dev || true
    
    log_info "Verifica e pulizia conflitti con pacchetti ROCm nativi..."
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

# ------------------------------------------------------------------------------
# Auto-Riparazione Toolchain ROCm
# ------------------------------------------------------------------------------
ensure_hipcc_toolchain() {
    local HIPCC_BIN="/opt/rocm/bin/hipcc"
    if [[ ! -x "$HIPCC_BIN" ]]; then
        log_warn "Compilatore hipcc non trovato. Iniezione forzata repository AMD ROCm 6.2..."
        
        mkdir -p /etc/apt/keyrings
        wget -q -O - https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/rocm.gpg
        
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/6.2 noble main" > /etc/apt/sources.list.d/rocm.list
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/amdgpu/6.2/ubuntu noble main" > /etc/apt/sources.list.d/amdgpu.list
        
        cat <<EOF > /etc/apt/preferences.d/99-rocm-amd
Package: *
Pin: origin repo.radeon.com
Pin-Priority: 1001
EOF
        
        export DEBIAN_FRONTEND=noninteractive
        apt-get update || true
        
        log_info "Installazione toolchain HIP/ROCm ufficiale AMD..."
        apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" rocm-dev rocm-hip-sdk || true
        
        if [[ ! -x "$HIPCC_BIN" ]]; then
            log_err "Auto-riparazione fallita. Repository non raggiungibili o pacchetti inesistenti."
            return 1
        fi
        log_info "Auto-riparazione completata: hipcc installato con successo."
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Compilazione llama.cpp & Patch FP8
# ------------------------------------------------------------------------------
compile_llama() {
    local type="$1"
    
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    
    if [[ ! -d "${LLAMA_DIR}" ]]; then
        git clone https://github.com/ggerganov/llama.cpp.git "${LLAMA_DIR}"
    else
        git -C "${LLAMA_DIR}" pull
    fi

    # Iniezione patch di compatibilità ROCm 6.2 / fallback tipi FP8 per architetture come gfx1030
    if [[ -f "${LLAMA_DIR}/ggml/src/ggml-cuda/vendors/hip.h" ]]; then
        log_info "Applicazione patch di compatibilità ROCm FP8 e fallback tipi..."
        sed -i 's/typedef __hip_fp8_e4m3 __nv_fp8_e4m3;/typedef uint8_t __nv_fp8_e4m3;/g' "${LLAMA_DIR}/ggml/src/ggml-cuda/vendors/hip.h" || true
        sed -i 's/typedef __hip_fp8_e5m2 __nv_fp8_e5m2;/typedef uint8_t __nv_fp8_e5m2;/g' "${LLAMA_DIR}/ggml/src/ggml-cuda/vendors/hip.h" || true
    fi

    log_info "Pulizia cache di compilazione..."
    rm -rf "${LLAMA_DIR}/build"
    rm -rf ~/.cache/ccache 2>/dev/null || true
    hash -r

    local gpu_profile target override
    gpu_profile=$(get_amd_gpu_profile)
    target=$(echo "$gpu_profile" | cut -d'|' -f1)
    override=$(echo "$gpu_profile" | cut -d'|' -f2)

    log_info "Avvio compilazione llama.cpp (Backend: ${type})..."

    case "${type}" in
        "vulkan")
            cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" -DGGML_VULKAN=ON
            cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
            ;;
        "rocm"|"rocm_exp")
            if ! ensure_hipcc_toolchain; then
                return 1
            fi
            
            local ROCM_PREFIX="/opt/rocm"
            local ROCM_CLANG="${ROCM_PREFIX}/llvm/bin/clang"
            local ROCM_CLANGXX="${ROCM_PREFIX}/llvm/bin/clang++"
            local CMAKE_ROCM_FLAGS="-DGGML_HIP=ON -DAMDGPU_TARGETS=${target} -DROCM_PATH=${ROCM_PREFIX} -DCMAKE_PREFIX_PATH=${ROCM_PREFIX}/lib/cmake:${ROCM_PREFIX}/lib/x86_64-linux-gnu/cmake -DCMAKE_C_FLAGS=-Wno-pedantic -DCMAKE_CXX_FLAGS=-Wno-pedantic"
            
            export PATH="${ROCM_PREFIX}/bin:${ROCM_PREFIX}/llvm/bin:${PATH}"
            export CC="${ROCM_CLANG}"
            export CXX="${ROCM_CLANGXX}"

            if [[ "${type}" == "rocm_exp" && -n "${override}" ]]; then
                log_warn "Iniezione Hack di compatibilità: HSA_OVERRIDE_GFX_VERSION=${override}"
                export HSA_OVERRIDE_GFX_VERSION="${override}"
            fi
            
            cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" ${CMAKE_ROCM_FLAGS}
            cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
            ;;
    esac

    log_info "Compilazione completata con successo."
    auto_setup_systemd_service "${type}" "${override}"
}

auto_setup_systemd_service() {
    local type="$1"
    local override="$2"
    local host="0.0.0.0"
    local port="8080"
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
Description=Homelab AI Backend Service (llama.cpp)
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
    log_info "Servizio ${SERVICE_NAME} configurato con variabili d'ambiente ROCm e avviato."
}

# ------------------------------------------------------------------------------
# Gestione Frontend (Open WebUI)
# ------------------------------------------------------------------------------
install_open_webui() {
    log_info "Installazione/Aggiornamento Open WebUI (Frontend)..."
    mkdir -p "${WEBUI_DIR}"
    
    if [[ ! -d "${WEBUI_DIR}/venv" ]]; then
        python3 -m venv "${WEBUI_DIR}/venv"
    fi
    
    source "${WEBUI_DIR}/venv/bin/activate"
    pip install --upgrade pip
    pip install open-webui
    deactivate

    cat <<EOF > "${FRONTEND_SERVICE_FILE}"
[Unit]
Description=Homelab AI Frontend Service (Open WebUI)
After=network.target ${SERVICE_NAME}.service

[Service]
Type=simple
User=root
WorkingDirectory=${WEBUI_DIR}
Environment="PORT=3000"
Environment="OPENAI_API_BASE_URL=http://127.0.0.1:8080/v1"
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
    log_info "Open WebUI configurato con successo (Porta 3000)."
    read -rp "Premi Invio per continuare..."
}

# ------------------------------------------------------------------------------
# Gestione Modelli GGUF
# ------------------------------------------------------------------------------
download_model() {
    local model_url
    model_url=$(whiptail --title "Gestione Modelli GGUF" --inputbox "Inserisci l'URL diretto del file GGUF da scaricare:" 10 78 "https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf" 3>&1 1>&2 2>&3)
    
    if [[ -n "${model_url}" ]]; then
        local filename
        filename=$(basename "${model_url}" | cut -d? -f1)
        log_info "Download del modello ${filename} in corso..."
        wget -O "${MODELS_DIR}/${filename}" "${model_url}"
        ln -sf "${MODELS_DIR}/${filename}" "${MODELS_DIR}/model.gguf"
        log_info "Modello scaricato e impostato come default (model.gguf)."
        systemctl restart "${SERVICE_NAME}" 2>/dev/null || true
    fi
    read -rp "Premi Invio per continuare..."
}

# ------------------------------------------------------------------------------
# Gestione Servizi
# ------------------------------------------------------------------------------
manage_service_menu() {
    local action
    action=$(whiptail --title "Gestione Servizi Homelab AI" \
        --menu "\nSeleziona l'azione da compiere:" 15 78 4 \
        "1" "Avvia Servizi (Backend & Frontend)" \
        "2" "Ferma Servizi (Backend & Frontend)" \
        "3" "Riavvia Servizi (Backend & Frontend)" \
        "4" "Torna al Menu Principale" \
        3>&1 1>&2 2>&3)
    
    case "$action" in
        1) 
            systemctl start "${SERVICE_NAME}" homelab-ai-frontend 2>/dev/null || true
            log_info "Servizi avviati." 
            ;;
        2) 
            systemctl stop "${SERVICE_NAME}" homelab-ai-frontend 2>/dev/null || true
            log_info "Servizi fermati." 
            ;;
        3) 
            systemctl restart "${SERVICE_NAME}" homelab-ai-frontend 2>/dev/null || true
            log_info "Servizi riavviati." 
            ;;
        *) ;;
    esac
}

# ------------------------------------------------------------------------------
# Menu TUI
# ------------------------------------------------------------------------------
select_backend() {
    local choice
    choice=$(whiptail --title "Selezione Backend Inferenza AMD" \
        --menu "\nSeleziona il backend grafico per la tua GPU AMD:" 18 78 3 \
        "1" "Vulkan (RACCOMANDATO per Navi / RDNA su OS Moderni)" \
        "2" "ROCm Sperimentale (Auto-fix HIPCC + Patch FP8 + Hack HSA)" \
        "3" "ROCm Ufficiale (Architetture native supportate)" \
        3>&1 1>&2 2>&3)

    case "$choice" in
        1) compile_llama "vulkan" ;;
        2) compile_llama "rocm_exp" ;;
        3) compile_llama "rocm" ;;
        *) log_warn "Operazione annullata." ;;
    esac
}

main_menu() {
    while true; do
        local choice
        choice=$(whiptail --title "Homelab AI - AMD Management Console" \
            --menu "\nAmbiente: $(detect_environment)\nScegli un'operazione:" 18 78 7 \
            "1" "Seleziona/Compila Backend Llama.cpp (Auto GPU + Patch FP8)" \
            "2" "Installa / Configura Open WebUI (Frontend)" \
            "3" "Scarica / Gestisci Modelli GGUF" \
            "4" "Gestione Servizi (Avvia/Ferma/Riavvia)" \
            "5" "Stato Servizi (Backend & Frontend)" \
            "6" "Visualizza Log di Sistema" \
            "7" "Esci" \
            3>&1 1>&2 2>&3)

        case "$choice" in
            1) select_backend; read -rp "Premi Invio per continuare..." ;;
            2) install_open_webui ;;
            3) download_model ;;
            4) manage_service_menu ;;
            5) systemctl status "${SERVICE_NAME}" homelab-ai-frontend 2>/dev/null || true; read -rp "Premi Invio per continuare..." ;;
            6) tail -n 50 "${LOG_FILE}" || true; read -rp "Premi Invio per continuare..." ;;
            7) break ;;
            *) break ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Avvio (Entrypoint)
# ------------------------------------------------------------------------------
check_root
init_env
install_dependencies
main_menu
