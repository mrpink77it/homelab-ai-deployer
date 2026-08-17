#!/usr/bin/env bash
# ==============================================================================
# Script: manager-cpu.sh (Homelab AI Deployer - CPU Manager)
# Descrizione: Deploy & Management stack AI per nodi solo CPU (llama.cpp + Open WebUI)
# Ambienti: Bare-Metal & LXC Proxmox (Debian 12/13 / Ubuntu 22.04/24.04+)
# Repository: homelab-ai-deployer
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configurazione Ambiente e Layout Colori
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/homelab-ai"
LLAMA_DIR="${INSTALL_DIR}/llama.cpp"
WEBUI_VENV="${INSTALL_DIR}/openwebui_env"
MODELS_DIR="${INSTALL_DIR}/models"

C_RESET='\033[0m'
C_BOLD='\033[1m'
C_CYAN='\033[1;36m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_DIM='\033[2m'

log_info()  { echo -e "${C_GREEN}[INFO]${C_RESET} $1"; }
log_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET} $1"; }
log_err()   { echo -e "${C_RED}[ERRORE]${C_RESET} $1"; }

pause() {
    read -rp $'Premere [INVIO] per continuare...'
}

# ------------------------------------------------------------------------------
# Rilevamento Dinamico OS e Hardware Auto-Tuning
# ------------------------------------------------------------------------------
detect_os() {
    OS_NAME="Linux Generico"
    if [[ -f /etc/os-release ]]; then
        OS_NAME=$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
    fi
}

generate_hardware_profile() {
    log_info "Analisi delle risorse hardware in corso..."

    # 1. Calcolo RAM Totale in GB
    TOTAL_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
    if [[ -z "${TOTAL_RAM_GB}" || "${TOTAL_RAM_GB}" -eq 0 ]]; then
        TOTAL_RAM_GB=4
    fi

    # 2. Calcolo Core Fisici (Escludendo gli Hyper-Thread logici)
    PHYSICAL_CORES=$(lscpu -p=CORE 2>/dev/null | grep -v '^#' | sort -u | wc -l)
    if [[ "${PHYSICAL_CORES}" -eq 0 ]]; then
        PHYSICAL_CORES=$(nproc)
    fi

    # 3. Assegnazione Dinamica Context Size e Batch Size in base alla RAM
    OPTIMIZED_CTX=2048
    OPTIMIZED_BATCH=256

    if [[ "${TOTAL_RAM_GB}" -ge 30 ]]; then
        OPTIMIZED_CTX=8192
        OPTIMIZED_BATCH=1024
    elif [[ "${TOTAL_RAM_GB}" -ge 14 ]]; then
        OPTIMIZED_CTX=4096
        OPTIMIZED_BATCH=512
    fi

    OPTIMIZED_THREADS="${PHYSICAL_CORES}"

    echo -e "${C_CYAN}▸ RAM Rilevata:      ${TOTAL_RAM_GB} GB${C_RESET}"
    echo -e "${C_CYAN}▸ Core Fisici CPU:   ${OPTIMIZED_THREADS}${C_RESET}"
    echo -e "${C_CYAN}▸ Context Window:    ${OPTIMIZED_CTX} token${C_RESET}"
    echo -e "${C_CYAN}▸ Batch Size:        ${OPTIMIZED_BATCH}${C_RESET}"
}

# ------------------------------------------------------------------------------
# Verifica e Installazione Dipendenze di Sistema
# ------------------------------------------------------------------------------
install_system_deps() {
    detect_os
    echo -e "${C_CYAN}❖ Aggiornamento pacchetti e installazione build tools per ${OS_NAME}...${C_RESET}"
    export DEBIAN_FRONTEND=noninteractive
    
    apt-get update -qq
    apt-get install -y -qq \
        build-essential \
        cmake \
        git \
        curl \
        wget \
        pkg-config \
        libopenblas-dev \
        python3 \
        python3-venv \
        python3-dev \
        whiptail >/dev/null 2>&1

    mkdir -p "${INSTALL_DIR}" "${MODELS_DIR}"
    log_info "Dipendenze di sistema installate correttamente su ${OS_NAME}."
}

# ------------------------------------------------------------------------------
# Compilazione llama.cpp (Ottimizzata CPU)
# ------------------------------------------------------------------------------
build_llama_cpp() {
    install_system_deps

    log_info "Clonazione / Aggiornamento repository llama.cpp..."
    if [[ -d "${LLAMA_DIR}" ]]; then
        git -C "${LLAMA_DIR}" pull --quiet
    else
        git clone https://github.com/ggerganov/llama.cpp.git "${LLAMA_DIR}"
    fi

    log_info "Avvio compilazione nativa con ottimizzazioni CPU (OpenMP & Native Vectoring)..."
    
    cd "${LLAMA_DIR}"
    rm -rf build
    cmake -B build -DGGML_NATIVE=ON -DGGML_OPENMP=ON -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS
    cmake --build build --config Release -j"$(nproc)"

    if [[ -f "${LLAMA_DIR}/build/bin/llama-cli" || -f "${LLAMA_DIR}/build/bin/llama-server" ]]; then
        log_info "Compilazione completata con successo! Binari pronti in: ${LLAMA_DIR}/build/bin/"
    else
        log_err "Compilazione fallita. Verifica i log sopra indicati."
    fi
    pause
}

# ------------------------------------------------------------------------------
# Setup Ambiente Virtuale & Open WebUI
# ------------------------------------------------------------------------------
install_open_webui() {
    install_system_deps

    log_info "Configurazione virtualenv dedicato in: ${WEBUI_VENV}"
    if [[ -d "${WEBUI_VENV}" ]]; then
        log_warn "Rilevato ambiente esistente, sovrascrittura in corso..."
        rm -rf "${WEBUI_VENV}"
    fi

    python3 -m venv "${WEBUI_VENV}"
    source "${WEBUI_VENV}/bin/activate"

    pip install --upgrade pip setuptools wheel --quiet
    log_info "Installazione Open WebUI in corso..."
    pip install open-webui --quiet

    deactivate
    log_info "Open WebUI installato con successo nell'ambiente virtuale."
    pause
}

# ------------------------------------------------------------------------------
# Modulo di Applicazione Configurazione Systemd
# ------------------------------------------------------------------------------
apply_systemd_config() {
    log_info "Arresto preventivo dei servizi in corso..."
    systemctl stop llama-server open-webui 2>/dev/null || true

    generate_hardware_profile

    log_info "Generazione/Aggiornamento del servizio: llama-server.service..."
    cat <<EOF > /etc/systemd/system/llama-server.service
[Unit]
Description=Llama.cpp HTTP Server (CPU Mode - Auto Tuned)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${LLAMA_DIR}
ExecStart=${LLAMA_DIR}/build/bin/llama-server --host 127.0.0.1 --port 8080 -c ${OPTIMIZED_CTX} -b ${OPTIMIZED_BATCH} --threads ${OPTIMIZED_THREADS}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    log_info "Generazione/Aggiornamento del servizio: open-webui.service..."
    cat <<EOF > /etc/systemd/system/open-webui.service
[Unit]
Description=Open WebUI Service
After=network.target llama-server.service

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
Environment="OPENAI_API_BASE_URL=http://127.0.0.1:8080/v1"
Environment="OPENAI_API_KEY=sk-no-key-required"
ExecStart=${WEBUI_VENV}/bin/open-webui serve --port 8081
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    log_info "Ricaricamento daemon e avvio dello stack..."
    systemctl daemon-reload
    systemctl enable llama-server open-webui
    systemctl restart llama-server open-webui

    log_info "Servizi configurati ed avviati con successo!"
    log_info "▸ Llama.cpp API Server : http://127.0.0.1:8080"
    log_info "▸ Open WebUI Interface: http://$(hostname -I | awk '{print $1}'):8081"
}

# ------------------------------------------------------------------------------
# Configurazione Iniziale Servizi Systemd
# ------------------------------------------------------------------------------
setup_systemd_services() {
    if [[ ! -f "${LLAMA_DIR}/build/bin/llama-server" ]]; then
        log_err "Binario llama-server non trovato! Compila prima llama.cpp dall'opzione 1."
        pause
        return
    fi

    if [[ ! -f "${WEBUI_VENV}/bin/open-webui" ]]; then
        log_err "Open WebUI non installato! Esegui prima l'opzione 2."
        pause
        return
    fi

    apply_systemd_config
    pause
}

# ------------------------------------------------------------------------------
# Auto-Tuning Hardware & Riconfigurazione Servizi
# ------------------------------------------------------------------------------
run_autotune() {
    if [[ ! -f /etc/systemd/system/llama-server.service ]]; then
        log_err "I servizi systemd non sono ancora stati configurati. Esegui prima l'opzione 3."
        pause
        return
    fi

    log_info "Avvio procedura di Auto-Tuning per modifiche hardware..."
    apply_systemd_config
    log_info "Auto-Tuning completato! Il motore si è adattato alla nuova configurazione."
    pause
}

# ------------------------------------------------------------------------------
# Benchmark Prestazioni CPU
# ------------------------------------------------------------------------------
run_benchmark() {
    mkdir -p "${MODELS_DIR}"

    if [[ ! -f "${LLAMA_DIR}/build/bin/llama-bench" ]]; then
        log_err "Binario llama-bench non trovato. Esegui prima la compilazione (Opzione 1)."
        pause
        return
    fi

    local model_file
    model_file=$(find "${MODELS_DIR}" -name "*.gguf" 2>/dev/null | head -n 1 || true)

    if [[ -z "${model_file}" ]]; then
        log_warn "Nessun modello .gguf trovato in ${MODELS_DIR}."
        if whiptail --title "Download Modello Benchmark" --yesno "Nessun file .gguf trovato in ${MODELS_DIR}.\n\nVuoi scaricare un modello di test leggero (Qwen2.5-0.5B ~390MB) per eseguire il benchmark della CPU?" 10 75; then
            log_info "Download del modello di test Qwen2.5-0.5B-Instruct-Q4_K_M.gguf..."
            wget -c "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf" -O "${MODELS_DIR}/qwen2.5-0.5b-instruct-q4_k_m.gguf"
            model_file="${MODELS_DIR}/qwen2.5-0.5b-instruct-q4_k_m.gguf"
        else
            log_err "Esecuzione annullata: llama-bench richiede un file .gguf valido."
            pause
            return
        fi
    fi

    generate_hardware_profile

    log_info "Avvio benchmark CPU con il modello: $(basename "${model_file}")"
    echo -e "${C_CYAN}Thread allocati: ${OPTIMIZED_THREADS}${C_RESET}\n"
    
    "${LLAMA_DIR}/build/bin/llama-bench" -m "${model_file}" -t "${OPTIMIZED_THREADS}"
    pause
}

# ------------------------------------------------------------------------------
# Menu TUI del Controller CPU con Avanzamento Automatico
# ------------------------------------------------------------------------------
render_header() {
    clear
    detect_os
    echo -e "${C_CYAN}${C_BOLD}"
    echo "┌──────────────────────────────────────────────────────────────────────────────┐"
    echo "│               M A N A G E R   C P U   I N F E R E N C E                      │"
    echo "│                 Homelab AI Deployer - Native Vector Engine                   │"
    echo "└──────────────────────────────────────────────────────────────────────────────┘${C_RESET}"
    echo -e "${C_DIM} Sistema Operativo:${C_RESET} ${C_BOLD}${OS_NAME}${C_RESET}\n"
}

main_menu() {
    local default_choice="1"

    while true; do
        render_header
        
        local choice
        choice=$(whiptail --title "Homelab AI Deployer - Controller CPU" \
            --default-item "${default_choice}" \
            --menu "\nSeleziona l'azione da eseguire sul nodo CPU:" 19 78 6 \
            "1" "Compila llama.cpp (AVX2/AVX-512 + OpenMP native build)" \
            "2" "Installa Open WebUI (Virtualenv dedicato)" \
            "3" "Configura e Avvia Servizi Systemd (Setup Iniziale)" \
            "4" "Auto-Tuning Hardware (Rileva modifiche HW & Riavvia)" \
            "5" "Esegui Benchmark Rapido CPU (llama-bench)" \
            "0" "Torna al Menu Principale (main.sh)" \
            3>&1 1>&2 2>&3) || exit 0

        case "$choice" in
            1) 
                build_llama_cpp 
                default_choice="2"
                ;;
            2) 
                install_open_webui 
                default_choice="3"
                ;;
            3) 
                setup_systemd_services 
                default_choice="4"
                ;;
            4) 
                run_autotune 
                default_choice="5"
                ;;
            5) 
                run_benchmark 
                default_choice="0"
                ;;
            0) 
                exec "${SCRIPT_DIR}/main.sh"
                ;;
            *) exit 0 ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Entrypoint
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    log_err "Il controller richiede i privilegi di root."
    exit 1
fi

main_menu
