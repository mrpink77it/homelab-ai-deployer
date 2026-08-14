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

# ------------------------------------------------------------------------------
# Pacchetti di Sistema Essenziali (Supporto Integrato: Imaging, Audio, Video, RAG)
# ------------------------------------------------------------------------------
DEP_PACKAGES=(
    # --- Utility di Sistema & Build Tool ---
    build-essential
    cmake
    git
    curl
    wget
    pkg-config
    ca-certificates
    htop
    whiptail
    openssh-server
    pciutils
    clinfo

    # --- Python 3.12+ Stack & Header Dev (PEP 668 Compliant) ---
    python3
    python3-pip
    python3-venv
    python3-dev
    python3-full
    libsqlite3-dev
    libssl-dev
    libffi-dev

    # --- Tool e Header Grafici GPU AMD (Vulkan) ---
    libvulkan-dev
    vulkan-tools
    glslc
    libshaderc-dev
    glslang-tools

    # --- Audio, Speech (STT/Whisper), TTS & Talk Mode ---
    portaudio19-dev
    libasound2-dev
    libsndfile1-dev
    flac
    espeak-ng

    # --- Video & Multimedialità ---
    ffmpeg
    libavcodec-extra

    # --- Imaging, Vision & OCR ---
    libpng-dev
    libjpeg-dev
    libwebp-dev
    libtiff-dev
    tesseract-ocr
    tesseract-ocr-ita

    # --- Web Search, Scraping & RAG Parsing ---
    libxml2-dev
    libxslt1-dev
    zlib1g-dev
)

# Colori TUI
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

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
    mkdir -p "${WEBUI_DATA_DIR}"
    touch "${LOG_FILE}"
}

# ------------------------------------------------------------------------------
# Installazione Dipendenze
# ------------------------------------------------------------------------------
install_dependencies() {
    log_info "Verifica e installazione pacchetti di sistema e librerie multimediali..."
    apt-get update -qq
    apt-get install -y -qq "${DEP_PACKAGES[@]}"
    log_info "Dipendenze di sistema installate correttamente."
}

# ------------------------------------------------------------------------------
# Configurazione e Avvio Systemd Backend (llama.cpp)
# ------------------------------------------------------------------------------
auto_setup_systemd_service() {
    local backend_type="${1:-vulkan}"
    log_info "Configurazione ed abilitazione automatica del servizio Systemd Backend (${SERVICE_NAME})..."

    local host="0.0.0.0"
    local port="8080"
    local model_path="${MODELS_DIR}/model.gguf"
    local extra_args="-ngl 99 -c 2048"

    local env_override=""
    if [[ "${backend_type}" == "rocm_exp" ]]; then
        env_override="Environment=\"HSA_OVERRIDE_GFX_VERSION=10.3.0\""
    fi

    cat <<EOF > "${SERVICE_FILE}"
[Unit]
Description=Homelab AI Backend Service (llama.cpp)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
${env_override}
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
    
    log_info "Servizio ${SERVICE_NAME} abilitato al boot e avviato."
}

# ------------------------------------------------------------------------------
# Installazione & Configurazione Open WebUI Bare-Metal
# ------------------------------------------------------------------------------
install_open_webui_baremetal() {
    log_info "Avvio installazione Open WebUI Bare-Metal (Python Virtual Environment)..."

    # 1. Creazione Virtualenv se non presente
    if [[ ! -d "${WEBUI_VENV}" ]]; then
        log_info "Creazione Python Virtual Environment in ${WEBUI_VENV}..."
        python3 -m venv "${WEBUI_VENV}"
    fi

    # 2. Aggiornamento pip, setuptools, wheel e installazione open-webui
    log_info "Aggiornamento pip/setuptools e installazione pacchetto open-webui..."
    "${WEBUI_VENV}/bin/pip" install --upgrade pip setuptools wheel -q
    "${WEBUI_VENV}/bin/pip" install open-webui -q

    log_info "Open WebUI e librerie collegate installate con successo."

    # 3. Creazione Servizio Systemd per Open WebUI con Binding Automatico llama.cpp
    log_info "Configurazione file di servizio Systemd per Open WebUI (${WEBUI_SERVICE_NAME})..."

    cat <<EOF > "${WEBUI_SERVICE_FILE}"
[Unit]
Description=Homelab AI Open WebUI Service (Bare-Metal)
After=network.target ${SERVICE_NAME}.service

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
Environment="PORT=3000"
Environment="WEBUI_PORT=3000"
Environment="OPENAI_API_BASE_URL=http://127.0.0.1:8080/v1"
Environment="OPENAI_API_KEY=no-key"
Environment="ENABLE_OLLAMA_API=False"
Environment="DATA_DIR=${WEBUI_DATA_DIR}"
ExecStart=${WEBUI_VENV}/bin/open-webui serve
Restart=always
RestartSec=5
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${WEBUI_SERVICE_NAME}"
    systemctl restart "${WEBUI_SERVICE_NAME}"

    log_info "Servizio Open WebUI configurato ed avviato sulla porta 3000."
    
    whiptail --title "Open WebUI Bare-Metal Installato" --msgbox \
"Open WebUI è stato installato ed avviato con successo!\n\n\
- Interfaccia Web UI : http://0.0.0.0:3000\n\
- Backend Collegato  : http://127.0.0.1:8080/v1 (llama.cpp)\n\
- Feature Attivate   : Sound, Talk, STT/TTS, OCR, Imaging, Video, Web Search\n\
- File Servizio      : ${WEBUI_SERVICE_FILE}\n\
- Cartella Dati      : ${WEBUI_DATA_DIR}" 15 75
}

manage_webui_menu() {
    while true; do
        local webui_status="INATTIVO"
        if systemctl is-active --quiet "${WEBUI_SERVICE_NAME}" 2>/dev/null; then
            webui_status="ATTIVO (Porta 3000)"
        fi

        local choice
        choice=$(whiptail --title "Gestione Open WebUI Bare-Metal" \
            --menu "\nStato attuale Open WebUI: ${webui_status}\n\nScegli un'azione:" 18 78 6 \
            "1" "Installa / Ri-installa Open WebUI Bare-Metal" \
            "2" "Riavvia Servizio Open WebUI" \
            "3" "Arresta Servizio Open WebUI" \
            "4" "Visualizza Stato Dettagliato (systemctl)" \
            "5" "Visualizza Log Open WebUI (journalctl)" \
            "6" "Torna al Menu Principale" \
            3>&1 1>&2 2>&3)

        case "$choice" in
            1) install_open_webui_baremetal ;;
            2) 
                systemctl restart "${WEBUI_SERVICE_NAME}"
                log_info "Servizio ${WEBUI_SERVICE_NAME} riavviato."
                whiptail --msgbox "Servizio Open WebUI riavviato!" 8 45
                ;;
            3) 
                systemctl stop "${WEBUI_SERVICE_NAME}"
                log_info "Servizio ${WEBUI_SERVICE_NAME} arrestato."
                whiptail --msgbox "Servizio Open WebUI arrestato!" 8 45
                ;;
            4) 
                clear
                systemctl status "${WEBUI_SERVICE_NAME}" || true
                read -rp "Premere invio per tornare al menu..."
                ;;
            5) 
                clear
                journalctl -u "${WEBUI_SERVICE_NAME}" -n 100 -f
                ;;
            6) break ;;
            *) break ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Selezione e Compilazione Backend d'Inferenza (ROCm / Vulkan)
# ------------------------------------------------------------------------------
select_backend() {
    local choice
    choice=$(whiptail --title "Selezione Backend Inferenza AMD" \
        --menu "\nSeleziona il backend grafico per la tua GPU AMD:" 18 78 3 \
        "1" "Vulkan (RACCOMANDATO per RX 5700 XT / RDNA1 e iGPU)" \
        "2" "ROCm Sperimentale (HIP con HSA_OVERRIDE_GFX_VERSION=10.3.0)" \
        "3" "ROCm Ufficiale (Radeon Pro / Instinct / RX 6000+)" \
        3>&1 1>&2 2>&3)

    case "$choice" in
        1)
            echo "BACKEND=vulkan" > "${BACKEND_CONF}"
            log_info "Selezionato backend: Vulkan"
            compile_llama "vulkan"
            ;;
        2)
            echo "BACKEND=rocm_experimental" > "${BACKEND_CONF}"
            log_info "Selezionato backend: ROCm Sperimentale"
            compile_llama "rocm_exp"
            ;;
        3)
            echo "BACKEND=rocm_official" > "${BACKEND_CONF}"
            log_info "Selezionato backend: ROCm Ufficiale"
            compile_llama "rocm"
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
            HSA_OVERRIDE_GFX_VERSION=10.3.0 cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" -DGGML_HIPBLAS=ON -DAMDGPU_TARGETS=gfx1030
            HSA_OVERRIDE_GFX_VERSION=10.3.0 cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
            ;;
    esac

    log_info "Compilazione completata con successo in ${LLAMA_DIR}/build"

    # Configurazione e Avvio Automatico del servizio Systemd Backend
    auto_setup_systemd_service "${type}"

    echo -e "\n${BOLD}${GREEN}==============================================================================${NC}"
    echo -e "${BOLD}${GREEN}   COMPILAZIONE E CONFIGURAZIONE SERVIZIO SYSTEMD COMPLETATE${NC}"
    echo -e "${BOLD}${GREEN}==============================================================================${NC}"
    echo -e " ⚙️  ${BOLD}Servizio Backend:${NC}  ${CYAN}${SERVICE_NAME}.service${NC}"
    echo -e " 🚀 ${BOLD}Stato Servizio:${NC}   $(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || echo "Inattivo")"
    echo -e " 🌐 ${BOLD}Endpoint Backend:${NC} http://0.0.0.0:8080"
    echo -e " 📁 ${BOLD}Cartella Modelli:${NC} ${MODELS_DIR}"
    echo -e "${GREEN}------------------------------------------------------------------------------${NC}\n"

    read -rp "Premere [INVIO] per continuare..."
}

# ------------------------------------------------------------------------------
# Gestione Manuale Backend Systemd
# ------------------------------------------------------------------------------
manage_backend_service_menu() {
    while true; do
        local choice
        choice=$(whiptail --title "Gestione Servizio Backend (llama.cpp)" \
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

custom_setup_systemd_service() {
    log_info "Personalizzazione configurazione servizio Backend (${SERVICE_NAME})..."

    if [[ ! -f "${LLAMA_DIR}/build/bin/llama-server" ]]; then
        whiptail --msgbox "Esegui prima la compilazione del backend (Opzione 2)!" 10 60
        return
    fi

    local host port model_path extra_args
    host=$(whiptail --inputbox "Host Bind per il server API:" 10 60 "0.0.0.0" 3>&1 1>&2 2>&3) || return
    port=$(whiptail --inputbox "Porta per il server API:" 10 60 "8080" 3>&1 1>&2 2>&3) || return
    model_path=$(whiptail --inputbox "Percorso al modello (.gguf):" 10 60 "${MODELS_DIR}/model.gguf" 3>&1 1>&2 2>&3) || return
    extra_args=$(whiptail --inputbox "Argomenti extra:" 10 60 "-ngl 99 -c 2048" 3>&1 1>&2 2>&3) || return

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
    whiptail --msgbox "Servizio aggiornato con successo!" 8 50
}

# ------------------------------------------------------------------------------
# Monitoraggio Hardware e Stato Servizi
# ------------------------------------------------------------------------------
check_hardware_status() {
    clear
    echo -e "${BOLD}${CYAN}=== Stato Hardware AMD & Diagnostica Servizi ===${NC}"
    echo -e "Ambiente Rilevato: ${BOLD}$(detect_environment)${NC}\n"

    echo -e "${YELLOW}[Dispositivi PCI AMD]${NC}"
    lspci | grep -iE 'vga|3d|display|amd' || echo "Nessun dispositivo PCI AMD rilevato."
    echo ""

    echo -e "${YELLOW}[Stato Vulkan ICD]${NC}"
    if command -v vulkaninfo &>/dev/null; then
        vulkaninfo --summary 2>/dev/null | grep -iE 'deviceName|driverID|driverName' || echo "Informazioni Vulkan non disponibili."
    else
        echo "vulkan-tools non presente."
    fi
    echo ""

    echo -e "${YELLOW}[Servizio Backend llama.cpp (Porta 8080)]${NC}"
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        echo -e "Stato: ${GREEN}ATTIVO (Running - Abilitato al boot)${NC}"
    else
        echo -e "Stato: ${RED}INATTIVO / NON CONFIGURATO${NC}"
    fi
    echo ""

    echo -e "${YELLOW}[Servizio Open WebUI Bare-Metal (Porta 3000)]${NC}"
    if systemctl is-active --quiet "${WEBUI_SERVICE_NAME}" 2>/dev/null; then
        echo -e "Stato: ${GREEN}ATTIVO (Running - http://0.0.0.0:3000)${NC}"
    else
        echo -e "Stato: ${RED}INATTIVO / NON CONFIGURATO${NC}"
    fi

    echo ""
    read -rp "Premere invio per tornare al menu..."
}

# ------------------------------------------------------------------------------
# Configurazione Sandbox SSH
# ------------------------------------------------------------------------------
setup_sandbox_ssh() {
    log_info "Configurazione accesso Sandbox SSH..."
    local ssh_port
    ssh_port=$(whiptail --inputbox "Inserisci la porta SSH per la Sandbox:" 10 60 "2222" 3>&1 1>&2 2>&3)
    
    if [[ -n "${ssh_port}" ]]; then
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh
        touch /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        log_info "Sandbox SSH registrata su porta ${ssh_port}."
        whiptail --msgbox "Aggiungi la tua chiave pubblica in /root/.ssh/authorized_keys" 10 60
    fi
}

# ------------------------------------------------------------------------------
# Aggiornamento Componenti
# ------------------------------------------------------------------------------
update_components() {
    log_info "Aggiornamento componenti (llama.cpp e Open WebUI)..."
    
    # 1. Ricompilazione llama.cpp
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

    # 2. Aggiornamento Open WebUI
    if [[ -d "${WEBUI_VENV}" ]]; then
        log_info "Aggiornamento pacchetto Open WebUI tramite pip..."
        "${WEBUI_VENV}/bin/pip" install --upgrade open-webui setuptools wheel -q
        systemctl restart "${WEBUI_SERVICE_NAME}" 2>/dev/null || true
    fi

    log_info "Aggiornamento completato."
    whiptail --msgbox "Tutti i componenti sono stati aggiornati!" 10 60
}

# ------------------------------------------------------------------------------
# Pulizia Cache
# ------------------------------------------------------------------------------
clean_system_cache() {
    log_info "Avvio pulizia cache e file temporanei..."
    rm -rf /root/.cache/vulkan /root/.cache/AMD ~/.cache/vulkan ~/.cache/AMD
    rm -rf /tmp/* /var/tmp/*

    if command -v journalctl &>/dev/null; then
        journalctl --vacuum-size=100M || true
    fi

    log_info "Pulizia completata con successo."
    whiptail --msgbox "Cache e file temporanei rimossi!" 10 60
}

# ------------------------------------------------------------------------------
# Disinstallazione Completa
# ------------------------------------------------------------------------------
uninstall_environment() {
    if whiptail --title "Conferma Rimozione Ambiente" --yesno "Sei sicuro di voler rimuovere l'ambiente Homelab AI?\n\n- Arresto e rimozione servizi Systemd (Backend & Open WebUI)\n- Rimozione directory ${INSTALL_DIR}\n- Rimozione file di log e dati Open WebUI\n\nI pacchetti .deb di sistema NON verranno modificati." 14 70; then
        
        log_warn "Avvio disinstallazione dell'ambiente AI..."

        # Rimozione Servizi Systemd
        for svc in "${SERVICE_NAME}" "${WEBUI_SERVICE_NAME}"; do
            systemctl stop "${svc}" 2>/dev/null || true
            systemctl disable "${svc}" 2>/dev/null || true
        done

        rm -f "${SERVICE_FILE}" "${WEBUI_SERVICE_FILE}"
        systemctl daemon-reload

        # Rimozione Directory e Log
        rm -rf "${INSTALL_DIR}"
        rm -rf "${LOG_FILE}"
        rm -rf /root/.cache/vulkan /root/.cache/AMD

        log_info "Disinstallazione completata."
        whiptail --msgbox "Ambiente Homelab AI rimosso con successo!" 10 60
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
            --menu "\nAmbiente: $(detect_environment)\n\nScegli un'operazione:" 22 78 10 \
            "1" "Verifica Stato Hardware e Servizi (Backend & Web UI)" \
            "2" "Seleziona/Compila Backend (Vulkan / ROCm)" \
            "3" "Gestisci Servizio Backend llama.cpp (Porta 8080)" \
            "4" "Gestisci Open WebUI Bare-Metal (Porta 3000)" \
            "5" "Configura Nodo SSH Sandbox" \
            "6" "Aggiorna Componenti (llama.cpp & Open WebUI)" \
            "7" "Visualizza Log di Sistema" \
            "8" "Pulizia Cache e File Temporanei" \
            "9" "Disinstalla Ambiente AI" \
            "10" "Esci" \
            3>&1 1>&2 2>&3)

        case "$choice" in
            1) check_hardware_status ;;
            2) select_backend ;;
            3) manage_backend_service_menu ;;
            4) manage_webui_menu ;;
            5) setup_sandbox_ssh ;;
            6) update_components ;;
            7) clear; tail -n 50 "${LOG_FILE}"; read -rp "Premere invio per tornare al menu..." ;;
            8) clean_system_cache ;;
            9) uninstall_environment ;;
            10) echo -e "${GREEN}Uscita.${NC}"; break ;;
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
