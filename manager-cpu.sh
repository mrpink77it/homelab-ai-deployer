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
# Rilevamento Dinamico OS
# ------------------------------------------------------------------------------
detect_os() {
    OS_NAME="Linux Generico"
    if [[ -f /etc/os-release ]]; then
        OS_NAME=$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
    fi
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

    mkdir -p "${INSTALL_DIR}"
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
# Configurazione Servizi Systemd (Auto-start)
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

    log_info "Creazione servizio systemd: llama-server.service..."
    cat <<EOF > /etc/systemd/system/llama-server.service
[Unit]
Description=Llama.cpp HTTP Server (CPU Mode)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${LLAMA_DIR}
ExecStart=${LLAMA_DIR}/build/bin/llama-server --host 127.0.0.1 --port 8080 -c 4096 --threads $(nproc)
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    log_info "Creazione servizio systemd: open-webui.service..."
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

    systemctl daemon-reload
    systemctl enable llama-server open-webui
    systemctl restart llama-server open-webui

    log_info "Servizi abilitati ed avviati con successo!"
    log_info "▸ Llama.cpp API Server : http://127.0.0.1:8080"
    log_info "▸ Open WebUI Interface: http://$(hostname -I | awk '{print $1}'):8081"
    pause
}

# ------------------------------------------------------------------------------
# Menu TUI del Controller CPU
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
    while true; do
        render_header
        
        local choice
        choice=$(whiptail --title "Homelab AI Deployer - Controller CPU" \
            --menu "\nSeleziona l'azione da eseguire sul nodo CPU:" 18 78 5 \
            "1" "Compila llama.cpp (AVX2/AVX-512 + OpenMP native build)" \
            "2" "Installa Open WebUI (Virtualenv dedicato)" \
            "3" "Configura e Avvia Servizi Systemd (Auto-Start)" \
            "4" "Esegui Benchmark Rapido CPU (llama-bench)" \
            "0" "Torna al Menu Principale (main.sh)" \
            3>&1 1>&2 2>&3) || exit 0

        case "$choice" in
            1) build_llama_cpp ;;
            2) install_open_webui ;;
            3) setup_systemd_services ;;
            4) 
                if [[ -f "${LLAMA_DIR}/build/bin/llama-bench" ]]; then
                    "${LLAMA_DIR}/build/bin/llama-bench" -t "$(nproc)"
                else
                    log_err "Binario llama-bench non trovato. Esegui prima la compilazione (Opzione 1)."
                fi
                pause
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
