#!/usr/bin/env bash
# ==============================================================================
# Script Name: manager-cpu.sh
# Version:     1.3.4
# Project:     homelab-ai-deployer
# Description: CPU Manager per llama.cpp (AVX2/AVX-512 + OpenMP) & Open WebUI
# ==============================================================================

set -euo pipefail

# --- VARIABILI GLOBALI DI SISTEMA ---
BASE_DIR="/opt/homelab-ai"
MODELS_DIR="${BASE_DIR}/models"
LLAMA_DIR="${BASE_DIR}/llama.cpp"
WEBUI_DIR="${BASE_DIR}/open-webui"
WEBUI_VENV="${WEBUI_DIR}/venv"

ACTIVE_MODEL=""
OPTIMIZED_THREADS=4
OPTIMIZED_CTX=32768
OPTIMIZED_BATCH=512
AUTO_MODE="false"

if [[ "${1:-}" == "--auto" ]]; then
    AUTO_MODE="true"
fi

# --- CATALOGO MODELLI CPU PRESETTATI ---
declare -A CPU_MODELS=(
    ["01. Qwen2.5-3B-Instruct"]="https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf|Qwen2.5-3B-Instruct-Q4_K_M.gguf|32768|1024|4"
    ["02. Phi-3.5-mini-instruct"]="https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf|Phi-3.5-mini-instruct-Q4_K_M.gguf|32768|512|6"
    ["03. Qwen2.5-7B-Instruct"]="https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf|Qwen2.5-7B-Instruct-Q4_K_M.gguf|32768|512|8"
    ["04. DeepSeek-R1-Distill-Qwen-7B"]="https://huggingface.co/unsloth/DeepSeek-R1-Distill-Qwen-7B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf|DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf|32768|256|8"
    ["05. Hermes-3-Llama-3.1-8B"]="https://huggingface.co/bartowski/Hermes-3-Llama-3.1-8B-GGUF/resolve/main/Hermes-3-Llama-3.1-8B-Q4_K_M.gguf|Hermes-3-Llama-3.1-8B-Q4_K_M.gguf|32768|512|8"
    ["06. Mistral-Nemo-Instruct (12B)"]="https://huggingface.co/bartowski/Mistral-Nemo-Instruct-2407-GGUF/resolve/main/Mistral-Nemo-Instruct-2407-Q4_K_M.gguf|Mistral-Nemo-Instruct-2407-Q4_K_M.gguf|32768|512|16"
    ["07. Qwen2.5-14B-Instruct"]="https://huggingface.co/bartowski/Qwen2.5-14B-Instruct-GGUF/resolve/main/Qwen2.5-14B-Instruct-Q4_K_M.gguf|Qwen2.5-14B-Instruct-Q4_K_M.gguf|32768|512|16"
    ["08. Qwen2.5-32B-Instruct"]="https://huggingface.co/bartowski/Qwen2.5-32B-Instruct-GGUF/resolve/main/Qwen2.5-32B-Instruct-Q4_K_M.gguf|Qwen2.5-32B-Instruct-Q4_K_M.gguf|32768|256|32"
    ["09. DeepSeek-R1-Distill-Qwen-32B"]="https://huggingface.co/unsloth/DeepSeek-R1-Distill-Qwen-32B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf|DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf|32768|256|32"
    ["10. DeepSeek-R1-Distill-Llama-70B"]="https://huggingface.co/unsloth/DeepSeek-R1-Distill-Llama-70B-GGUF/resolve/main/DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf|DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf|32768|128|64"
    ["11. Qwen2.5-72B-Instruct"]="https://huggingface.co/bartowski/Qwen2.5-72B-Instruct-GGUF/resolve/main/Qwen2.5-72B-Instruct-Q4_K_M.gguf|Qwen2.5-72B-Instruct-Q4_K_M.gguf|32768|128|64"
)

# --- LOGGING HELPERS ---
log_info() { echo -e "\e[32m[INFO]\e[0m $1"; }
log_warn() { echo -e "\e[33m[WARN]\e[0m $1"; }
log_err()  { echo -e "\e[31m[ERROR]\e[0m $1"; }

# --- CONTROLLO PRIVILEGI E DIPENDENZE BASE ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "Questo script deve essere eseguito come root (sudo)."
        exit 1
    fi
}

check_dependencies() {
    local deps=(build-essential cmake git python3 python3-pip whiptail curl wget pciutils htop)
    local missing=()
    for pkg in "${deps[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then missing+=("$pkg"); fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Installazione pacchetti mancanti: ${missing[*]}"
        apt-get update -qq && apt-get install -y -qq "${missing[@]}"
    fi
    mkdir -p "${MODELS_DIR}" "${BASE_DIR}"
}

# --- INSTALLAZIONE PYTHON 3.11 (Gestione Ubuntu/Debian) ---
install_python311() {
    if command -v python3.11 >/dev/null 2>&1; then
        log_info "Python 3.11 è già presente nel sistema."
        return 0
    fi

    log_warn "Python 3.11 non trovato. Inizio installazione automatica..."
    
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        local OS_ID="${ID}"
        
        if [[ "${OS_ID}" == "ubuntu" ]]; then
            log_info "Rilevato sistema Ubuntu. Utilizzo repository PPA deadsnakes..."
            apt-get update -qq
            apt-get install -y -qq software-properties-common
            add-apt-repository ppa:deadsnakes/ppa -y || true
            apt-get update -qq
            apt-get install -y -qq python3.11 python3.11-venv python3.11-dev
            
        elif [[ "${OS_ID}" == "debian" ]]; then
            log_info "Rilevato sistema Debian. Compilazione da sorgente (richiederà qualche minuto)..."
            apt-get update -qq
            apt-get install -y -qq build-essential libssl-dev zlib1g-dev libncurses5-dev libncursesw5-dev \
                libreadline-dev libsqlite3-dev libgdbm-dev libdb5.3-dev libbz2-dev libexpat1-dev liblzma-dev \
                tk-dev libffi-dev wget
            
            local tmp_dir
            tmp_dir=$(mktemp -d)
            pushd "${tmp_dir}" >/dev/null
            wget --show-progress -q https://www.python.org/ftp/python/3.11.9/Python-3.11.9.tgz
            tar -xf Python-3.11.9.tgz
            cd Python-3.11.9
            ./configure --enable-optimizations
            make -j "$(nproc)"
            make altinstall
            popd >/dev/null
            rm -rf "${tmp_dir}"
        else
            log_err "Sistema operativo non supportato in automatico (${OS_ID}). Installa Python 3.11 manualmente."
            exit 1
        fi
    else
        log_err "Impossibile determinare il sistema operativo. Installa Python 3.11 manualmente."
        exit 1
    fi
    
    log_info "Python 3.11 installato con successo."
}

# --- RILEVAMENTO MODELLO IN ESECUZIONE ---
detect_running_model() {
    local svc_file="/etc/systemd/system/llama-server.service"
    if [[ -f "${svc_file}" ]]; then
        local detected
        detected=$(grep -oP '(?<=-m )/opt/homelab-ai/models/[^ ]+' "${svc_file}" 2>/dev/null || true)
        if [[ -n "${detected}" && -f "${detected}" ]]; then
            ACTIVE_MODEL="${detected}"
        fi
    fi
}

# --- AUTO-TUNING HARDWARE ---
generate_hardware_profile() {
    local physical_cores
    physical_cores=$(lscpu -p=CORE,SOCKET 2>/dev/null | grep -v '^#' | sort -u | wc -l || true)
    if [[ -z "${physical_cores}" || "${physical_cores}" -eq 0 ]]; then physical_cores=$(nproc); fi
    OPTIMIZED_THREADS="${physical_cores}"
}

show_hardware_profile() {
    generate_hardware_profile
    local ram_total_mb
    ram_total_mb=$(free -m | awk '/^Mem:/ {print $2}')
    local ram_free_mb
    ram_free_mb=$(free -m | awk '/^Mem:/ {print $7}')
    
    local msg="Risultati dell'analisi hardware:\n\n"
    msg+="• CPU Thread Allocati: ${OPTIMIZED_THREADS}\n"
    msg+="• RAM Totale di sistema: ${ram_total_mb} MB\n"
    msg+="• RAM Libera disponibile: ${ram_free_mb} MB\n\n"
    msg+="Questi parametri verranno usati automaticamente\nper l'ottimizzazione del server llama.cpp."
    
    whiptail --title "Auto-Tuning Hardware (CPU & RAM)" --msgbox "${msg}" 13 60
}

# --- DOWNLOAD MASSIVO ---
download_all_models() {
    local msg="Stai per scaricare TUTTI i modelli in elenco.\n\n"
    msg+="Questo richiederà circa 160 GB di spazio libero\nsu disco e molta banda.\n\n"
    msg+="I modelli già presenti verranno ignorati.\n\n"
    msg+="Vuoi procedere?"

    if ! whiptail --title "Download Massivo" --yesno "${msg}" 14 65; then
        return 0
    fi
    
    local sorted_keys=()
    while IFS= read -r k; do sorted_keys+=("$k"); done < <(printf "%s\n" "${!CPU_MODELS[@]}" | sort)
    
    for key in "${sorted_keys[@]}"; do
        [[ -z "$key" ]] && continue
        IFS='|' read -r final_url filename ctx batch min_ram <<< "${CPU_MODELS[${key}]}"
        local target_path="${MODELS_DIR}/${filename}"
        
        if [[ -f "${target_path}" ]]; then
            log_info "Modello già presente: ${filename}, salto..."
            continue
        fi
        
        log_info "Download del modello: ${key}..."
        if ! wget --continue --show-progress -O "${target_path}" "${final_url}"; then
            log_warn "Errore durante il download di ${filename}, passo al successivo."
            rm -f "${target_path}"
        fi
    done
    
    whiptail --msgbox "Download di massa completato!\nOra puoi tornare al menu e selezionare quale avviare." 10 65
}

# --- SELEZIONE O DOWNLOAD MODELLI ---
select_active_model() {
    local model_files=()
    while IFS= read -r -d '' file; do model_files+=("$file"); done < <(find "${MODELS_DIR}" -maxdepth 2 -name "*.gguf" -print0 2>/dev/null)

    if [[ ${#model_files[@]} -eq 0 ]]; then
        log_warn "Nessun file .gguf presente."
        download_and_tune_model_menu
        return 0
    fi

    if [[ ${#model_files[@]} -eq 1 || "${AUTO_MODE}" == "true" ]]; then
        ACTIVE_MODEL="${model_files[0]}"
        return 0
    fi

    local menu_items=()
    for file in "${model_files[@]}"; do
        local fname fsize
        fname=$(basename "${file}")
        fsize=$(ls -lh "${file}" | awk '{print $5}')
        menu_items+=("${fname}" "Dim: ${fsize}")
    done

    local chosen_fname
    chosen_fname=$(whiptail --title "Selezione Modello Attivo" \
        --menu "\nSeleziona il modello GGUF da caricare sul server:" 20 80 10 \
        "${menu_items[@]}" 3>&1 1>&2 2>&3) || return 0

    ACTIVE_MODEL="${MODELS_DIR}/${chosen_fname}"
}

download_and_tune_model_menu() {
    generate_hardware_profile
    local total_ram_gb
    total_ram_gb=$(free -g | awk '/^Mem:/ {print $2}')

    local menu_options=(
        "AA. Scarica TUTTI i modelli" "[Richiede ~160GB di spazio]"
        "00. Inserisci URL Custom"    "[Da HuggingFace o link diretto]"
    )
    
    local sorted_keys=()
    while IFS= read -r k; do sorted_keys+=("$k"); done < <(printf "%s\n" "${!CPU_MODELS[@]}" | sort)

    for key in "${sorted_keys[@]}"; do
        [[ -z "$key" ]] && continue
        IFS='|' read -r url filename ctx batch min_ram <<< "${CPU_MODELS[${key}]}"
        local status="[Scaricabile - Min RAM: ${min_ram}GB]"
        if [[ -f "${MODELS_DIR}/${filename}" ]]; then status="[GIA PRESENTE IN LOCALE]"; fi
        menu_options+=("${key}" "${status}")
    done

    local choice
    choice=$(whiptail --title "Download & Model-Aware Tuning" \
        --menu "\nRAM Rilevata: ${total_ram_gb} GB\nScegli un'opzione:" 22 85 14 \
        "${menu_options[@]}" 3>&1 1>&2 2>&3) || return 0

    if [[ "${choice}" == "AA. Scarica TUTTI i modelli" ]]; then
        download_all_models
        return 0
    fi

    local target_path=""
    local final_url=""

    if [[ "${choice}" == "00. Inserisci URL Custom" ]]; then
        final_url=$(whiptail --inputbox "Inserisci il link diretto al file .gguf:" 10 75 3>&1 1>&2 2>&3) || return 0
        local filename
        filename=$(basename "${final_url}" | cut -d'?' -f1)
        target_path="${MODELS_DIR}/${filename}"
        OPTIMIZED_CTX=$(whiptail --inputbox "Context Window:" 10 40 "32768" 3>&1 1>&2 2>&3) || OPTIMIZED_CTX=32768
        OPTIMIZED_BATCH=$(whiptail --inputbox "Batch Size:" 10 40 "512" 3>&1 1>&2 2>&3) || OPTIMIZED_BATCH=512
    else
        IFS='|' read -r final_url filename ctx batch min_ram <<< "${CPU_MODELS[${choice}]}"
        target_path="${MODELS_DIR}/${filename}"
        
        if [[ "${total_ram_gb}" -lt "${min_ram}" ]]; then
            if ! whiptail --title "Avviso Risorse" --yesno "RAM inferiore al minimo consigliato.\nVuoi proseguire comunque?" 10 60; then return 0; fi
        fi

        OPTIMIZED_CTX="${ctx}"
        OPTIMIZED_BATCH="${batch}"
    fi

    if [[ ! -f "${target_path}" ]]; then
        log_info "Avvio download per: $(basename "${target_path}")"
        
        if ! wget --continue --show-progress -O "${target_path}" "${final_url}"; then
            rm -f "${target_path}"
            whiptail --msgbox "Errore di rete durante il download.\nVerifica il link o la connessione." 10 60
            return 1
        fi
        
        local filesize
        filesize=$(stat -c%s "${target_path}" 2>/dev/null || echo 0)
        if [[ ${filesize} -lt 5000000 ]]; then
            rm -f "${target_path}"
            whiptail --msgbox "Download fallito!\n\nIl file scaricato è troppo piccolo (< 5MB)." 12 65
            return 1
        fi
    fi

    ACTIVE_MODEL="${target_path}"
    whiptail --msgbox "Modello pronto!\n\nI servizi verranno riavviati con i nuovi parametri." 10 65
    apply_systemd_config
}

# --- COMPILAZIONE NATIVA LLAMA.CPP ---
compile_llama_cpu() {
    log_info "Compilazione nativa di llama.cpp..."
    if [[ ! -d "${LLAMA_DIR}" ]]; then git clone https://github.com/ggml-org/llama.cpp "${LLAMA_DIR}"; else cd "${LLAMA_DIR}" && git pull; fi
    cd "${LLAMA_DIR}" && rm -rf build && mkdir build && cd build

    local cmake_flags=("-DGGML_OPENMP=ON" "-DCMAKE_BUILD_TYPE=Release")
    if grep -q "avx512" /proc/cpuinfo; then cmake_flags+=("-DGGML_AVX512=ON"); elif grep -q "avx2" /proc/cpuinfo; then cmake_flags+=("-DGGML_AVX2=ON"); fi

    cmake .. "${cmake_flags[@]}"
    cmake --build . --config Release -j "${OPTIMIZED_THREADS}" --target llama-server llama-bench
    log_info "Compilazione completata."
}

# --- INSTALLAZIONE OPEN WEBUI ---
install_open_webui() {
    log_info "Setup Open WebUI..."
    install_python311
    
    mkdir -p "${WEBUI_DIR}"
    
    # Controllo e rimozione venv corrotto (es. creato con Python 3.12)
    if [[ -d "${WEBUI_VENV}" ]]; then
        local venv_py_version
        venv_py_version=$("${WEBUI_VENV}/bin/python" --version 2>&1 || true)
        if [[ "${venv_py_version}" != *"3.11"* ]]; then
            log_warn "Rilevato venv con versione Python incompatibile. Ricreazione in corso..."
            rm -rf "${WEBUI_VENV}"
        fi
    fi

    if [[ ! -d "${WEBUI_VENV}" ]]; then 
        python3.11 -m venv "${WEBUI_VENV}"
    fi
    
    "${WEBUI_VENV}/bin/pip" install --upgrade pip
    "${WEBUI_VENV}/bin/pip" install open-webui
    log_info "Open WebUI installato."
}

# --- GENERAZIONE CONFIGURAZIONE SYSTEMD ---
apply_systemd_config() {
    generate_hardware_profile
    if [[ -z "${ACTIVE_MODEL}" || ! -f "${ACTIVE_MODEL}" ]]; then select_active_model; fi
    if [[ -z "${ACTIVE_MODEL}" || ! -f "${ACTIVE_MODEL}" ]]; then return 1; fi

    log_info "Configurazione Systemd per: $(basename "${ACTIVE_MODEL}")"

    cat <<EOF > /etc/systemd/system/llama-server.service
[Unit]
Description=Llama.cpp HTTP Server (CPU Optimized)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${LLAMA_DIR}
ExecStart=${LLAMA_DIR}/build/bin/llama-server -m ${ACTIVE_MODEL} --host 0.0.0.0 --port 8080 -c ${OPTIMIZED_CTX} -b ${OPTIMIZED_BATCH} --threads ${OPTIMIZED_THREADS}
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
WorkingDirectory=${WEBUI_DIR}
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
    log_info "Servizi riavviati."
}

# --- BENCHMARK CPU ---
run_cpu_benchmark() {
    if [[ -z "${ACTIVE_MODEL}" || ! -f "${ACTIVE_MODEL}" ]]; then select_active_model; fi
    if [[ ! -f "${LLAMA_DIR}/build/bin/llama-bench" ]]; then log_err "Esegui prima la compilazione."; return 1; fi

    log_info "Esecuzione benchmark sul modello: $(basename "${ACTIVE_MODEL}") con ${OPTIMIZED_THREADS} thread..."
    "${LLAMA_DIR}/build/bin/llama-bench" -m "${ACTIVE_MODEL}" -t "${OPTIMIZED_THREADS}" -p 512 -n 128
    
    read -p "Premi [INVIO] per tornare al menu..."
}

# --- EXPRESS AUTO-DEPLOY ---
run_express_deploy() {
    generate_hardware_profile
    compile_llama_cpu
    install_open_webui
    select_active_model
    apply_systemd_config
}

# --- DASHBOARD DI USCITA ---
show_exit_summary() {
    local exit_code=$?
    echo -e "\n================================================================="
    echo -e "              HOMELAB AI DEPLOYER - CPU DASHBOARD                "
    echo -e "================================================================="
    local ip_addr
    ip_addr=$(hostname -I | awk '{print $1}' || echo "127.0.0.1")

    echo -e " Stato Servizi:"
    echo -e "  • llama-server: $(systemctl is-active llama-server 2>/dev/null || echo 'inactive')"
    echo -e "  • open-webui:   $(systemctl is-active open-webui 2>/dev/null || echo 'inactive')"
    echo -e "-----------------------------------------------------------------"
    echo -e " Modello Attivo: $(basename "${ACTIVE_MODEL:-'Nessuno'}")"
    echo -e " Endpoint API:   http://${ip_addr}:8080/v1"
    echo -e " Web Interface:  http://${ip_addr}:8081"
    echo -e "=================================================================\n"
    exit ${exit_code}
}

trap show_exit_summary EXIT

# --- MENU PRINCIPALE ---
show_menu() {
    check_root
    check_dependencies
    generate_hardware_profile
    detect_running_model

    if [[ "${AUTO_MODE}" == "true" ]]; then run_express_deploy; exit 0; fi

    while true; do
        local choice
        choice=$(whiptail --title "Homelab AI Deployer - Manager CPU (v1.3.4)" \
            --menu "\nSeleziona un'operazione:" 20 80 8 \
            "A" "Express Auto-Deploy (Pipeline Completa)" \
            "1" "Compila llama.cpp (AVX2/AVX-512 + OpenMP)" \
            "2" "Installa Open WebUI (Python venv)" \
            "3" "Configura & Avvia Servizi Systemd" \
            "4" "Mostra Profilo Hardware (CPU & RAM)" \
            "5" "Download & Tuning Modelli CPU" \
            "6" "Esegui Benchmark CPU (llama-bench)" \
            "0" "Esci e Mostra Dashboard" 3>&1 1>&2 2>&3) || exit 0

        case "${choice}" in
            A) run_express_deploy ;;
            1) compile_llama_cpu ;;
            2) install_open_webui ;;
            3) apply_systemd_config ;;
            4) show_hardware_profile ;;
            5) download_and_tune_model_menu ;;
            6) run_cpu_benchmark ;;
            0) exit 0 ;;
        esac
    done
}

show_menu
