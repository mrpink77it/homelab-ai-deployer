#!/usr/bin/env bash
# ==============================================================================
# Script: manager-amd.sh
# Descrizione: Gestore deployment, servizi systemd e ciclo AI per GPU AMD
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
WEBUI_DATA_DIR="${INSTALL_DIR}/open-webui-data"

SERVICE_NAME="homelab-ai-backend"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

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
    mkdir -p "$(dirname "$LOG_FILE")" "${MODELS_DIR}" "${WEBUI_DATA_DIR}"
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
        libvulkan-dev vulkan-tools python3 python3-pip python3-venv python3-dev whiptail || true
    
    log_info "Verifica conflitti con pacchetti ROCm di sistema (obsoleti)..."
    if dpkg -l | grep -qE "hipcc|rocm-dev|libhip-dev"; then
        log_warn "Rilevata versione di sistema di ROCm non compatibile. Pulizia profonda..."
        apt-get remove --purge -y hipcc rocm-dev rocm-cmake rocm-core libamdhip64-dev libhip-dev >/dev/null 2>&1 || true
        apt-get autoremove -y >/dev/null 2>&1 || true
    fi
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
# Auto-Riparazione Toolchain ROCm (Brute-Force)
# ------------------------------------------------------------------------------
ensure_hipcc_toolchain() {
    local HIPCC_BIN="/opt/rocm/bin/hipcc"
    if [[ ! -x "$HIPCC_BIN" ]]; then
        log_warn "Compilatore hipcc non trovato. Iniezione forzata repository AMD ROCm 6.2..."
        
        # Bypassiamo amdgpu-install e registriamo i repo a mano
        mkdir -p /etc/apt/keyrings
        wget -q -O - https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/rocm.gpg
        
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/6.2 noble main" > /etc/apt/sources.list.d/rocm.list
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/amdgpu/6.2/ubuntu noble main" > /etc/apt/sources.list.d/amdgpu.list
        
        # Diamo priorità ai pacchetti AMD ufficiali
        echo -e "Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600" > /etc/apt/preferences.d/rocm-pin-600
        
        export DEBIAN_FRONTEND=noninteractive
        apt-get update || true
        
        log_info "Installazione toolchain HIP/ROCm..."
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
# Compilazione llama.cpp
# ------------------------------------------------------------------------------
compile_llama() {
    local type="$1"
    
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    
    if [[ ! -d "${LLAMA_DIR}" ]]; then
        git clone https://github.com/ggerganov/llama.cpp.git "${LLAMA_DIR}"
    else
        git -C "${LLAMA_DIR}" pull
    fi

    log_info "Pulizia profonda cache di compilazione..."
    rm -rf "${LLAMA_DIR}/build"
    rm -rf ~/.cache/ccache 2>/dev/null || true
    hash -r

    local gpu_profile target override env_override=""
    gpu_profile=$(get_amd_gpu_profile)
    target=$(echo "$gpu_profile" | cut -d'|' -f1)
    override=$(echo "$gpu_profile" | cut -d'|' -f2)

    log_info "Avvio compilazione llama.cpp (Backend: ${type})..."

    case "${type}" in
        "vulkan")
            log_info "Backend Vulkan selezionato. Ignoro ROCm..."
            cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" -DGGML_VULKAN=ON
            cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
            ;;
        "rocm"|"rocm_exp")
            if ! ensure_hipcc_toolchain; then
                log_err "Interruzione compilazione. Ritorno al menu principale."
                return 1
            fi
            
            local HIPCC_BIN="/opt/rocm/bin/hipcc"
            local ROCM_PREFIX="/opt/rocm"
            local CMAKE_ROCM_FLAGS="-DGGML_HIP=ON -DAMDGPU_TARGETS=${target} -DROCM_PATH=${ROCM_PREFIX} -DCMAKE_PREFIX_PATH=${ROCM_PREFIX}/lib/cmake:${ROCM_PREFIX}/lib/x86_64-linux-gnu/cmake"
            
            export PATH="${ROCM_PREFIX}/bin:${PATH}"
            export CXX="${HIPCC_BIN}"

            if [[ "${type}" == "rocm_exp" && -n "${override}" ]]; then
                log_warn "Iniezione Hack di compatibilità: HSA_OVERRIDE_GFX_VERSION=${override}"
                export HSA_OVERRIDE_GFX_VERSION="${override}"
                env_override="Environment=\"HSA_OVERRIDE_GFX_VERSION=${override}\""
            fi
            
            cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" ${CMAKE_ROCM_FLAGS}
            cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
            ;;
    esac

    log_info "Compilazione completata con successo."
    auto_setup_systemd_service "${env_override}"
}

auto_setup_systemd_service() {
    local env_override="$1"
    local host="0.0.0.0"
    local port="8080"
    local model_path="${MODELS_DIR}/model.gguf"

    cat <<EOF > "${SERVICE_FILE}"
[Unit]
Description=Homelab AI Backend Service (llama.cpp)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
${env_override}
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
    systemctl restart "${SERVICE_NAME}"
    log_info "Servizio ${SERVICE_NAME} abilitato e in esecuzione."
}

# ------------------------------------------------------------------------------
# Menu TUI
# ------------------------------------------------------------------------------
select_backend() {
    local choice
    choice=$(whiptail --title "Selezione Backend Inferenza AMD" \
        --menu "\nSeleziona il backend grafico per la tua GPU AMD:" 18 78 3 \
        "1" "Vulkan (RACCOMANDATO per Navi 10 / RDNA1 su OS Moderni)" \
        "2" "ROCm Sperimentale (Auto-fix HIPCC + Hack HSA_OVERRIDE)" \
        "3" "ROCm Ufficiale (Solo architetture native supportate)" \
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
            --menu "\nAmbiente: $(detect_environment)\nScegli un'operazione:" 15 78 4 \
            "1" "Seleziona/Compila Backend (Auto-Rilevamento GPU)" \
            "2" "Stato Servizio Backend" \
            "3" "Visualizza Log di Sistema" \
            "4" "Esci" \
            3>&1 1>&2 2>&3)

        case "$choice" in
            1) select_backend ;;
            2) systemctl status "${SERVICE_NAME}" || true; read -rp "Premi Invio per continuare..." ;;
            3) tail -n 50 "${LOG_FILE}" || true; read -rp "Premi Invio per continuare..." ;;
            4) break ;;
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
