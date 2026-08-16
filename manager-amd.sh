#!/usr/bin/env bash
# ==============================================================================
# Script: manager-amd.sh
# Descrizione: Gestore deployment, servizi systemd, Open WebUI Bare-Metal e ciclo AI per GPU AMD
# Ambienti: Bare-Metal & Proxmox LXC (Debian 13 / Ubuntu 24.04 LTS)
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configurazione Variabili Globali e Log
# ------------------------------------------------------------------------------
LOG_FILE="/var/log/homelab-ai-amd.log"
INSTALL_DIR="/opt/homelab-ai"
LLAMA_DIR="${INSTALL_DIR}/llama.cpp"
MODELS_DIR="${INSTALL_DIR}/models"
WEBUI_VENV="${INSTALL_DIR}/venv-webui"
WEBUI_DATA_DIR="${INSTALL_DIR}/open-webui-data"

SERVICE_NAME="homelab-ai-backend"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

WEBUI_SERVICE_NAME="homelab-ai-webui"
WEBUI_SERVICE_FILE="/etc/systemd/system/${WEBUI_SERVICE_NAME}.service"

BACKEND_CONF="${INSTALL_DIR}/backend.conf"

# Colori TUI
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ------------------------------------------------------------------------------
# Funzioni Helper & Logging
# ------------------------------------------------------------------------------
log() {
    local level="$1"
    local msg="$2"
    echo -e "$(date "+%Y-%m-%d %H:%M:%S") [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

log_info() { log "INFO" "${GREEN}$1${NC}"; }
log_warn() { log "WARN" "${YELLOW}$1${NC}"; }
log_err()  { log "ERROR" "${RED}$1${NC}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "Eseguire come root."
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
    touch "${LOG_FILE}"
}

# ------------------------------------------------------------------------------
# Gestione Dipendenze e Repository Ufficiali AMD
# ------------------------------------------------------------------------------
install_dependencies() {
    log_info "Verifica pacchetti base di sistema..."
    apt-get update -qq
    apt-get install -y -qq build-essential cmake git curl wget pkg-config pciutils \
        libvulkan-dev vulkan-tools python3 python3-pip python3-venv python3-dev
    
    # Integrazione Repository AMD per compilatore HIP e ROCm
    if ! command -v hipcc &>/dev/null; then
        log_warn "Compilatore hipcc non trovato. Installazione stack ROCm ufficiale AMD in corso..."
        local amd_deb="/tmp/amdgpu-install.deb"
        # Utilizzo pacchetto generico Ubuntu Noble (compatibile con Debian testing/13 in ambito homelab)
        wget -q "https://repo.radeon.com/amdgpu-install/6.1.2/ubuntu/noble/amdgpu-install_6.1.60102-1_all.deb" -O "${amd_deb}"
        dpkg -i "${amd_deb}" || apt-get install -f -y
        apt-get update -qq
        
        log_info "Installazione toolchain hiplibsdk e rocm..."
        amdgpu-install -y --usecase=rocm,hiplibsdk --no-dkms || log_warn "Possibili dipendenze ROCm mancanti, fallback su Vulkan garantito."
    else
        log_info "Stack ROCm già presente nel sistema."
    fi
}

# ------------------------------------------------------------------------------
# Diagnostica Hardware Dinamica
# ------------------------------------------------------------------------------
get_amd_gpu_profile() {
    local gpu_info
    gpu_info=$(lspci | grep -iE 'vga|3d|display' | grep -i amd || true)
    
    local target="gfx1030" # Default fallback
    local override=""

    if echo "$gpu_info" | grep -qiE 'navi 10|5700|5600'; then
        # RDNA1 (es. RX 5700 XT) - Richiede override a RDNA2
        target="gfx1030"
        override="10.3.0"
    elif echo "$gpu_info" | grep -qiE 'navi 2|6700|6800|6900|6500'; then
        # RDNA2
        target="gfx1030"
    elif echo "$gpu_info" | grep -qiE 'navi 3|7900|7800|7600'; then
        # RDNA3
        target="gfx1100"
    elif echo "$gpu_info" | grep -qiE 'vega|radeon vii'; then
        # Vega (gfx900, gfx906)
        target="gfx900,gfx906"
    elif echo "$gpu_info" | grep -qiE 'polaris|rx 580|rx 570|rx 480'; then
        # Polaris (Molto sperimentale)
        target="gfx803"
        override="8.0.3"
    fi

    echo "${target}|${override}"
}

# ------------------------------------------------------------------------------
# Compilazione llama.cpp e Orchestrazione Systemd
# ------------------------------------------------------------------------------
compile_llama() {
    local type="$1"
    
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    
    if [[ ! -d "${LLAMA_DIR}" ]]; then
        git clone https://github.com/ggerganov/llama.cpp.git "${LLAMA_DIR}"
    else
        git -C "${LLAMA_DIR}" pull
    fi

    rm -rf "${LLAMA_DIR}/build"

    # Estrazione Profilo GPU Dinamico
    local gpu_profile target override env_override=""
    gpu_profile=$(get_amd_gpu_profile)
    target=$(echo "$gpu_profile" | cut -d'|' -f1)
    override=$(echo "$gpu_profile" | cut -d'|' -f2)

    log_info "Avvio compilazione llama.cpp (Backend: ${type})..."
    
    case "${type}" in
        "vulkan")
            cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" -DGGML_VULKAN=ON
            cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
            ;;
        "rocm")
            # ROCm Ufficiale (Senza Overrides)
            cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" -DGGML_HIP=ON -DAMDGPU_TARGETS="${target}"
            cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
            ;;
        "rocm_exp")
            # ROCm Sperimentale (Forza gli Override se la GPU lo richiede)
            if [[ -n "${override}" ]]; then
                log_warn "Applicazione Hack HSA_OVERRIDE_GFX_VERSION=${override} per architettura rilevata."
                export HSA_OVERRIDE_GFX_VERSION="${override}"
                env_override="Environment=\"HSA_OVERRIDE_GFX_VERSION=${override}\""
            fi
            cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" -DGGML_HIP=ON -DAMDGPU_TARGETS="${target}"
            cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
            ;;
    esac

    log_info "Compilazione completata."
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
    log_info "Servizio ${SERVICE_NAME} abilitato."
}

# ------------------------------------------------------------------------------
# Menu TUI e Workflow
# ------------------------------------------------------------------------------
select_backend() {
    local choice
    choice=$(whiptail --title "Selezione Backend Inferenza AMD" \
        --menu "\nSeleziona il backend grafico per la tua GPU AMD:" 18 78 3 \
        "1" "Vulkan (Raccomandato per compatibilità universale)" \
        "2" "ROCm Sperimentale (Applica override automatici per RDNA1/Polaris)" \
        "3" "ROCm Ufficiale (Nativo per RDNA2/RDNA3/Instinct)" \
        3>&1 1>&2 2>&3)

    case "$choice" in
        1) compile_llama "vulkan" ;;
        2) compile_llama "rocm_exp" ;;
        3) compile_llama "rocm" ;;
        *) log_warn "Nessuna selezione." ;;
    esac
}

main_menu() {
    while true; do
        local choice
        choice=$(whiptail --title "Homelab AI - AMD Management Console" \
            --menu "\nAmbiente: $(detect_environment)\nScegli un'operazione:" 15 78 4 \
            "1" "Seleziona/Compila Backend (Auto-Rilevamento GPU)" \
            "2" "Stato Servizio Backend" \
            "3" "Log di Sistema" \
            "4" "Esci" \
            3>&1 1>&2 2>&3)

        case "$choice" in
            1) select_backend ;;
            2) systemctl status "${SERVICE_NAME}" || true; read -rp "Invio per continuare..." ;;
            3) tail -n 50 "${LOG_FILE}"; read -rp "Invio per continuare..." ;;
            4) break ;;
            *) break ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Entrypoint
# ------------------------------------------------------------------------------
check_root
init_env
install_dependencies
main_menu
