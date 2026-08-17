#!/usr/bin/env bash
# ==============================================================================
# Script: manager-cpu.sh (Homelab AI Deployer - CPU Manager)
# Descrizione: Deploy & Management stack AI per nodi CPU (llama.cpp + Open WebUI)
# Ambienti: Bare-Metal & LXC Proxmox (Debian 12/13 / Ubuntu 22.04/24.04+)
# Repository: homelab-ai-deployer
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configurazione Ambiente e Stili ANSI (Sobri)
# ------------------------------------------------------------------------------
INSTALL_DIR="/opt/homelab-ai"
LLAMA_DIR="${INSTALL_DIR}/llama.cpp"
WEBUI_VENV="${INSTALL_DIR}/openwebui_env"
MODELS_DIR="${INSTALL_DIR}/models"

AUTO_MODE=false

C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_CYAN=$'\033[36m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'
C_DIM=$'\033[2m'

log_info()  { printf "%s[INFO]%s %s\n" "${C_GREEN}" "${C_RESET}" "$1"; }
log_warn()  { printf "%s[WARN]%s %s\n" "${C_YELLOW}" "${C_RESET}" "$1"; }
log_err()   { printf "%s[ERRORE]%s %s\n" "${C_RED}" "${C_RESET}" "$1"; }

pause() {
    if [[ "${AUTO_MODE}" == "true" ]]; then
        printf "%s[AUTO] Proseguimento automatico in corso...%s\n" "${C_DIM}" "${C_RESET}"
        sleep 1.5
    else
        read -rp $'Premere [INVIO] per continuare...'
    fi
}

# ------------------------------------------------------------------------------
# Dashboard Finale Sobria & Compatta (Registrata con TRAP)
# ------------------------------------------------------------------------------
show_exit_summary() {
    # Disattiva temporaneamente l'uscita su errore per garantire il rendering
    set +e

    clear
    detect_os

    local primary_ip
    primary_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "${primary_ip}" ]] && primary_ip="127.0.0.1"

    local virt_type cpu_model phys_cores log_cores load_avg
    virt_type=$(systemd-detect-virt 2>/dev/null) || virt_type="Bare-Metal"
    cpu_model=$(lscpu 2>/dev/null | grep "Model name:" | sed 's/Model name:\s*//' | head -n1 | sed 's/Intel(R) Core(TM) //g; s/CPU @ //g; s/  */ /g')
    [[ -z "${cpu_model}" ]] && cpu_model="x86_64 CPU"
    phys_cores=$(lscpu -p=CORE 2>/dev/null | grep -v '^#' | sort -u | wc -l)
    [[ "${phys_cores}" -eq 0 ]] && phys_cores=$(nproc 2>/dev/null || echo "1")
    log_cores=$(nproc 2>/dev/null || echo "1")
    load_avg=$(uptime 2>/dev/null | awk -F'load average:' '{ print $2 }' | sed 's/^ //' | tr -d ' ')

    local ram_used ram_tot ram_pct disk_info
    ram_used=$(free -h 2>/dev/null | awk '/^Mem:/{print $3}')
    ram_tot=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')
    ram_pct=$(free 2>/dev/null | awk '/^Mem:/{printf "%.1f%%", $3/$2*100}')
    disk_info=$(df -h "${INSTALL_DIR}" 2>/dev/null | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}')

    local cpu_temps="" fan_speeds=""
    if command -v sensors >/dev/null 2>&1; then
        local pkg_t core_t
        pkg_t=$(sensors 2>/dev/null | grep -iE 'Package|Tdie|temp1' | head -n1 | awk '{print $2}' | tr -d '+')
        core_t=$(sensors 2>/dev/null | grep -i 'Core' | awk '{print $3}' | tr -d '+' | tr '\n' ' ')
        
        if [[ -n "${pkg_t}" ]]; then
            cpu_temps="Pkg: ${pkg_t}"
            [[ -n "${core_t}" ]] && cpu_temps="${cpu_temps} | Cores: [ ${core_t}]"
        elif [[ -n "${core_t}" ]]; then
            cpu_temps="Cores: [ ${core_t}]"
        fi

        fan_speeds=$(sensors 2>/dev/null | grep -iE 'fan[0-9]*:' | awk '{print $1 " " $2 " " $3}' | tr '\n' ' | ' | sed 's/ | $//')
    fi

    [[ -z "${cpu_temps}" ]] && cpu_temps="N/D"
    [[ -z "${fan_speeds}" ]] && fan_speeds="N/D"

    local models_summary
    if [[ -d "${MODELS_DIR}" ]]; then
        models_summary=$(find "${MODELS_DIR}" -name "*.gguf" -exec ls -lh {} \; 2>/dev/null | awk '{print $9 " (" $5 ")"}' | sed "s|${MODELS_DIR}/||g" | tr '\n' ', ' | sed 's/, $//')
        [[ -z "${models_summary}" ]] && models_summary="Nessun modello presente"
    else
        models_summary="N/D"
    fi

    local llama_st webui_st llama_fmt webui_fmt
    llama_st=$(systemctl is-active llama-server 2>/dev/null || echo "inattivo")
    webui_st=$(systemctl is-active open-webui 2>/dev/null || echo "inattivo")

    [[ "$llama_st" == "active" ]] && llama_fmt="${C_GREEN}ONLINE${C_RESET}" || llama_fmt="${C_RED}OFFLINE${C_RESET}"
    [[ "$webui_st" == "active" ]] && webui_fmt="${C_GREEN}ONLINE${C_RESET}" || webui_fmt="${C_RED}OFFLINE${C_RESET}"

    printf "%s--------------------------------------------------------------------------------%s\n" "${C_CYAN}" "${C_RESET}"
    printf "%s HOMELAB AI DEPLOYER — STATO NODO INFERENZA CPU%s\n" "${C_BOLD}" "${C_RESET}"
    printf "%s--------------------------------------------------------------------------------%s\n" "${C_CYAN}" "${C_RESET}"
    printf " %s• OS / Host%s        : %s (Virt: %s)\n" "${C_BOLD}" "${C_RESET}" "${OS_NAME}" "${virt_type}"
    printf " %s• CPU / Load%s       : %s (%sC/%sT) — Load: %s\n" "${C_BOLD}" "${C_RESET}" "${cpu_model}" "${phys_cores}" "${log_cores}" "${load_avg}"
    printf " %s• RAM / Disk%s       : %s / %s (%s) | Storage: %s\n" "${C_BOLD}" "${C_RESET}" "${ram_used}" "${ram_tot}" "${ram_pct}" "${disk_info}"
    printf " %s• Temp / Ventole%s   : %s | Ventole: %s\n" "${C_BOLD}" "${C_RESET}" "${cpu_temps}" "${fan_speeds}"
    printf " %s• Modelli GGUF%s     : %s\n" "${C_BOLD}" "${C_RESET}" "${models_summary}"
    printf " %s• Llama.cpp%s        : [%s] http://%s:8080/v1\n" "${C_BOLD}" "${C_RESET}" "${llama_fmt}" "${primary_ip}"
    printf " %s• Open WebUI%s       : [%s] http://%s:8081\n" "${C_BOLD}" "${C_RESET}" "${webui_fmt}" "${primary_ip}"
    printf "%s--------------------------------------------------------------------------------%s\n" "${C_CYAN}" "${C_RESET}"
    printf " %sSessione terminata. Riavvio: ./manager-cpu.sh%s\n\n" "${C_DIM}" "${C_RESET}"
}

# Registrazione dell'hook di uscita globale
trap show_exit_summary EXIT

# ------------------------------------------------------------------------------
# Rilevamento Dinamico Hardware e Sistema
# ------------------------------------------------------------------------------
detect_os() {
    OS_NAME="Linux Generico"
    if [[ -f /etc/os-release ]]; then
        OS_NAME=$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
    fi
}

generate_hardware_profile() {
    log_info "Analisi delle risorse hardware..."

    TOTAL_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
    if [[ -z "${TOTAL_RAM_GB}" || "${TOTAL_RAM_GB}" -eq 0 ]]; then
        TOTAL_RAM_GB=4
    fi

    PHYSICAL_CORES=$(lscpu -p=CORE 2>/dev/null | grep -v '^#' | sort -u | wc -l)
    if [[ "${PHYSICAL_CORES}" -eq 0 ]]; then
        PHYSICAL_CORES=$(nproc)
    fi

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

    printf "  • RAM Rilevata     : %s GB\n" "${TOTAL_RAM_GB}"
    printf "  • Core Fisici CPU  : %s\n" "${OPTIMIZED_THREADS}"
    printf "  • Context Window   : %s token\n" "${OPTIMIZED_CTX}"
    printf "  • Batch Size       : %s\n" "${OPTIMIZED_BATCH}"
}

# ------------------------------------------------------------------------------
# Dipendenze e Compilazione
# ------------------------------------------------------------------------------
install_system_deps() {
    detect_os
    log_info "Verifica e installazione pacchetti base per ${OS_NAME}..."
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
}

build_llama_cpp() {
    install_system_deps

    log_info "Sincronizzazione repository llama.cpp..."
    if [[ -d "${LLAMA_DIR}" ]]; then
        git -C "${LLAMA_DIR}" pull --quiet
    else
        git clone https://github.com/ggerganov/llama.cpp.git "${LLAMA_DIR}"
    fi

    log_info "Compilazione nativa CPU (OpenMP & Vectorization)..."
    
    cd "${LLAMA_DIR}"
    rm -rf build
    cmake -B build -DGGML_NATIVE=ON -DGGML_OPENMP=ON -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS
    cmake --build build --config Release -j"$(nproc)"

    if [[ -f "${LLAMA_DIR}/build/bin/llama-cli" || -f "${LLAMA_DIR}/build/bin/llama-server" ]]; then
        log_info "Compilazione completata."
        pause
        return 0
    else
        log_err "Compilazione fallita."
        pause
        return 1
    fi
}

install_open_webui() {
    install_system_deps

    log_info "Configurazione virtualenv in: ${WEBUI_VENV}"
    if [[ -d "${WEBUI_VENV}" ]]; then
        rm -rf "${WEBUI_VENV}"
    fi

    python3 -m venv "${WEBUI_VENV}"
    source "${WEBUI_VENV}/bin/activate"

    pip install --upgrade pip setuptools wheel --quiet
    log_info "Installazione Open WebUI..."
    pip install open-webui --quiet

    deactivate
    log_info "Open WebUI installato correttamente."
    pause
    return 0
}

# ------------------------------------------------------------------------------
# Gestione Servizi Systemd
# ------------------------------------------------------------------------------
apply_systemd_config() {
    systemctl stop llama-server open-webui 2>/dev/null || true
    generate_hardware_profile

    cat <<EOF > /etc/systemd/system/llama-server.service
[Unit]
Description=Llama.cpp HTTP Server (CPU Mode)
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
    log_info "Servizi Systemd configurati e avviati."
}

setup_systemd_services() {
    if [[ ! -f "${LLAMA_DIR}/build/bin/llama-server" ]]; then
        log_err "Binario llama-server mancante. Esegui prima la compilazione (Opzione 1)."
        pause
        return 1
    fi

    if [[ ! -f "${WEBUI_VENV}/bin/open-webui" ]]; then
        log_err "Open WebUI mancante. Esegui prima l'installazione (Opzione 2)."
        pause
        return 2
    fi

    apply_systemd_config
    pause
    return 0
}

run_autotune() {
    if [[ ! -f /etc/systemd/system/llama-server.service ]]; then
        log_err "Servizi non configurati. Esegui prima il setup (Opzione 3)."
        pause
        return 1
    fi

    log_info "Esecuzione Auto-Tuning..."
    apply_systemd_config
    pause
    return 0
}

# ------------------------------------------------------------------------------
# Benchmark
# ------------------------------------------------------------------------------
run_benchmark() {
    mkdir -p "${MODELS_DIR}"

    if [[ ! -f "${LLAMA_DIR}/build/bin/llama-bench" ]]; then
        log_err "Binario llama-bench non trovato. Compila llama.cpp."
        pause
        return 1
    fi

    local model_file
    model_file=$(find "${MODELS_DIR}" -name "*.gguf" 2>/dev/null | head -n 1 || true)

    if [[ -z "${model_file}" ]]; then
        local download_confirm=0
        if [[ "${AUTO_MODE}" == "true" ]]; then
            download_confirm=0
        else
            whiptail --title "Download Modello Benchmark" --yesno "Nessun modello GGUF trovato in ${MODELS_DIR}.\n\nScaricare un modello leggero di test (Qwen2.5-0.5B ~390MB)?" 10 70 || download_confirm=1
        fi

        if [[ $download_confirm -eq 0 ]]; then
            log_info "Download modello di test Qwen2.5-0.5B..."
            wget -c "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf" -O "${MODELS_DIR}/qwen2.5-0.5b-instruct-q4_k_m.gguf"
            model_file="${MODELS_DIR}/qwen2.5-0.5b-instruct-q4_k_m.gguf"
        else
            log_err "Nessun modello disponibile per il benchmark."
            pause
            return 2
        fi
    fi

    generate_hardware_profile
    log_info "Avvio benchmark CPU: $(basename "${model_file}")"
    "${LLAMA_DIR}/build/bin/llama-bench" -m "${model_file}" -t "${OPTIMIZED_THREADS}"
    pause
    return 0
}

# ------------------------------------------------------------------------------
# Pipeline Automatica Non-Interattiva
# ------------------------------------------------------------------------------
run_all_automated() {
    AUTO_MODE=true
    clear
    printf "%s================================================================================%s\n" "${C_CYAN}" "${C_RESET}"
    printf "%s  HOMELAB AI DEPLOYER — EXPRESS AUTOMATED DEPLOYMENT (CPU)%s\n" "${C_BOLD}" "${C_RESET}"
    printf "%s================================================================================%s\n\n" "${C_CYAN}" "${C_RESET}"

    build_llama_cpp
    install_open_webui
    setup_systemd_services
    run_autotune
    run_benchmark

    log_info "Installazione automatica completata."
    sleep 2
    exit 0
}

# ------------------------------------------------------------------------------
# Wizard di Benvenuto Semplificato & Pulito
# ------------------------------------------------------------------------------
welcome_wizard() {
    detect_os
    
    # Pagina 1: Panoramica
    clear
    printf "%s================================================================================%s\n" "${C_CYAN}" "${C_RESET}"
    printf "  %sHOMELAB AI DEPLOYER — NODE INFERENCE CONTROLLER (CPU)%s\n" "${C_BOLD}" "${C_RESET}"
    printf "%s================================================================================%s\n\n" "${C_CYAN}" "${C_RESET}"

    printf "%s[ PANORAMICA ]%s\n" "${C_BOLD}" "${C_RESET}"
    printf "  Deploy nativo (Bare-Metal / LXC Proxmox) dello stack di inferenza LLM\n"
    printf "  ottimizzato per sola CPU.\n\n"

    printf "%s[ ARCHITETTURA ]%s\n" "${C_BOLD}" "${C_RESET}"
    printf "  • %sEngine%s         : llama.cpp (compilazione nativa C++, OpenMP, AVX2/AVX-512)\n" "${C_CYAN}" "${C_RESET}"
    printf "  • %sInterfaccia%s   : Open WebUI (ambiente virtuale Python isolato)\n" "${C_CYAN}" "${C_RESET}"
    printf "  • %sGestore%s       : Unità Systemd con riavvio automatico ed auto-tuning\n\n" "${C_CYAN}" "${C_RESET}"

    read -rp $'Premere [INVIO] per continuare (Specifiche e Modalità)...'

    # Pagina 2: Risorse & Scelta
    clear
    printf "%s================================================================================%s\n" "${C_CYAN}" "${C_RESET}"
    printf "  %sCONFIGURAZIONE AMBIENTE E PORTE RETE%s\n" "${C_BOLD}" "${C_RESET}"
    printf "%s================================================================================%s\n\n" "${C_CYAN}" "${C_RESET}"

    printf "%s[ PERCORSI LOCAL ]%s\n" "${C_BOLD}" "${C_RESET}"
    printf "  • Root Directory   : %s/opt/homelab-ai%s\n" "${C_CYAN}" "${C_RESET}"
    printf "  • Modelli GGUF     : %s/opt/homelab-ai/models%s\n\n" "${C_CYAN}" "${C_RESET}"

    printf "%s[ PORTE SERVIZI ]%s\n" "${C_BOLD}" "${C_RESET}"
    printf "  • Llama API (v1)   : %sHTTP 8080%s\n" "${C_CYAN}" "${C_RESET}"
    printf "  • Open WebUI GUI   : %sHTTP 8081%s\n\n" "${C_CYAN}" "${C_RESET}"

    printf "%s--------------------------------------------------------------------------------%s\n\n" "${C_CYAN}" "${C_RESET}"

    if command -v whiptail >/dev/null 2>&1; then
        local mode
        mode=$(whiptail --title "Modalità di Esecuzione" \
            --menu "\nSeleziona la modalità di avvio:" 12 70 2 \
            "AUTO" "Express Auto-Deploy (Passi 1->5 automatici senza prompt)" \
            "MENU" "Menu Interattivo (Seleziona le opzioni singolarmente)" \
            3>&1 1>&2 2>&3) || exit 0

        if [[ "$mode" == "AUTO" ]]; then
            run_all_automated
        fi
    fi
}

# ------------------------------------------------------------------------------
# Menu Principale TUI
# ------------------------------------------------------------------------------
render_header() {
    clear
    detect_os
    printf "%s--------------------------------------------------------------------------------%s\n" "${C_CYAN}" "${C_RESET}"
    printf "  %sHOMELAB AI DEPLOYER — CPU MANAGER%s (%s)\n" "${C_BOLD}" "${OS_NAME}" "${C_RESET}"
    printf "%s--------------------------------------------------------------------------------%s\n\n" "${C_CYAN}" "${C_RESET}"
}

main_menu() {
    local default_choice="1"

    while true; do
        render_header
        
        local choice
        choice=$(whiptail --title "Menu Operazioni" \
            --default-item "${default_choice}" \
            --menu "\nScegli un'opzione:" 18 75 7 \
            "A" "Express Auto-Deploy (Passi 1->5 automatici)" \
            "1" "Compila llama.cpp (AVX2/AVX-512 + OpenMP)" \
            "2" "Installa Open WebUI (Virtualenv)" \
            "3" "Configura e Avvia Servizi Systemd" \
            "4" "Auto-Tuning Hardware & Riavvio" \
            "5" "Esegui Benchmark CPU (llama-bench)" \
            "0" "Esci e Mostra Dashboard" \
            3>&1 1>&2 2>&3) || exit 0

        case "$choice" in
            A|a) run_all_automated ;;
            1) build_llama_cpp && default_choice="2" ;;
            2) install_open_webui && default_choice="3" ;;
            3) setup_systemd_services && default_choice="4" ;;
            4) run_autotune && default_choice="5" ;;
            5) run_benchmark && default_choice="0" ;;
            0) exit 0 ;;
            *) exit 0 ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    log_err "Lo script richiede i privilegi di root."
    exit 1
fi

welcome_wizard
main_menu
