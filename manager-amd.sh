#!/usr/bin/env bash
# ==============================================================================
# Script: manager-amd.sh
# Descrizione: Gestore deployment, servizi systemd e ciclo di vita AI per GPU AMD
# Ambienti: Bare-Metal & Proxmox LXC
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configurazione Variabili Globali e Log
# ------------------------------------------------------------------------------
LOG_FILE="/var/log/homelab-ai-amd.log"
INSTALL_DIR="/opt/homelab-ai"
LLAMA_DIR="${INSTALL_DIR}/llama.cpp"
MODELS_DIR="${INSTALL_DIR}/models"
SERVICE_NAME="homelab-ai-backend"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
BACKEND_CONF="${INSTALL_DIR}/backend.conf"

# Pacchetti installati dallo script per la gestione/compilazione
DEP_PACKAGES=(
    build-essential
    cmake
    git
    curl
    wget
    pkg-config
    libvulkan-dev
    vulkan-tools
    glslc
    libshaderc-dev
    glslang-tools
    clinfo
    pciutils
    openssh-server
    htop
    whiptail
)

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
    mkdir -p "${MODELS_DIR}"
    touch "${LOG_FILE}"
}

# ------------------------------------------------------------------------------
# Installazione Dipendenze e Driver AMD
# ------------------------------------------------------------------------------
install_dependencies() {
    log_info "Verifica e installazione pacchetti di sistema..."
    apt-get update -qq
    apt-get install -y -qq "${DEP_PACKAGES[@]}"
    log_info "Dipendenze base installate correttamente."
}

# ------------------------------------------------------------------------------
# Configurazione e Avvio Automatico Systemd (al Boot e Post-Install)
# ------------------------------------------------------------------------------
auto_setup_systemd_service() {
    log_info "Configurazione ed abilitazione automatica del servizio Systemd (${SERVICE_NAME})..."

    local host="0.0.0.0"
    local port="8080"
    local model_path="${MODELS_DIR}/model.gguf"
    local extra_args="-ngl 99 -c 2048"

    cat <<EOF > "${SERVICE_FILE}"
[Unit]
Description=Homelab AI Backend Service (llama.cpp)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${LLAMA_DIR}/build/bin/llama-server --host ${host} --port ${port} -m "${model_path}" ${extra_args}
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
    
    log_info "Servizio ${SERVICE_NAME} abilitato al boot e avviato automaticamente."
}

# ------------------------------------------------------------------------------
# Selezione e Compilazione Backend d'Inferenza (ROCm / Vulkan)
# ------------------------------------------------------------------------------
select_backend() {
    local choice
    choice=$(whiptail --title "Selezione Backend Inferenza AMD" \
        --menu "\nScegli il backend di accelerazione hardware per llama.cpp:" 18 78 3 \
        "1" "ROCm Ufficiale (Consigliato per GPU Instinct/Radeon Pro)" \
        "2" "Vulkan (Consigliato per GPU Consumer / Cross-Platform)" \
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

    # Configurazione e Avvio Automatico del servizio
    auto_setup_systemd_service
}

# ------------------------------------------------------------------------------
# Gestione Manuale Servizio Systemd (Personalizzazione Parametri)
# ------------------------------------------------------------------------------
custom_setup_systemd_service() {
    log_info "Personalizzazione configurazione servizio Systemd (${SERVICE_NAME})..."

    if [[ ! -f "${LLAMA_DIR}/build/bin/llama-server" ]]; then
        whiptail --msgbox "Esegui prima la compilazione del backend (Opzione 2) per generare il binario llama-server!" 10 60
        return
    fi

    local host port model_path extra_args
    host=$(whiptail --inputbox "Host Bind per il server API:" 10 60 "0.0.0.0" 3>&1 1>&2 2>&3) || return
    port=$(whiptail --inputbox "Porta per il server API:" 10 60 "8080" 3>&1 1>&2 2>&3) || return
    model_path=$(whiptail --inputbox "Percorso assoluto al modello (.gguf):" 10 60 "${MODELS_DIR}/model.gguf" 3>&1 1>&2 2>&3) || return
    extra_args=$(whiptail --inputbox "Argomenti extra (es: -ngl 99 -c 4096):" 10 60 "-ngl 99 -c 2048" 3>&1 1>&2 2>&3) || return

    cat <<EOF > "${SERVICE_FILE}"
[Unit]
Description=Homelab AI Backend Service (llama.cpp)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${LLAMA_DIR}/build/bin/llama-server --host ${host} --port ${port} -m "${model_path}" ${extra_args}
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
    log_info "Servizio ${SERVICE_NAME} aggiornato e riavviato."
    whiptail --msgbox "Servizio aggiornato e riavviato con successo!" 8 50
}

manage_service_menu() {
    while true; do
        local choice
        choice=$(whiptail --title "Gestione Servizio Systemd" \
            --menu "\nSeleziona un'azione per ${SERVICE_NAME}:" 18 78 6 \
            "1" "Personalizza Parametri Servizio (Porta, Modello, Argomenti)" \
            "2" "Riavvia Servizio" \
            "3" "Arresta Servizio" \
            "4" "Visualizza Stato Dettagliato (systemctl)" \
            "5" "Visualizza Log in Tempo Reale (journalctl)" \
            "6" "Torna al Menu Principale" \
            3>&1 1>&2 2>&3)

        case "$choice" in
            1) custom_setup_systemd_service ;;
            2) 
                systemctl restart "${SERVICE_NAME}"
                log_info "Servizio ${SERVICE_NAME} riavviato."
                whiptail --msgbox "Servizio riavviato!" 8 40
                ;;
            3) 
                systemctl stop "${SERVICE_NAME}"
                log_info "Servizio ${SERVICE_NAME} arrestato."
                whiptail --msgbox "Servizio arrestato!" 8 40
                ;;
            4) 
                clear
                systemctl status "${SERVICE_NAME}" || true
                read -rp "Premere invio per tornare al menu..."
                ;;
            5) 
                clear
                journalctl -u "${SERVICE_NAME}" -n 100 -f
                ;;
            6) break ;;
            *) break ;;
        esac
    done
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
        echo -e "Stato: ${GREEN}ATTIVO (Running - Abilitato al boot)${NC}"
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
    ssh_port=$(whiptail --inputbox "Inserisci la porta SSH per il nodo Sandbox:" 10 60 "2222" 3>&1 1>&2 2>&3)
    
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
# Pulizia File Temporanei e Cache di Sistema
# ------------------------------------------------------------------------------
clean_system_cache() {
    log_info "Avvio pulizia cache di sistema e file temporanei..."

    apt-get clean -y
    apt-get autoremove --purge -y

    if command -v ccache &>/dev/null; then
        ccache -C
    fi

    rm -rf /root/.cache/vulkan /root/.cache/AMD ~/.cache/vulkan ~/.cache/AMD
    rm -rf /tmp/* /var/tmp/*

    if command -v journalctl &>/dev/null; then
        journalctl --vacuum-size=100M || true
    fi

    log_info "Pulizia completata con successo."
    whiptail --msgbox "Cache pacchetti, shader e file temporanei rimossi con successo!" 10 60
}

# ------------------------------------------------------------------------------
# Disinstallazione e Pulizia Completa (Servizi, File, Dipendenze APT)
# ------------------------------------------------------------------------------
uninstall_environment() {
    if whiptail --title "Conferma Rimozione Completa" --yesno "Sei sicuro di voler disinstallare completamente l'ambiente?\n\n- Arresto e rimozione servizio Systemd\n- Rimozione directory ${INSTALL_DIR}\n- Rimozione dei file di log" 12 70; then
        
        log_warn "Avvio disinstallazione..."

        # 1. Arresto e rimozione servizio Systemd
        if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null || [[ -f "${SERVICE_FILE}" ]]; then
            log_info "Arresto e rimozione servizio Systemd..."
            systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
            systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
            rm -f "${SERVICE_FILE}"
            systemctl daemon-reload
        fi

        # 2. Rimozione cartelle installazione e file temporanei
        log_info "Rimozione cartelle e log..."
        rm -rf "${INSTALL_DIR}"
        rm -rf /root/.cache/vulkan /root/.cache/AMD

        # 3. Richiesta conferma per rimozione dipendenze PRIMA di rimuovere whiptail
        local remove_deps=0
        if whiptail --title "Rimozione Dipendenze di Sistema" --yesno "Vuoi rimuovere anche le dipendenze di pacchetto (build-essential, cmake, libvulkan-dev, ecc.) installate per questo progetto?" 12 70; then
            remove_deps=1
        fi

        log_info "Ambiente disinstallato completamente."

        # 4. Esecuzione purge APT solo dopo la chiusura di whiptail
        if [[ $remove_deps -eq 1 ]]; then
            log_info "Rimozione pacchetti APT di sviluppo..."
            apt-get purge -y "${DEP_PACKAGES[@]}" || true
            apt-get autoremove --purge -y
            apt-get clean -y
        fi

        echo -e "${GREEN}Disinstallazione e pulizia completate con successo.${NC}"
        exit 0
    fi
}

# ------------------------------------------------------------------------------
# Menu Principale TUI
# ------------------------------------------------------------------------------
main_menu() {
    while true; do
        local choice
        choice=$(whiptail --title "Homelab AI - AMD Management Console" \
            --menu "\nAmbiente Rilevato: $(detect_environment)\nScegli un'operazione:" 21 78 9 \
            "1" "Verifica Stato Hardware e Servizi" \
            "2" "Seleziona/Compila Backend (ROCm / Vulkan)" \
            "3" "Gestisci Servizio Systemd (Personalizza/Monitora)" \
            "4" "Configura Nodo SSH Sandbox" \
            "5" "Aggiorna Componenti (llama.cpp)" \
            "6" "Visualizza Log di Sistema" \
            "7" "Pulizia Cache e File Temporanei" \
            "8" "Disinstalla Ambiente e Dipendenze" \
            "9" "Esci" \
            3>&1 1>&2 2>&3)

        case "$choice" in
            1) check_hardware_status ;;
            2) select_backend ;;
            3) manage_service_menu ;;
            4) setup_sandbox_ssh ;;
            5) update_components ;;
            6) clear; tail -n 50 "${LOG_FILE}"; read -rp "Premere invio per tornare al menu..." ;;
            7) clean_system_cache ;;
            8) uninstall_environment ;;
            9) echo -e "${GREEN}Uscita.${NC}"; break ;;
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
