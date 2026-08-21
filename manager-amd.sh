#!/usr/bin/env bash
# ==============================================================================
# Script: manager-amd.sh
# Versione: 1.0.2
# Descrizione: Gestore deployment, frontend, servizi systemd e ciclo AI per GPU AMD
# Novità: Implementata Dashboard di stato avanzata (Rete, API, HW, Driver)
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configurazione Variabili Globali
# ------------------------------------------------------------------------------
VERSION="1.0.2"
INSTALL_DIR="/opt/homelab-ai"
MODELS_DIR="${INSTALL_DIR}/models"
BACKEND_DIR="${INSTALL_DIR}/backend"
FRONTEND_DIR="${INSTALL_DIR}/frontend"

# Colori per UI Terminale
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_CYAN='\033[1;36m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'

# ------------------------------------------------------------------------------
# Funzioni di Utilità
# ------------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${C_RED}[ERRORE] Questo script richiede i privilegi di root. Usa sudo.${C_RESET}"
        exit 1
    fi
}

setup_directories() {
    echo -e "${C_CYAN}>>> Creazione struttura directory in ${INSTALL_DIR}...${C_RESET}"
    mkdir -p "${MODELS_DIR}" "${BACKEND_DIR}" "${FRONTEND_DIR}"
}

# ------------------------------------------------------------------------------
# Installazione Componenti (Backend e Frontend)
# ------------------------------------------------------------------------------
install_backend() {
    echo -e "${C_CYAN}>>> Installazione Backend (llama.cpp - Ottimizzazione AMD/ROCm)...${C_RESET}"
    
    cd "${BACKEND_DIR}"
    echo -e "${C_YELLOW}Recupero ultima versione di llama.cpp...${C_RESET}"
    LATEST_RELEASE=$(curl -s https://api.github.com/repos/ggerganov/llama.cpp/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    DOWNLOAD_URL="https://github.com/ggerganov/llama.cpp/releases/download/${LATEST_RELEASE}/llama-${LATEST_RELEASE}-bin-ubuntu-x64-rocm.zip"
    
    if curl --output /dev/null --silent --head --fail "$DOWNLOAD_URL"; then
        echo -e "${C_GREEN}Trovata release ROCm. Download in corso...${C_RESET}"
        wget -q --show-progress -O llama-rocm.zip "$DOWNLOAD_URL"
        apt-get install -y unzip >/dev/null
        unzip -o llama-rocm.zip -d ./ >/dev/null
        rm llama-rocm.zip
        find . -name "llama-server" -exec mv {} ./llama-server-amd \;
        chmod +x llama-server-amd
    else
        echo -e "${C_YELLOW}Release ROCm precompilata non trovata. Verrà scaricata la versione base.${C_RESET}"
        DOWNLOAD_URL_BASE="https://github.com/ggerganov/llama.cpp/releases/download/${LATEST_RELEASE}/llama-${LATEST_RELEASE}-bin-ubuntu-x64.zip"
        wget -q --show-progress -O llama-base.zip "$DOWNLOAD_URL_BASE"
        unzip -o llama-base.zip -d ./ >/dev/null
        rm llama-base.zip
        find . -name "llama-server" -exec mv {} ./llama-server-amd \;
        chmod +x llama-server-amd
    fi
}

download_model() {
    echo -e "${C_CYAN}>>> Download Modello GGUF (Qwen2.5-Coder-7B-Instruct)...${C_RESET}"
    cd "${MODELS_DIR}"
    MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf"
    MODEL_FILE="qwen2.5-coder-7b-instruct-q4_k_m.gguf"

    if [[ -f "$MODEL_FILE" ]]; then
        echo -e "${C_GREEN}Modello già presente: $MODEL_FILE${C_RESET}"
    else
        wget --show-progress -O "$MODEL_FILE" "$MODEL_URL"
    fi
}

install_frontend() {
    echo -e "${C_CYAN}>>> Installazione Open WebUI (Frontend)...${C_RESET}"
    export PATH="/root/.cargo/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    
    if ! command -v uv &> /dev/null; then
        echo -e "${C_YELLOW}Installazione gestore rapido 'uv'...${C_RESET}"
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi

    cd "${FRONTEND_DIR}"
    uv venv .venv
    VIRTUAL_ENV="${FRONTEND_DIR}/.venv" uv pip install open-webui
}

# ------------------------------------------------------------------------------
# Configurazione Servizi Systemd
# ------------------------------------------------------------------------------
setup_services() {
    echo -e "${C_CYAN}>>> Configurazione Servizi Systemd...${C_RESET}"
    
    cat <<EOF > /etc/systemd/system/homelab-ai-backend.service
[Unit]
Description=Homelab AI Backend (llama.cpp - AMD)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${BACKEND_DIR}
Environment="HSA_OVERRIDE_GFX_VERSION=10.3.0"
ExecStart=${BACKEND_DIR}/llama-server-amd -m ${MODELS_DIR}/qwen2.5-coder-7b-instruct-q4_k_m.gguf --host 127.0.0.1 --port 8080 -c 4096 -ngl 99
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    cat <<EOF > /etc/systemd/system/homelab-ai-frontend.service
[Unit]
Description=Homelab AI Frontend (Open WebUI)
After=network.target homelab-ai-backend.service

[Service]
Type=simple
User=root
WorkingDirectory=${FRONTEND_DIR}
Environment="PATH=/root/.cargo/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="OLLAMA_BASE_URL=http://127.0.0.1:8080"
Environment="WEBUI_AUTH=False"
Environment="HOST=0.0.0.0"
Environment="PORT=3000"
ExecStart=${FRONTEND_DIR}/.venv/bin/open-webui serve
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable homelab-ai-backend homelab-ai-frontend
    systemctl start homelab-ai-backend homelab-ai-frontend
}

# ------------------------------------------------------------------------------
# Dashboard Elegante Terminale
# ------------------------------------------------------------------------------
show_dashboard() {
    clear
    
    # Rilevamento IP Rete Locale
    local ip_addr
    ip_addr=$(hostname -I | awk '{print $1}')
    [[ -z "$ip_addr" ]] && ip_addr="127.0.0.1"

    # Controllo stato Servizi Systemd
    local be_status="${C_RED}🔴 INATTIVO (Spento o in Errore)${C_RESET}"
    local fe_status="${C_RED}🔴 INATTIVO (Spento o in Errore)${C_RESET}"
    if systemctl is-active --quiet homelab-ai-backend; then be_status="${C_GREEN}🟢 ATTIVO (In Esecuzione)${C_RESET}"; fi
    if systemctl is-active --quiet homelab-ai-frontend; then fe_status="${C_GREEN}🟢 ATTIVO (In Esecuzione)${C_RESET}"; fi

    # Diagnostica Hardware Base
    local cpu_model=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed -e 's/^[ \t]*//')
    local cpu_cores=$(nproc)
    local ram_total=$(free -h | awk '/^Mem:/{print $2}')
    local ram_used=$(free -h | awk '/^Mem:/{print $3}')

    # Diagnostica AMD GPU e Driver
    local gpu_desc="GPU AMD Non Trovata / Non Rilevata su bus PCI"
    if lspci | grep -iE 'vga|3d|display' | grep -i amd >/dev/null 2>&1; then
        gpu_desc=$(lspci | grep -iE 'vga|3d|display' | grep -i amd | cut -d: -f3 | sed 's/^[ \t]*//' | head -n1)
    fi

    local driver_ver="amdgpu (Kernel: $(uname -r))"
    if command -v rocm-smi >/dev/null 2>&1; then
        local rocm_ver
        rocm_ver=$(apt-cache policy rocm-core 2>/dev/null | grep Installed | awk '{print $2}' || echo "N/D")
        driver_ver="ROCm (Versione: ${rocm_ver}) - Stack Grafico Avanzato"
    fi

    # Renderizzazione Interfaccia
    echo -e "${C_CYAN}========================================================================${C_RESET}"
    echo -e " ${C_BOLD}📊 HOMELAB AI - DASHBOARD DI SISTEMA (PROFILO AMD)${C_RESET}"
    echo -e "${C_CYAN}========================================================================${C_RESET}\n"

    echo -e "${C_YELLOW}▶ STATO SERVIZI, PORTE E API${C_RESET}"
    echo -e "  ├─ ${C_BOLD}Backend AI (llama.cpp)${C_RESET} : ${be_status}"
    echo -e "  │  ├─ Porta in Ascolto  : 8080 (TCP Locale)"
    echo -e "  │  └─ API Endpoint      : http://127.0.0.1:8080/v1 (Compatibile OpenAI)"
    echo -e "  │"
    echo -e "  └─ ${C_BOLD}Frontend (Open WebUI)${C_RESET}: ${fe_status}"
    echo -e "     ├─ Porta Esposta     : 3000 (TCP Pubblica)"
    echo -e "     └─ Interfaccia Web   : http://${ip_addr}:3000\n"

    echo -e "${C_YELLOW}▶ RISORSE HARDWARE E DRIVER${C_RESET}"
    echo -e "  ├─ ${C_BOLD}Processore (CPU)${C_RESET}     : ${cpu_model} (${cpu_cores} Thread)"
    echo -e "  ├─ ${C_BOLD}Memoria Sistema (RAM)${C_RESET}: ${ram_used} usati / ${ram_total} totali"
    echo -e "  ├─ ${C_BOLD}Acceleratore GPU${C_RESET}     : ${gpu_desc}"
    echo -e "  └─ ${C_BOLD}Driver & Toolchain${C_RESET}   : ${driver_ver}\n"

    # Selettore Live VRAM (Se rocm-smi è installato e funzionante)
    if command -v rocm-smi >/dev/null 2>&1; then
        echo -e "${C_YELLOW}▶ UTILIZZO GPU TEMPO REALE (rocm-smi)${C_RESET}"
        rocm-smi --showuse --showmeminfo vram | grep -v '=====================' | grep -v 'ROCm System' | sed 's/^/  /' || true
        echo ""
    fi

    echo -e "${C_CYAN}========================================================================${C_RESET}"
    # Mette in pausa l'esecuzione finché l'utente non preme un tasto
    read -n 1 -s -r -p "Premi un tasto qualsiasi per tornare al menu operativo..."
}

# ------------------------------------------------------------------------------
# Menu Principale TUI
# ------------------------------------------------------------------------------
main_menu() {
    if ! command -v whiptail &> /dev/null; then
        apt-get update -qq && apt-get install -y whiptail
    fi

    local choice
    choice=$(whiptail --title "Homelab AI - Controller AMD (v${VERSION})" \
        --menu "\nSeleziona un'operazione per l'ambiente AMD:" 18 78 6 \
        "1" "▶ Esegui Installazione Completa (Backend + Frontend)" \
        "2" "📊 Dashboard Stato & Risorse (Reti, API, Hardware)" \
        "3" "🔄 Riavvia Servizi Systemd (Applica modifiche)" \
        "4" "📄 Mostra Log Live Backend (llama.cpp)" \
        "5" "📄 Mostra Log Live Frontend (Open WebUI)" \
        "6" "🔙 Esci al Menu Principale (main.sh)" \
        3>&1 1>&2 2>&3) || exit 0

    case "$choice" in
        1)
            setup_directories
            install_backend
            download_model
            install_frontend
            setup_services
            whiptail --title "Completato" --msgbox "Installazione AMD completata con successo!\nAccedi a Open WebUI sulla porta 3000." 8 60
            main_menu
            ;;
        2)
            show_dashboard
            main_menu
            ;;
        3)
            systemctl restart homelab-ai-backend homelab-ai-frontend
            whiptail --title "Riavvio" --msgbox "Servizi riavviati." 8 40
            main_menu
            ;;
        4)
            journalctl -u homelab-ai-backend -f
            ;;
        5)
            journalctl -u homelab-ai-frontend -f
            ;;
        6)
            exit 0
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Entrypoint
# ------------------------------------------------------------------------------
check_root
main_menu
