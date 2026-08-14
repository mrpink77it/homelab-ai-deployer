#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Controller AMD (manager-amd.sh)
# Compatible with: Debian 13 (Trixie) & Ubuntu 24.04 LTS | Baremetal & LXC
# ==============================================================================

set -e

# Determinazione sicura della Home utente reale (supporta esecuzione via sudo)
if [ -n "$SUDO_USER" ]; then
    REAL_USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    REAL_USER_HOME="$HOME"
fi

# Configuration Paths
LOG_DIR="${REAL_USER_HOME}/homelab-ai-logs"
INSTALL_DIR="/opt/homelab-ai"
UNSLOTH_ENV="/root/unsloth_env"
CODE_RUNNER_DIR="/opt/code_runner"
LLAMA_CPP_DIR="${INSTALL_DIR}/llama.cpp"

# --- Palette Colori & Stili ANSI ---
BOLD='\033[1m'
RESET='\033[0m'

C_CYAN='\033[38;5;38m'
C_BLUE='\033[38;5;32m'
C_GREEN='\033[38;5;42m'
C_YELLOW='\033[38;5;214m'
C_RED='\033[38;5;196m'
C_PURPLE='\033[38;5;141m'
C_GRAY='\033[38;5;242m'
C_WHITE='\033[38;5;255m'

# --- Componenti Grafici ---
show_header() {
    clear
    echo -e "${C_PURPLE}==============================================================================${RESET}"
    echo -e "  ${BOLD}${C_WHITE}H O M E L A B   A I   D E P L O Y E R${RESET}  ${C_GRAY}::${RESET}  ${BOLD}${C_CYAN}A M D   C O N T R O L L E R${RESET}"
    echo -e "  ${C_GRAY}Gestione Hardware AMD · Accelerazione Vulkan/ROCm · llama.cpp${RESET}"
    echo -e "${C_PURPLE}==============================================================================${RESET}\n"
}

show_split_screen_guide() {
    local step_title="$1"
    local left_content="$2"
    local right_content="$3"

    show_header
    echo -e "  ${BOLD}${C_PURPLE}❖ GUIDA OPERATIVA :: ${step_title}${RESET}"
    echo -e "  ${C_GRAY}──────────────────────────────────────────────────────────────────────────────${RESET}"
    
    echo -e "  ${BOLD}${C_CYAN}STATO OPERATIVO & PARAMETRI${RESET}          ${C_GRAY}│${RESET} ${BOLD}${C_YELLOW}CONFIGURAZIONE & CONTESTO LOGS${RESET}"
    echo -e "  ${C_GRAY}───────────────────────────────────────┼──────────────────────────────────────${RESET}"

    mapfile -t left_lines <<< "$left_content"
    mapfile -t right_lines <<< "$right_content"

    local max_lines=${#left_lines[@]}
    if [ ${#right_lines[@]} -gt $max_lines ]; then
        max_lines=${#right_lines[@]}
    fi

    for ((i=0; i<max_lines; i++)); do
        local l_line="${left_lines[i]:-}"
        local r_line="${right_lines[i]:-}"
        
        local clean_left
        clean_left=$(echo -e "$l_line" | sed 's/\x1b\[[0-9;]*m//g')
        local len=${#clean_left}
        local pad=$((37 - len))
        [ $pad -lt 0 ] && pad=0
        
        local padding=""
        if [ $pad -gt 0 ]; then
            padding=$(printf '%*s' "$pad" "")
        fi

        echo -e "  ${l_line}${padding} ${C_GRAY}│${RESET} ${r_line}"
    done
    echo -e "  ${C_GRAY}──────────────────────────────────────────────────────────────────────────────${RESET}\n"
}

# --- Verifiche Iniziali ---
if [ "$EUID" -ne 0 ]; then
    show_header
    echo -e "  ${C_RED}✖ PERMESSI INSUFFICIENTI${RESET}"
    echo -e "  ${C_GRAY}Esegui lo script con privilegi di root: ${C_WHITE}sudo ./manager-amd.sh${RESET}\n"
    exit 1
fi

install_vulkan_dependencies() {
    echo -e "  ${C_CYAN}➜ Verifica e installazione dipendenze di sistema...${RESET}"
    apt-get update -qq

    # Inclusi glslang-tools e glslang-dev per garantire la presenza di /usr/bin/glslc (richiesto da CMake 3.31+)
    BASE_PACKAGES=(
        build-essential cmake ccache git curl wget zstd
        pkg-config libssl-dev libvulkan-dev vulkan-tools
        mesa-vulkan-drivers glslang-tools glslang-dev
        python3 python3-pip python3-venv clinfo nodejs npm
    )

    echo -e "  ${C_BLUE}➜ Installazione pacchetti base e toolchain Vulkan/C++...${RESET}"
    apt-get install -y "${BASE_PACKAGES[@]}"
}

select_log_mode() {
    echo -e "  ${BOLD}${C_PURPLE}❖ SELEZIONE MODALITÀ DI LOGGING${RESET}"
    echo -e "  ${C_GRAY}──────────────────────────────────────────────────────────────────────────────${RESET}"
    echo -e "  ${BOLD}${C_CYAN}[1] all${RESET}      ${C_WHITE}Log Completo File${RESET}  · Solo file build_all.log (Silenzioso)"
    echo -e "  ${BOLD}${C_CYAN}[2] all+video${RESET}${C_WHITE} Log Completo Video${RESET} · Salva in build_all.log + Mostra a video"
    echo -e "  ${BOLD}${C_YELLOW}[3] err${RESET}      ${C_WHITE}Solo Errori File${RESET}   · Solo file build_errors.log (Silenzioso)"
    echo -e "  ${BOLD}${C_YELLOW}[4] err+video${RESET}${C_WHITE} Log Errori Video${RESET}  · Salva in build_errors.log + Mostra a video"
    echo -e "  ${BOLD}${C_GRAY}[5] none${RESET}     ${C_WHITE}Nessun Log File${RESET}   · Solo output standard a video"
    echo -e "  ${C_GRAY}──────────────────────────────────────────────────────────────────────────────${RESET}\n"

    read -p "  Seleziona opzione [1-5] (default: 2): " log_choice
    case $log_choice in
        1) LOG_MODE="all" ;;
        2) LOG_MODE="all_tee" ;;
        3) LOG_MODE="err" ;;
        4) LOG_MODE="err_tee" ;;
        5) LOG_MODE="none" ;;
        *) LOG_MODE="all_tee" ;;
    esac
}

build_llama_vulkan() {
    # Garanzia assoluta creazione cartella Log prima di qualsiasi elaborazione
    mkdir -p "${LOG_DIR}"
    chmod 755 "${LOG_DIR}"

    # Auto-healing: garantisce la presenza di glslc prima di lanciare CMake
    if ! command -v glslc &> /dev/null; then
        echo -e "  ${C_YELLOW}[!] Binario 'glslc' non trovato. Esecuzione installazione dipendenze...${RESET}"
        install_vulkan_dependencies
    fi

    select_log_mode

    local all_log_file="${LOG_DIR}/build_all.log"
    local err_log_file="${LOG_DIR}/build_errors.log"
    local cmake_log_file="${LOG_DIR}/cmake_config.log"

    mkdir -p "${INSTALL_DIR}"
    cd "${INSTALL_DIR}"

    if [ -d "${LLAMA_CPP_DIR}" ]; then
        echo -e "\n  ${C_CYAN}➜ Sync repository llama.cpp in corso...${RESET}"
        cd "${LLAMA_CPP_DIR}"
        git pull --quiet || true
    else
        echo -e "\n  ${C_CYAN}➜ Download sorgenti llama.cpp...${RESET}"
        git clone --quiet https://github.com/ggerganov/llama.cpp.git "${LLAMA_CPP_DIR}"
        cd "${LLAMA_CPP_DIR}"
    fi

    # Pulizia della build precedente
    rm -rf build
    mkdir -p build
    cd build

    local left_info="* Repo : github.com/ggerganov/llama.cpp
* Path : ${LLAMA_CPP_DIR}
* GPU  : Vulkan (Driver RADV)
* Mode : [${LOG_MODE}]"

    local right_info="* Shaders : Compilatore glslc attivo
* C++     : Standard C++20
* Logs    : ${LOG_DIR}/"

    show_split_screen_guide "Compilazione Nativa llama.cpp" "$left_info" "$right_info"

    echo -e "  ${C_CYAN}➜ Configurazione ambiente CMake (Vulkan Enabled)...${RESET}"

    set +e
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_STANDARD=20 \
        -DGGML_VULKAN=ON > "${cmake_log_file}" 2>&1
    
    local cmake_res=$?
    set -e

    if [ $cmake_res -ne 0 ]; then
        echo -e "\n  ${C_RED}✖ Errore durante la configurazione CMake!${RESET}"
        echo -e "  ${C_YELLOW}Il log di configurazione è salvato in:${RESET} ${C_WHITE}${cmake_log_file}${RESET}\n"
        cat "${cmake_log_file}"
        read -p "  Premi [INVIO] per tornare al menu..."
        return 1
    fi

    echo -e "  ${C_GREEN}✔ Configurazione CMake completata con successo.${RESET}"
    echo -e "  ${C_YELLOW}➜ Avvio build parallela su $(nproc) thread...${RESET}\n"

    set +e
    case $LOG_MODE in
        all)
            echo -e "  ${C_GRAY}[i] Registrazione log completo in: ${C_WHITE}${all_log_file}${RESET}\n"
            cmake --build . --config Release -j$(nproc) > "${all_log_file}" 2>&1
            grep -iE 'error|cannot compile|failed|fatal' "${all_log_file}" > "${err_log_file}" || true
            ;;
        all_tee)
            echo -e "  ${C_GRAY}[i] Output a video + Registrazione log in: ${C_WHITE}${all_log_file}${RESET}\n"
            cmake --build . --config Release -j$(nproc) 2>&1 | tee "${all_log_file}"
            grep -iE 'error|cannot compile|failed|fatal' "${all_log_file}" > "${err_log_file}" || true
            ;;
        err)
            echo -e "  ${C_GRAY}[i] Registrazione dei soli errori in: ${C_WHITE}${err_log_file}${RESET}\n"
            cmake --build . --config Release -j$(nproc) > "${all_log_file}" 2>&1
            grep -iE 'error|cannot compile|failed|fatal' "${all_log_file}" > "${err_log_file}" || true
            ;;
        err_tee)
            echo -e "  ${C_GRAY}[i] Output a video + Isolamento errori in: ${C_WHITE}${err_log_file}${RESET}\n"
            cmake --build . --config Release -j$(nproc) 2>&1 | tee "${all_log_file}"
            grep -iE 'error|cannot compile|failed|fatal' "${all_log_file}" > "${err_log_file}" || true
            ;;
        none)
            cmake --build . --config Release -j$(nproc)
            ;;
    esac
    set -e

    echo -e "\n  ${C_GREEN}✔ Processo di compilazione terminato!${RESET}"
    if [ -s "${err_log_file}" ]; then
        echo -e "  ${C_YELLOW}[!] Rilevati avvisi/errori registrati in: ${C_WHITE}${err_log_file}${RESET}"
    else
        echo -e "  ${C_GREEN}✔ Nessun errore critico rilevato.${RESET}"
    fi
}

install_services() {
    show_header
    echo -e "  ${BOLD}${C_PURPLE}❖ SELEZIONE BACKEND D'INFERENZA AMD${RESET}"
    echo -e "  ${C_GRAY}──────────────────────────────────────────────────────────────────────────────${RESET}"
    echo -e "  ${BOLD}${C_CYAN}[1]${RESET} ${C_WHITE}ROCm Ufficiale${RESET}     · Consigliato per GPU RX 6000 / RX 7000"
    echo -e "  ${BOLD}${C_GREEN}[2]${RESET} ${C_WHITE}Vulkan / llama.cpp${RESET} · Consigliato per RX 5000 / RDNA1 (RX 5700 XT)"
    echo -e "  ${BOLD}${C_YELLOW}[3]${RESET} ${C_WHITE}ROCm Sperimentale${RESET}  · Override PyTorch (HSA_OVERRIDE_GFX=10.3.0)"
    echo -e "  ${C_GRAY}──────────────────────────────────────────────────────────────────────────────${RESET}\n"

    read -p "  Seleziona opzione [1-3]: " amd_choice

    install_vulkan_dependencies
    mkdir -p "${INSTALL_DIR}"

    case $amd_choice in
        1)
            echo -e "\n  ${C_BLUE}➜ Setup ROCm Ufficiale...${RESET}"
            apt-get install -y -qq rocm-hip-sdk || true
            mkdir -p "${UNSLOTH_ENV}"
            python3 -m venv "${UNSLOTH_ENV}"
            "${UNSLOTH_ENV}/bin/pip" install --upgrade pip --quiet
            "${UNSLOTH_ENV}/bin/pip" install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/rocm6.0 --quiet
            ;;
        2)
            build_llama_vulkan
            ;;
        3)
            echo -e "\n  ${C_BLUE}➜ Setup ROCm Sperimentale (gfx1030)...${RESET}"
            apt-get install -y -qq rocm-hip-sdk || true
            mkdir -p "${UNSLOTH_ENV}"
            python3 -m venv "${UNSLOTH_ENV}"
            "${UNSLOTH_ENV}/bin/pip" install --upgrade pip --quiet
            "${UNSLOTH_ENV}/bin/pip" install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/rocm6.0 --quiet

            if ! grep -q "HSA_OVERRIDE_GFX_VERSION=10.3.0" /root/.bashrc; then
                echo "export HSA_OVERRIDE_GFX_VERSION=10.3.0" >> /root/.bashrc
            fi
            export HSA_OVERRIDE_GFX_VERSION=10.3.0
            echo -e "  ${C_GREEN}✔ Env HSA_OVERRIDE_GFX_VERSION=10.3.0 registrato in /root/.bashrc${RESET}"
            ;;
        *)
            echo -e "\n  ${C_RED}✖ Scelta non valida.${RESET}"
            return 1
            ;;
    esac

    echo -e "\n  ${C_GREEN}✔ Operazione completata!${RESET}"
    read -p "  Premi [INVIO] per continuare..."
}

check_status() {
    show_header
    echo -e "  ${BOLD}${C_PURPLE}❖ STATO HARDWARE & COMPONENTI AMD${RESET}\n"

    if command -v vulkaninfo &> /dev/null; then
        echo -e "  ${C_GREEN}[ OK ]${RESET} ${BOLD}Vulkan Runtime${RESET}     · Presente nel sistema"
    else
        echo -e "  ${C_RED}[FAIL]${RESET} ${BOLD}Vulkan Runtime${RESET}     · Non installato"
    fi

    if [ -f "${LOG_DIR}/build_errors.log" ]; then
        echo -e "  ${C_YELLOW}[WARN]${RESET} ${BOLD}Log Errori Build${RESET}   · Rilevato in ${C_CYAN}${LOG_DIR}/build_errors.log${RESET}"
    fi

    if command -v rocm-smi &> /dev/null; then
        echo -e "  ${C_GREEN}[ OK ]${RESET} ${BOLD}ROCm SMI Utilità${RESET}   · Attiva"
        echo -e "${C_GRAY}"
        rocm-smi --showid | sed 's/^/         /' || true
        echo -e "${RESET}"
    else
        echo -e "  ${C_YELLOW}[WARN]${RESET} ${BOLD}ROCm SMI Utilità${RESET}   · Non disponibile"
    fi

    if [ -f "${LLAMA_CPP_DIR}/build/bin/llama-cli" ] || [ -f "${LLAMA_CPP_DIR}/build/bin/llama-server" ]; then
        echo -e "  ${C_GREEN}[ OK ]${RESET} ${BOLD}llama.cpp Binari${RESET}   · Compilati in ${LLAMA_CPP_DIR}/build/bin"
    fi

    echo ""
    read -p "  Premi [INVIO] per continuare..."
}

update_components() {
    show_header
    echo -e "  ${C_YELLOW}➜ Aggiornamento componenti e ricompilazione...${RESET}\n"
    if [ -d "${LLAMA_CPP_DIR}" ]; then
        build_llama_vulkan
    else
        echo -e "  ${C_YELLOW}[!] Repository llama.cpp non trovata in ${LLAMA_CPP_DIR}.${RESET}"
    fi
    echo ""
    read -p "  Premi [INVIO] per continuare..."
}

configure_sandbox() {
    show_header
    local left_info="* Connect Remote Sandbox SSH
* Nativo KeyGen Ed25519
* Auto-deploy chiave pubblica"

    local right_info="* Esecuzione remota abilitata
* Requisito: Root target
* Ideal: Container LXC / VM"

    show_split_screen_guide "Configurazione Sandbox SSH" "$left_info" "$right_info"

    read -p "  Inserisci l'IP del nodo Sandbox (INVIO per annullare): " sandbox_ip
    if [ -n "$sandbox_ip" ]; then
        if [ ! -f /root/.ssh/id_ed25519 ]; then
            ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 -q
        fi
        ssh-copy-id -i /root/.ssh/id_ed25519.pub "root@${sandbox_ip}" || true
    fi
    read -p "  Premi [INVIO] per continuare..."
}

uninstall_all() {
    show_header
    echo -e "  ${BOLD}${C_RED}❖ RIMOZIONE COMPLETA AMBIENTE${RESET}\n"
    read -p "  Confermi la cancellazione di servizi, dipendenze e log? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -rf "${INSTALL_DIR}" "${UNSLOTH_ENV}" "${CODE_RUNNER_DIR}" "${LOG_DIR}"
        echo -e "\n  ${C_GREEN}✔ Ambiente e log rimossi con successo.${RESET}"
    else
        echo -e "\n  ${C_YELLOW}Operazione annullata.${RESET}"
    fi
    read -p "  Premi [INVIO] per continuare..."
}

# --- Main Menu Loop ---
while true; do
    show_header
    echo -e "  ${C_GRAY}──────────────────────────────────────────────────────────────────────────────${RESET}"
    echo -e "  ${BOLD}${C_CYAN}[1]${RESET} ${C_WHITE}INSTALLA Servizi${RESET} (ROCm / Vulkan)"
    echo -e "  ${BOLD}${C_GREEN}[2]${RESET} ${C_WHITE}VERIFICA Stato${RESET} Hardware & Servizi"
    echo -e "  ${BOLD}${C_YELLOW}[3]${RESET} ${C_WHITE}AGGIORNA Componenti${RESET} & llama.cpp"
    echo -e "  ${BOLD}${C_PURPLE}[4]${RESET} ${C_WHITE}CONFIGURA Sandbox SSH${RESET}"
    echo -e "  ${BOLD}${C_RED}[5]${RESET} ${C_WHITE}DISINSTALLA Tutto${RESET}"
    echo -e "  ${BOLD}${C_WHITE}[6] ESCI${RESET}"
    echo -e "  ${C_GRAY}──────────────────────────────────────────────────────────────────────────────${RESET}\n"

    read -p "  Seleziona un'opzione [1-6]: " choice

    case $choice in
        1) install_services ;;
        2) check_status ;;
        3) update_components ;;
        4) configure_sandbox ;;
        5) uninstall_all ;;
        6) echo -e "\n  ${C_GREEN}Arrivederci!${RESET}\n"; exit 0 ;;
        *) echo -e "\n  ${C_RED}Opzione non valida!${RESET}"; sleep 1 ;;
    esac
done
