#!/usr/bin/env bash
# ==============================================================================
# Script: manager-amd.sh
# Versione: 1.0.4
# Descrizione: Gestore deployment per GPU AMD (Stile TUI Unificato con Back Routing)
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configurazione Variabili Globali
# ------------------------------------------------------------------------------
VERSION="1.0.4"
INSTALL_DIR="/opt/homelab-ai"
MODELS_DIR="${INSTALL_DIR}/models"
BACKEND_DIR="${INSTALL_DIR}/backend"
FRONTEND_DIR="${INSTALL_DIR}/frontend"

C_RESET='\033[0m'
C_BOLD='\033[1m'
C_CYAN='\033[1;36m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'

AMD_MODE="ROCm" # Default che verrà sovrascritto dal menu iniziale

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
    mkdir -p "${MODELS_DIR}" "${BACKEND_DIR}" "${FRONTEND_DIR}"
}

# ------------------------------------------------------------------------------
# Scelta Iniziale Driver AMD
# ------------------------------------------------------------------------------
choose_amd_mode() {
    if ! command -v whiptail &> /dev/null; then
        apt-get update -qq && apt-get install -y whiptail
    fi

    local choice
    choice=$(whiptail --title "Homelab AI Deployer - Setup AMD" \
        --menu "\nSeleziona il tipo di driver/backend GPU da configurare:" 17 75 5 \
        "1" "Vulkan (Compatibilità universale su tutte le schede AMD)" \
        "2" "ROCm (Supportato ufficialmente - RX 6000/7000, Instinct)" \
        "3" "ROCm (Experimental - Forzato su GPU non supportate)" \
        "0" "Indietro al Menu Principale (main.sh)" \
        3>&1 1>&2 2>&3) || return 1

    case "$choice" in
        1) AMD_MODE="Vulkan" ;;
        2) AMD_MODE="ROCm" ;;
        3) AMD_MODE="ROCm-Experimental" ;;
        0) return 1 ;;
    esac
    return 0
}

# ------------------------------------------------------------------------------
# Funzioni Core
# ------------------------------------------------------------------------------
install_backend() {
    echo -e "${C_CYAN}>>> Installazione Backend (llama.cpp - Modalità: ${AMD_MODE})...${C_RESET}"
    setup_directories
    cd "${BACKEND_DIR}"
    
    LATEST_RELEASE=$(curl -s https://api.github.com/repos/ggerganov/llama.cpp/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    local target_bin="ubuntu-x64-rocm"
    if [[ "$AMD_MODE" == "Vulkan" ]]; then
        target_bin="ubuntu-x64-vulkan"
    fi

    DOWNLOAD_URL="https://github.com/ggerganov/llama.cpp/releases/download/${LATEST_RELEASE}/llama-${LATEST_RELEASE}-bin-${target_bin}.zip"
    
    if curl --output /dev/null --silent --head --fail "$DOWNLOAD_URL"; then
        wget -q --show-progress -O llama-amd.zip "$DOWNLOAD_URL"
        apt-get install -y unzip >/dev/null
        unzip -o llama-amd.zip -d ./ >/dev/null
        rm llama-amd.zip
        find . -name "llama-server" -exec mv {} ./llama-server-amd \;
        chmod +x llama-server-amd
        echo -e "${C_GREEN}Backend ${AMD_MODE} installato con successo.${C_RESET}"
    else
        echo -e "${C_RED}Errore: Release ${target_bin} non trovata per la versione ${LATEST_RELEASE}.${C_RESET}"
        sleep 3
    fi
}

install_frontend() {
    echo -e "${C_CYAN}>>> Installazione Open WebUI (Python venv via uv)...${C_RESET}"
    setup_directories
    export PATH="/root/.cargo/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    
    if ! command -v uv &> /dev/null; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi

    cd "${FRONTEND_DIR}"
    uv venv .venv
    VIRTUAL_ENV="${FRONTEND_DIR}/.venv" uv pip install open-webui
    echo -e "${C_GREEN}Frontend installato.${C_RESET}"
}

setup_services() {
    echo -e "${C_CYAN}>>> Configurazione Servizi Systemd...${C_RESET}"
    
    local env_vars=""
    if [[ "$AMD_MODE" == "ROCm-Experimental" ]]; then
        env_vars="Environment=\"HSA_OVERRIDE_GFX_VERSION=10.3.0\""
    fi

    cat <<EOF > /etc/systemd/system/homelab-ai-backend.service
[Unit]
Description=Homelab AI Backend (llama.cpp - AMD)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${BACKEND_DIR}
${env_vars}
ExecStart=${BACKEND_DIR}/llama-server-amd -m ${MODELS_DIR}/model.gguf --host 127.0.0.1 --port 8080 -c 4096 -ngl 99
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
    systemctl restart homelab-ai-backend homelab-ai-frontend
    echo -e "${C_GREEN}Servizi configurati e avviati.${C_RESET}"
    sleep 2
}

download_models_menu() {
    setup_directories
    local m_choice
    m_choice=$(whiptail --title "Download Modelli AMD" \
        --menu "\nSeleziona il modello in base alla VRAM disponibile:" 16 70 5 \
        "1" "[4 GB VRAM] Qwen 2.5 Coder 7B (Q4_K_M)" \
        "2" "[8 GB VRAM] Llama 3.1 8B Instruct (Q8_0)" \
        "3" "[16 GB VRAM] Qwen 2.5 14B Instruct (Q8_0)" \
        "4" "[32 GB VRAM] Llama 3.1 70B Instruct (Q4_K_M)" \
        "0" "Torna indietro" \
        3>&1 1>&2 2>&3) || return

    cd "${MODELS_DIR}"
    local url=""
    case "$m_choice" in
        1) url="https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf" ;;
        2) url="https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q8_0.gguf" ;;
        3) url="https://huggingface.co/Qwen/Qwen2.5-14B-Instruct-GGUF/resolve/main/qwen2.5-14b-instruct-q8_0.gguf" ;;
        4) url="https://huggingface.co/bartowski/Meta-Llama-3.1-70B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-70B-Instruct-Q4_K_M.gguf" ;;
        0) return ;;
    esac

    echo -e "${C_CYAN}Download in corso...${C_RESET}"
    wget --show-progress -O "model.gguf" "$url"
    echo -e "${C_GREEN}Download completato (salvato come model.gguf per autostart).${C_RESET}"
    sleep 2
}

show_hardware_profile() {
    clear
    echo -e "${C_CYAN}=== PROFILO HARDWARE ===${C_RESET}"
    lscpu | grep -E "Model name|Thread\(s\) per core|Core\(s\) per socket"
    free -h
    echo -e "\n${C_CYAN}=== SCHEDA VIDEO AMD ===${C_RESET}"
    lspci | grep -iE 'vga|3d|display' | grep -i amd || echo "Nessuna GPU AMD rilevata su bus PCI"
    echo ""
    read -n 1 -s -r -p "Premi un tasto per continuare..."
}

run_benchmark() {
    clear
    if [[ -f "${BACKEND_DIR}/llama-bench" ]]; then
        echo -e "${C_CYAN}Esecuzione llama-bench su modello caricato...${C_RESET}"
        "${BACKEND_DIR}/llama-bench" -m "${MODELS_DIR}/model.gguf" -ngl 99
    else
        echo -e "${C_RED}Eseguibile llama-bench non trovato. Assicurati di aver installato llama.cpp.${C_RESET}"
    fi
    echo ""
    read -n 1 -s -r -p "Premi un tasto per continuare..."
}

show_dashboard() {
    clear
    
    local ip_addr=$(hostname -I | awk '{print $1}')
    [[ -z "$ip_addr" ]] && ip_addr="127.0.0.1"
    
    local be_status="${C_RED}🔴 INATTIVO (Spento o in Errore)${C_RESET}"
    local fe_status="${C_RED}🔴 INATTIVO (Spento o in Errore)${C_RESET}"
    if systemctl is-active --quiet homelab-ai-backend; then be_status="${C_GREEN}🟢 ATTIVO (In Esecuzione)${C_RESET}"; fi
    if systemctl is-active --quiet homelab-ai-frontend; then fe_status="${C_GREEN}🟢 ATTIVO (In Esecuzione)${C_RESET}"; fi

    local cpu_info=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed -e 's/^[ \t]*//')
    local cpu_threads=$(nproc)
    local ram_used=$(free -h | awk '/^Mem:/{print $3}')
    local ram_total=$(free -h | awk '/^Mem:/{print $2}')
    local gpu_info=$(lspci | grep -iE 'vga|3d|display' | grep -i amd | cut -d: -f3 | sed 's/^[ \t]*//' | head -n1 || echo "Non Rilevata")
    local kernel_ver=$(uname -r)

    echo -e "${C_CYAN}========================================================================${C_RESET}"
    echo -e " ${C_BOLD}📊 HOMELAB AI - DASHBOARD DI SISTEMA (PROFILO AMD)${C_RESET}"
    echo -e "${C_CYAN}========================================================================${C_RESET}\n"

    echo -e "${C_YELLOW}▶ STATO SERVIZI, PORTE E API${C_RESET}"
    echo -e "  ├─ Backend AI (llama.cpp) : ${be_status}"
    echo -e "  │  ├─ Porta in Ascolto  : 8080 (TCP Locale)"
    echo -e "  │  └─ API Endpoint      : http://127.0.0.1:8080/v1 (Compatibile OpenAI)"
    echo -e "  │"
    echo -e "  └─ Frontend (Open WebUI): ${fe_status}"
    echo -e "     ├─ Porta Esposta     : 3000 (TCP Pubblica)"
    echo -e "     └─ Interfaccia Web   : http://${ip_addr}:3000\n"

    echo -e "${C_YELLOW}▶ RISORSE HARDWARE E DRIVER${C_RESET}"
    echo -e "  ├─ Processore (CPU)     : ${cpu_info} (${cpu_threads} Thread)"
    echo -e "  ├─ Memoria Sistema (RAM): ${ram_used} usati / ${ram_total} totali"
    echo -e "  ├─ Acceleratore GPU     : ${gpu_info}"
    echo -e "  └─ Driver & Toolchain   : amdgpu (Kernel: ${kernel_ver})\n"

    echo -e "${C_CYAN}========================================================================${C_RESET}"
    read -n 1 -s -r -p "Premi un tasto qualsiasi per tornare al menu operativo..."
}

# ------------------------------------------------------------------------------
# Menu Principale TUI
# ------------------------------------------------------------------------------
main_menu() {
    while true; do
        local choice
        choice=$(whiptail --title "Homelab AI Deployer - Manager AMD (v${VERSION})" \
            --menu "\nSeleziona un'operazione [Modo Attuale: ${AMD_MODE}]:" 18 75 9 \
            "A" "Express Auto-Deploy (Pipeline Completa)" \
            "1" "Installa llama.cpp (Vulkan / ROCm)" \
            "2" "Installa Open WebUI (Python venv via uv)" \
            "3" "Configura & Avvia Servizi Systemd" \
            "4" "Mostra Profilo Hardware (CPU & GPU AMD)" \
            "5" "Download & Tuning Modelli AMD (4, 8, 16, 32 GB)" \
            "6" "Esegui Benchmark GPU (llama-bench)" \
            "D" "Mostra Dashboard Sistema" \
            "0" "Indietro (Cambia Modalità GPU)" \
            3>&1 1>&2 2>&3) || return 0

        case "$choice" in
            A)
                install_backend
                download_models_menu
                install_frontend
                setup_services
                whiptail --title "Completato" --msgbox "Pipeline completa eseguita." 8 40
                ;;
            1) install_backend ;;
            2) install_frontend ;;
            3) setup_services ;;
            4) show_hardware_profile ;;
            5) download_models_menu ;;
            6) run_benchmark ;;
            D) show_dashboard ;;
            0) return 0 ;; # Esce dalla funzione e torna al loop per la scelta GPU
        esac
    done
}

# ------------------------------------------------------------------------------
# Entrypoint
# ------------------------------------------------------------------------------
check_root

# Loop principale per permettere la navigazione fluida avanti e indietro
while true; do
    # Se l'utente preme Esc o seleziona 0 in choose_amd_mode, torna al main
    if ! choose_amd_mode; then
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [[ -f "${SCRIPT_DIR}/main.sh" ]]; then
            # Rilancia il menu principale sostituendo il processo corrente
            exec "${SCRIPT_DIR}/main.sh"
        else
            echo -e "${C_RED}[ERRORE] File main.sh non trovato in ${SCRIPT_DIR}. Uscita.${C_RESET}"
            exit 0
        fi
    fi
    
    # Se choose_amd_mode va a buon fine, lancia il menu operativo
    # Se l'utente preme 0 nel main_menu, uscirà e ripartirà il while,
    # chiedendo nuovamente quale GPU (Vulkan, ROCm, ecc.) usare.
    main_menu
done
