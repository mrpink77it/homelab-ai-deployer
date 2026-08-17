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

AUTO_MODE=false

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
    if [[ "${AUTO_MODE}" == "true" ]]; then
        echo -e "${C_DIM}[AUTO] Proseguimento automatico in corso...${C_RESET}"
        sleep 1.5
    else
        read -rp $'Premere [INVIO] per continuare...'
    fi
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
        lm-sensors \
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
        pause
        return 0
    else
        log_err "Compilazione fallita. Verifica i log sopra indicati."
        pause
        return 1
    fi
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
    return 0
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
ExecStart=${LLAMA_DIR}/build/bin/llama-server --host 0.0.0.0 --port 8080 -c ${OPTIMIZED_CTX} -b ${OPTIMIZED_BATCH} --threads ${OPTIMIZED_THREADS}
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
}

# ------------------------------------------------------------------------------
# Configurazione Iniziale Servizi Systemd
# ------------------------------------------------------------------------------
setup_systemd_services() {
    if [[ ! -f "${LLAMA_DIR}/build/bin/llama-server" ]]; then
        log_err "Binario llama-server non trovato! Compila prima llama.cpp dall'opzione 1."
        pause
        return 1
    fi

    if [[ ! -f "${WEBUI_VENV}/bin/open-webui" ]]; then
        log_err "Open WebUI non installato! Esegui prima l'opzione 2."
        pause
        return 2
    fi

    apply_systemd_config
    pause
    return 0
}

# ------------------------------------------------------------------------------
# Auto-Tuning Hardware & Riconfigurazione Servizi
# ------------------------------------------------------------------------------
run_autotune() {
    if [[ ! -f /etc/systemd/system/llama-server.service ]]; then
        log_err "I servizi systemd non sono ancora stati configurati. Esegui prima l'opzione 3."
        pause
        return 1
    fi

    log_info "Avvio procedura di Auto-Tuning per modifiche hardware..."
    apply_systemd_config
    log_info "Auto-Tuning completato! Il motore si è adattato alla nuova configurazione."
    pause
    return 0
}

# ------------------------------------------------------------------------------
# Benchmark Prestazioni CPU
# ------------------------------------------------------------------------------
run_benchmark() {
    mkdir -p "${MODELS_DIR}"

    if [[ ! -f "${LLAMA_DIR}/build/bin/llama-bench" ]]; then
        log_err "Binario llama-bench non trovato. Esegui prima la compilazione (Opzione 1)."
        pause
        return 1
    fi

    local model_file
    model_file=$(find "${MODELS_DIR}" -name "*.gguf" 2>/dev/null | head -n 1 || true)

    if [[ -z "${model_file}" ]]; then
        log_warn "Nessun modello .gguf trovato in ${MODELS_DIR}."
        
        local download_confirm=0
        if [[ "${AUTO_MODE}" == "true" ]]; then
            log_info "Modalità Automatica: Download automatico modello di benchmark..."
            download_confirm=0
        else
            whiptail --title "Download Modello Benchmark" --yesno "Nessun file .gguf trovato in ${MODELS_DIR}.\n\nVuoi scaricare un modello di test leggero (Qwen2.5-0.5B ~390MB) per eseguire il benchmark della CPU?" 10 75 || download_confirm=1
        fi

        if [[ $download_confirm -eq 0 ]]; then
            log_info "Download del modello di test Qwen2.5-0.5B-Instruct-Q4_K_M.gguf..."
            wget -c "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf" -O "${MODELS_DIR}/qwen2.5-0.5b-instruct-q4_k_m.gguf"
            model_file="${MODELS_DIR}/qwen2.5-0.5b-instruct-q4_k_m.gguf"
        else
            log_err "Esecuzione annullata: llama-bench richiede un file .gguf valido."
            pause
            return 2
        fi
    fi

    generate_hardware_profile

    log_info "Avvio benchmark CPU con il modello: $(basename "${model_file}")"
    echo -e "${C_CYAN}Thread allocati: ${OPTIMIZED_THREADS}${C_RESET}\n"
    
    "${LLAMA_DIR}/build/bin/llama-bench" -m "${model_file}" -t "${OPTIMIZED_THREADS}"
    pause
    return 0
}

# ------------------------------------------------------------------------------
# Esecuzione Pipeline Automatica (Passi 1 -> 5 Non-Interattiva)
# ------------------------------------------------------------------------------
run_all_automated() {
    AUTO_MODE=true
    clear
    echo -e "${C_CYAN}${C_BOLD}"
    echo "================================================================================"
    echo "         HOMELAB AI DEPLOYER — EXPRESS AUTOMATED DEPLOYMENT (CPU)               "
    echo "================================================================================"
    echo -e "${C_RESET}"
    log_info "Avvio della pipeline automatizzata senza interruzione utente..."

    log_info "[FASE 1/5] Compilazione C++ di llama.cpp..."
    build_llama_cpp

    log_info "[FASE 2/5] Installazione Open WebUI in Virtualenv..."
    install_open_webui

    log_info "[FASE 3/5] Setup Servizi Systemd e Auto-Tuning Hardware..."
    setup_systemd_services

    log_info "[FASE 4/5] Riconfigurazione ed Auto-Tuning Finale..."
    run_autotune

    log_info "[FASE 5/5] Esecuzione Benchmark Prestazionale..."
    run_benchmark

    log_info "Deploy automatico completato con successo!"
    sleep 2
    show_exit_summary
    exit 0
}

# ------------------------------------------------------------------------------
# Dashboard Ultra-Compatta a Schermata Singola (Single-Screen / No-Scroll)
# ------------------------------------------------------------------------------
show_exit_summary() {
    clear
    detect_os

    local primary_ip
    primary_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")

    local virt_type cpu_model phys_cores log_cores load_avg
    virt_type=$(systemd-detect-virt 2>/dev/null || echo "Bare-Metal")
    cpu_model=$(lscpu 2>/dev/null | grep "Model name:" | sed 's/Model name:\s*//' | head -n1 | sed 's/Intel(R) Core(TM) //g; s/CPU @ //g; s/  */ /g')
    [[ -z "${cpu_model}" ]] && cpu_model="x86_64 CPU"
    phys_cores=$(lscpu -p=CORE 2>/dev/null | grep -v '^#' | sort -u | wc -l)
    [[ "${phys_cores}" -eq 0 ]] && phys_cores=$(nproc)
    log_cores=$(nproc)
    load_avg=$(uptime | awk -F'load average:' '{ print $2 }' | sed 's/^ //' | tr -d ' ')

    local ram_used ram_tot ram_pct disk_info
    ram_used=$(free -h | awk '/^Mem:/{print $3}')
    ram_tot=$(free -h | awk '/^Mem:/{print $2}')
    ram_pct=$(free | awk '/^Mem:/{printf "%.1f%%", $3/$2*100}')
    disk_info=$(df -h "${INSTALL_DIR}" 2>/dev/null | awk 'NR==2{printf "%s usati / %s tot (%s)", $3, $2, $5}')

    local cpu_temps="" fan_speeds=""
    if command -v sensors >/dev/null 2>&1; then
        local pkg_t core_t
        pkg_t=$(sensors 2>/dev/null | grep -iE 'Package|Tdie|temp1' | head -n1 | awk '{print $2}' | tr -d '+')
        core_t=$(sensors 2>/dev/null | grep -i 'Core' | awk '{print $3}' | tr -d '+' | tr '\n' ' ')
        
        if [[ -n "${pkg_t}" ]]; then
            cpu_temps="Package: ${pkg_t}"
            [[ -n "${core_t}" ]] && cpu_temps="${cpu_temps} | Core: [ ${core_t}]"
        elif [[ -n "${core_t}" ]]; then
            cpu_temps="Core: [ ${core_t}]"
        fi

        fan_speeds=$(sensors 2>/dev/null | grep -iE 'fan[0-9]*:' | awk '{print $1 " " $2 " " $3}' | tr '\n' ' | ' | sed 's/ | $//')
    fi

    if [[ -z "${cpu_temps}" ]] && [[ -d /sys/class/thermal ]]; then
        local tz_list=""
        for zone in /sys/class/thermal/thermal_zone*/temp; do
            if [[ -f "$zone" ]]; then
                local raw_t
                raw_t=$(cat "$zone" 2>/dev/null || echo 0)
                [[ "$raw_t" -gt 0 ]] && tz_list="${tz_list}$((raw_t / 1000))°C "
            fi
        done
        [[ -n "${tz_list}" ]] && cpu_temps="Thermal Zones: ${tz_list}"
    fi

    [[ -z "${cpu_temps}" ]] && cpu_temps="N/D (LXC/VM senza pass-through)"
    [[ -z "${fan_speeds}" ]] && fan_speeds="N/D (Gestite da Host BIOS)"

    local models_summary=""
    if [[ -d "${MODELS_DIR}" ]]; then
        models_summary=$(find "${MODELS_DIR}" -name "*.gguf" -exec ls -lh {} \; 2>/dev/null | awk '{print $9 " (" $5 ")"}' | sed "s|${MODELS_DIR}/||g" | tr '\n' ', ' | sed 's/, $//')
        [[ -z "${models_summary}" ]] && models_summary="Nessun modello .gguf presente"
    else
        models_summary="Directory non trovata"
    fi

    local llama_st webui_st llama_fmt webui_fmt
    llama_st=$(systemctl is-active llama-server 2>/dev/null || echo "inattivo")
    webui_st=$(systemctl is-active open-webui 2>/dev/null || echo "inattivo")

    [[ "$llama_st" == "active" ]] && llama_fmt="${C_GREEN}● ONLINE${C_RESET}" || llama_fmt="${C_RED}○ OFFLINE${C_RESET}"
    [[ "$webui_st" == "active" ]] && webui_fmt="${C_GREEN}● ONLINE${C_RESET}" || webui_fmt="${C_RED}○ OFFLINE${C_RESET}"

    echo -e "${C_CYAN}┌──────────────────────────────────────────────────────────────────────────────┐${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET} ${C_BOLD}HOMELAB AI DEPLOYER — DASHBOARD NODO INFERENZA CPU${C_RESET}                       ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}├──────────────────────────────────────────────────────────────────────────────┤${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET} ${C_GREEN}${C_BOLD}SYSTEM & HARDWARE${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET}  • OS / Virt   : ${OS_NAME} [Virtualizzazione: ${virt_type}]"
    echo -e "${C_CYAN}│${C_RESET}  • CPU / Load  : ${cpu_model} (${phys_cores}C/${log_cores}T) — Load: ${load_avg}"
    echo -e "${C_CYAN}│${C_RESET}  • RAM / Disk  : RAM: ${ram_used} / ${ram_tot} (${ram_pct}) | Storage: ${disk_info}"
    echo -e "${C_CYAN}├──────────────────────────────────────────────────────────────────────────────┤${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET} ${C_GREEN}${C_BOLD}SENSORI, TEMPERATURE & VENTOLE${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET}  • Temperature : ${cpu_temps}"
    echo -e "${C_CYAN}│${C_RESET}  • Ventole     : ${fan_speeds}"
    echo -e "${C_CYAN}├──────────────────────────────────────────────────────────────────────────────┤${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET} ${C_GREEN}${C_BOLD}MODELLI AI (GGUF)${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET}  • Modelli     : ${models_summary}"
    echo -e "${C_CYAN}├──────────────────────────────────────────────────────────────────────────────┤${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET} ${C_GREEN}${C_BOLD}SERVIZI & ENDPOINT DI CONNESIONE${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET}  • Llama.cpp   : [${llama_fmt}] http://${primary_ip}:8080 (API OpenAI /v1)"
    echo -e "${C_CYAN}│${C_RESET}  • Open WebUI  : [${webui_fmt}] http://${primary_ip}:8081 (Interfaccia Web)"
    echo -e "${C_CYAN}└──────────────────────────────────────────────────────────────────────────────┘${C_RESET}"
    echo -e " ${C_DIM}Sessione terminata. Per riaprire il manager esegui: ./manager-cpu.sh${C_RESET}\n"
}

# ------------------------------------------------------------------------------
# Wizard di Benvenuto & Presentazione Architettura (2 Pagine Terminale)
# ------------------------------------------------------------------------------
welcome_wizard() {
    detect_os
    
    # PAGINA 1: ASCII Art & Panoramica Architetturale
    clear
    echo -e "${C_CYAN}${C_BOLD}"
    echo "┌──────────────────────────────────────────────────────────────────────────────┐"
    echo "│   _  _  ___  __  ____  __    __   ____    ____  ____  ____  __    ___  _  _   │"
    echo "│  ( \/ )/ __)/  \(  _ \(  )  / _\ (  _ \  (  _ \(  __)(  _ \(  )  / __)( \/ )  │"
    echo "│   )  /( (__ (  O ))   // (_/\ /    \ ) __/   ) __/ ) _)  ) __/ (_/\( (__  )  (   │"
    echo "│  (_/\_)\___)\__/(_)\_)\____/\_/\_/ (__)    (__)  (____)(__)  \____/\___)(_/\_)│"
    echo "└──────────────────────────────────────────────────────────────────────────────┘${C_RESET}"
    echo -e "${C_BOLD}     BENVERNUTO IN HOMELAB AI DEPLOYER — NODE INFERENCE CONTROLLER (CPU)${C_RESET}\n"
    
    echo -e "${C_GREEN}${C_BOLD}► PANORAMICA & SCOPO DELLO SCRIPT${C_RESET}"
    echo -e "  Questo script gestisce il deploy nativo (bare-metal o LXC Proxmox) di uno stack"
    echo -e "  completo per l'inferenza di modelli LLM sfruttando esclusivamente la CPU host.\n"
    
    echo -e "${C_GREEN}${C_BOLD}► ARCHITETTURA DI BASE${C_RESET}"
    echo -e "  • ${C_BOLD}Engine di Inferenza${C_RESET} : Compilazione nativa C++ di ${C_CYAN}llama.cpp${C_RESET} con supporto"
    echo -e "                         OpenMP, OpenBLAS e vettorizzazione nativa (AVX2/AVX-512)."
    echo -e "  • ${C_BOLD}Interfaccia Utente${C_RESET}  : ${C_CYAN}Open WebUI${C_RESET} isolato in Python Virtualenv dedicato."
    echo -e "  • ${C_BOLD}Orchestratore${C_RESET}       : Unità Systemd con riavvio automatico e tuning dinamico."
    echo ""
    read -rp $'Premere [INVIO] per la Pagina 2 (Porte, Directory e Modalità)...'

    # PAGINA 2: Directory, Porte & Scelta Modalità
    clear
    echo -e "${C_CYAN}${C_BOLD}"
    echo "┌──────────────────────────────────────────────────────────────────────────────┐"
    echo "│             HOMELAB AI DEPLOYER — SPECIFICHE RETE & LAYOUT STORAGE           │"
    echo "└──────────────────────────────────────────────────────────────────────────────┘${C_RESET}\n"

    echo -e "${C_GREEN}${C_BOLD}► STRUTTURA DIRECTORY & FILESYSTEM${C_RESET}"
    echo -e "  • Root Installazione : ${C_CYAN}/opt/homelab-ai${C_RESET}"
    echo -e "  • Cartella Modelli   : ${C_CYAN}/opt/homelab-ai/models${C_RESET} (Inserisci qui i file .gguf)"
    echo -e "  • Ambiente Python    : ${C_CYAN}/opt/homelab-ai/openwebui_env${C_RESET}"
    echo -e "  • Sorgenti Engine    : ${C_CYAN}/opt/homelab-ai/llama.cpp${C_RESET}\n"

    echo -e "${C_GREEN}${C_BOLD}► SCHEMATICA PORTE E PROTOCOLLI${C_RESET}"
    echo -e "  • ${C_BOLD}Porta HTTP 8080${C_RESET}     : Llama-Server (API REST compatibili OpenAI /v1)"
    echo -e "  • ${C_BOLD}Porta HTTP 8081${C_RESET}     : Open WebUI (GUI Web di chat ed amministrazione)\n"

    echo -e "${C_GREEN}${C_BOLD}► REGOLE AUTO-TUNING DEDICATO${C_RESET}"
    echo -e "  Calcolo automatico dei thread sui Core Fisici della CPU (escludendo HT logici)"
    echo -e "  e dimensionamento dinamico della Context Window (2K/4K/8K) in base alla RAM."
    echo -e "\n================================================================================"

    # Scelta della Modalità di Esecuzione
    if command -v whiptail >/dev/null 2>&1; then
        local mode
        mode=$(whiptail --title "Modalità di Installazione" \
            --menu "\nCome desideri procedere?" 14 75 2 \
            "AUTO" "Express Auto-Deploy (Passi 1->5 automatici senza prompt)" \
            "MENU" "Menu Interattivo Manuale (Seleziona le opzioni passo-passo)" \
            3>&1 1>&2 2>&3) || exit 0

        if [[ "$mode" == "AUTO" ]]; then
            run_all_automated
        fi
    else
        echo -e "${C_BOLD}Seleziona la modalità di avvio:${C_RESET}"
        echo -e "  ${C_CYAN}[1]${C_RESET} Express Auto-Deploy (Passi 1->5 automatici senza prompt)"
        echo -e "  ${C_CYAN}[2]${C_RESET} Menu Interattivo Manuale (Seleziona le opzioni una per una)"
        read -rp "Scelta [1/2]: " mode_choice
        if [[ "$mode_choice" == "1" ]]; then
            run_all_automated
        fi
    fi
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
    local default_choice="1"

    while true; do
        render_header
        
        local choice
        choice=$(whiptail --title "Homelab AI Deployer - Controller CPU" \
            --default-item "${default_choice}" \
            --menu "\nSeleziona l'azione da eseguire sul nodo CPU:" 20 78 7 \
            "A" "EXPRESS AUTO-DEPLOY (Passi 1->5 automatici senza prompt)" \
            "1" "Compila llama.cpp (AVX2/AVX-512 + OpenMP native build)" \
            "2" "Installa Open WebUI (Virtualenv dedicato)" \
            "3" "Configura e Avvia Servizi Systemd (Setup Iniziale)" \
            "4" "Auto-Tuning Hardware (Rileva modifiche HW & Riavvia)" \
            "5" "Esegui Benchmark Rapido CPU (llama-bench)" \
            "0" "Esci dal Manager e Mostra Dashboard Sistema" \
            3>&1 1>&2 2>&3) || { show_exit_summary; exit 0; }

        case "$choice" in
            A|a)
                run_all_automated
                ;;
            1) 
                if build_llama_cpp; then
                    default_choice="2"
                fi
                ;;
            2) 
                if install_open_webui; then
                    default_choice="3"
                fi
                ;;
            3) 
                if setup_systemd_services; then
                    default_choice="4"
                else
                    local res=$?
                    if [[ $res -eq 1 ]]; then
                        default_choice="1"
                    elif [[ $res -eq 2 ]]; then
                        default_choice="2"
                    fi
                fi
                ;;
            4) 
                if run_autotune; then
                    default_choice="5"
                else
                    default_choice="3"
                fi
                ;;
            5) 
                if run_benchmark; then
                    default_choice="0"
                else
                    local res=$?
                    if [[ $res -eq 1 ]]; then
                        default_choice="1"
                    fi
                fi
                ;;
            0) 
                show_exit_summary
                exit 0
                ;;
            *) 
                show_exit_summary
                exit 0 
                ;;
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

welcome_wizard
main_menu
