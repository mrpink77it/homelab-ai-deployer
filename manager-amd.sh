#!/usr/bin/env bash
# ==============================================================================
# Script: manager_amd.sh
#Descrizione: Gestore deployment e ciclo di vita AI per GPU AMD
#Ambienti: Bare-Metal & Proxmox LXC
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configurazione Variabili Globale e Log
# ------------------------------------------------------------------------------
LOG_FILE="/var/log/homelab-ai-amd.log"
INSTALL_DIR="/opt/homelab-ai"
LLAMA_DIR="${INSTALL_DIR}/llama.cpp"
SERVICE_NAME="homelab-ai-backend"
BACKEND_CONF="${INSTALL_DIR}/backend.conf"

# Colori TUI
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ------------------------------------------------------------------------------
# Funzioni Helper & Logging
# ------------------------------------------------------------------------------
log() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "${timestamp} [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

log_info() { log "INFO" "${GREEN}$1${NC}"; }
log_warn() { log "WARN" "${YELLOW}$1${NC}"; }
log_err()  { log "ERROR" "${RED}$1${NC}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "Questo script deve essere eseguito come root (o tramite sudo)."
        exit 1
    fi
}

detect_environment() {
    if [[ -f /proc/1/environ ]] && grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
        echo "LXC (Proxmox)"
    elif grep -q "systemd-private" /proc/1/environ 2>/dev/null || [[ -d /dev/dri ]]; then
        echo "Bare-Metal / Standard VM"
    else
        echo "Sconosciuto"
    fi
}

# ------------------------------------------------------------------------------
# Inizializzazione Ambiente
# ------------------------------------------------------------------------------
init_env() {
    mkdir -p "$(dirname "$LOG_FILE")"
    mkdir -p "${INSTALL_DIR}"
    touch "${LOG_FILE}"
}

# ------------------------------------------------------------------------------
# Installazione Dipendenze e Driver AMD
# ------------------------------------------------------------------------------
install_dependencies() {
    log_info "Verifica e installazione pacchetti di sistema..."
    apt-get update -qq
    apt-get install -y -qq \
        build-essential \
        cmake \
        git \
        curl \
        wget \
        pkg-config \
        libvulkan-dev \
        vulkan-tools \
        shaderc \
        glslang-tools \
        clinfo \
        pciutils \
        openssh-server \
        htop \
        whiptail

    log_info "Dipendenze base installate correttamente."
}

# ------------------------------------------------------------------------------
# Selezione e Compilazione Backend d'Inferenza (ROCm / Vulkan)
# ------------------------------------------------------------------------------
select_backend() {
    local choice
    choice=$(whiptail --title "Selezione Backend Inferenza AMD" \
        --menu "Scegli il backend di accelerazione hardware per llama.cpp:" 15 65 3 \
        "1" "ROCm Ufficiale (Consigliato per GPU Instinct/Radeon Pro)" \
        "2" "Vulkan (Consigliato per GPU Consumer / Integrazione Cross-Platform)" \
        "3" "ROCm Sperimentale / Custom HIP (Per architetture RX non supportate)" \
        3>&1 1>&2 2>&3)

    case "$choice" in
        1)
            echo "BACKEND=rocm_official" > "${BACKEND_CONF}"
            log_info "Selezionato backend: ROCm Ufficiale"
            compile_llama "rocm"
            ;;
        2)
            echo "BACKEND=vulkan" > "${BACKEND_CONF}"
            log_info "Selezionato backend: Vulkan"
            compile_llama "vulkan"
            ;;
        3)
            echo "BACKEND=rocm_experimental" > "${BACKEND_CONF}"
            log_info "Selezionato backend: ROCm Sperimentale"
            compile_llama "rocm_exp"
            ;;
        *)
            log_warn "Nessun backend selezionato."
            ;;
    esac
}

compile_llama() {
    local type="$1"
    log_info "Clonazione / Aggiornamento repository llama.cpp..."
    
    if [[ ! -d "${LLAMA_DIR}" ]]; then
        git clone https://github.com/ggerganov/llama.cpp.git "${LLAMA_DIR}"
    else
        git -C "${LLAMA_DIR}" pull
    fi

    log_info "Avvio compilazione llama.cpp (Backend: ${type})..."
    rm -rf "${LLAMA_DIR}/build"

    case "${type}" in
        "vulkan")
            cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" -DGGML_VULKAN=ON -DGGML_VULKAN_SHADERS_GEN=OFF
            cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
            ;;
        "rocm")
            cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" -DGGML_HIPBLAS=ON -DAMDGPU_TARGETS=gfx900,gfx906,gfx908,gfx1030,gfx1100
            cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
            ;;
        "rocm_exp")
            HSA_OVERRIDE_GFX_VERSION=10.3.0 cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" -DGGML_HIPBLAS=ON
            cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
            ;;
    esac

    log_info "Compilazione completata con successo in ${LLAMA_DIR}/build"
}

# ------------------------------------------------------------------------------
# Monitoraggio Hardware e Stato Servizi
# ------------------------------------------------------------------------------
check_hardware_status() {
    clear
    echo -e "${BOLD}${CYAN}=== Stato Hardware AMD & Diagnostica ===${NC}"
    echo -e "Ambiente Rilevato: ${BOLD}$(detect_environment)${NC}\n"

    echo -e "${YELLOW}[Dispositivi PCI AMD]${NC}"
    lspci | grep -iE 'vga|3d|display|amd' || echo "Nessun dispositivo PCI AMD rilevato."
    echo ""

    echo -e "${YELLOW}[Stato ROCm / HIP]${NC}"
    if command -v rocm-smi &>/dev/null; then
        rocm-smi || true
    else
        echo "rocm-smi non presente."
    fi
    echo ""

    echo -e "${YELLOW}[Stato Vulkan ICD]${NC}"
    if command -v vulkaninfo &>/dev/null; then
        vulkaninfo --summary 2>/dev/null | grep -iE 'deviceName|driverID|driverName' || echo "Informazioni Vulkan non disponibili."
    else
        echo "vulkan-tools non presente."
    fi
    echo ""

    echo -e "${YELLOW}[Servizio AI Systemd]${NC}"
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        echo -e "Stato: ${GREEN}ATTIVO${NC}"
    else
        echo -e "Stato: ${RED}INATTIVO / NON CONFIGURATO${NC}"
    fi

    echo ""
    read -rp "Premere invio per tornare al menu..."
}

# ------------------------------------------------------------------------------
# Configurazione Nodo Sandbox SSH
# ------------------------------------------------------------------------------
setup_sandbox_ssh() {
    log_info "Configurazione accesso Sandbox SSH..."
    
    local ssh_port
    ssh_port=$(whiptail --inputbox "Inserisci la porta SSH per il nodo Sandbox:" 8 60 "2222" 3>&1 1>&2 2>&3)
    
    if [[ -n "${ssh_port}" ]]; then
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh
        touch /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys

        log_info "Nodi Sandbox SSH configurati sulla porta ${ssh_port}."
        whiptail --msgbox "Accesso SSH registrato. Aggiungi la tua chiave pubblica in /root/.ssh/authorized_keys" 10 60
    fi
}

# ------------------------------------------------------------------------------
# Aggiornamento Componenti
# ------------------------------------------------------------------------------
update_components() {
    log_info "Aggiornamento componenti e ricompilazione..."
    if [[ -f "${BACKEND_CONF}" ]]; then
        source "${BACKEND_CONF}"
        case "${BACKEND:-vulkan}" in
            "rocm_official") compile_llama "rocm" ;;
            "rocm_experimental") compile_llama "rocm_exp" ;;
            *) compile_llama "vulkan" ;;
        esac
    else
        select_backend
    fi
    log_info "Aggiornamento completato."
}

# ------------------------------------------------------------------------------
# Disinstallazione e Pulizia
# ------------------------------------------------------------------------------
uninstall_environment() {
    if whiptail --title "Conferma Rimozione" --yesno "Sei sicuro di voler rimuovere completamente l'ambiente Homelab-AI e llama.cpp?" 10 60; then
        log_warn "Rimozione in corso..."
        systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
        systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
        rm -rf "${INSTALL_DIR}"
        log_info "Ambiente rimosso con successo."
    fi
}

# ------------------------------------------------------------------------------
# Menu Principale TUI
# ------------------------------------------------------------------------------
main_menu() {
    while true; do
        local choice
        choice=$(whiptail --title "Homelab AI - AMD Management Console" \
            --menu "Ambiente: $(detect_environment)\nScegli un'operazione:" 18 70 7 \
            "1" "Verifica Stato Hardware e Servizi" \
            "2" "Seleziona/Compila Backend (ROCm / Vulkan)" \
            "3" "Configura Nodo SSH Sandbox" \
            "4" "Aggiorna Componenti (llama.cpp)" \
            "5" "Visualizza Log di Sistema" \
            "6" "Disinstalla Ambiente AI" \
            "7" "Esci" \
            3>&1 1>&2 2>&3)

        case "$choice" in
            1) check_hardware_status ;;
            2) select_backend ;;
            3) setup_sandbox_ssh ;;
            4) update_components ;;
            5) clear; tail -n 50 "${LOG_FILE}"; read -rp "Premere invio per continuare..." ;;
            6) uninstall_environment ;;
            7) echo -e "${GREEN}Uscita.${NC}"; break ;;
            *) break ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Main Entrypoint
# ------------------------------------------------------------------------------
check_root
init_env
install_dependencies
main_menu
