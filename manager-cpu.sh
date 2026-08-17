#!/usr/bin/env bash
# ==============================================================================
# Script: manager-cpu.sh
# Descrizione: Gestore deployment, inferenza CPU, Open WebUI e Logging
# Ambienti: Bare-Metal & Proxmox LXC (Debian 12+ / Ubuntu 22.04+)
# ==============================================================================

set -euo pipefail

trap 'echo -e "\n\033[1;31m[ERRORE FATALE] Lo script si è interrotto alla riga $LINENO.\033[0m\n"' ERR

# ------------------------------------------------------------------------------
# Configurazione Variabili Globali
# ------------------------------------------------------------------------------
LOG_FILE="/var/log/homelab-ai-cpu.log"
INSTALL_DIR="/opt/homelab-ai"
LLAMA_DIR="${INSTALL_DIR}/llama.cpp"
MODELS_DIR="${INSTALL_DIR}/models"
WEBUI_DIR="${INSTALL_DIR}/open-webui"

SERVICE_NAME="homelab-ai-backend"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
FRONTEND_SERVICE_FILE="/etc/systemd/system/homelab-ai-frontend.service"

# Colori per output terminale
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_BLUE='\033[0;34m'
C_YELLOW='\033[1;33m'
C_BOLD='\033[1m'
C_NC='\033[0m'

# ------------------------------------------------------------------------------
# Utility e Logging
# ------------------------------------------------------------------------------
log() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "${timestamp} [${level}] ${msg}" >> "${LOG_FILE}"
}

log_info() { log "INFO" "$1"; echo -e "${C_GREEN}[INFO]${C_NC} $1"; }
log_warn() { log "WARN" "$1"; echo -e "${C_YELLOW}[WARN]${C_NC} $1"; }
log_err()  { log "ERROR" "$1"; echo -e "${C_RED}[ERRORE]${C_NC} $1"; }

print_header() {
    clear
    echo -e "${C_BLUE}${C_BOLD}======================================================================${C_NC}"
    echo -e "${C_BLUE}${C_BOLD} $1 ${C_NC}"
    echo -e "${C_BLUE}${C_BOLD}======================================================================${C_NC}\n"
}

pause() {
    echo -e "\n${C_BOLD}Premi INVIO per tornare al menu principale...${C_NC}"
    read -r
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${C_RED}Questo script richiede privilegi amministrativi. Avvialo con sudo.${C_NC}"
        exit 1
    fi
}

detect_environment() {
    local os_info="Sistema Sconosciuto"
    if [[ -f /etc/os-release ]]; then
        os_info=$(grep -E '^(PRETTY_NAME)=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
    fi
    if [[ -f /proc/1/environ ]] && grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
        echo "LXC (Proxmox) - ${os_info}"
    else
        echo "Bare-Metal - ${os_info}"
    fi
}

init_env() {
    mkdir -p "$(dirname "$LOG_FILE")" "${MODELS_DIR}" "${WEBUI_DIR}"
    touch "${LOG_FILE}" || true
}

# ------------------------------------------------------------------------------
# Fase 1: Installazione Dipendenze
# ------------------------------------------------------------------------------
install_dependencies() {
    print_header "Installazione Dipendenze di Sistema"
    export DEBIAN_FRONTEND=noninteractive
    
    log_info "Aggiornamento indici dei pacchetti (apt-get update)..."
    apt-get update -y
    
    log_info "Installazione toolchain di compilazione, OpenBLAS e OpenMP..."
    apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" \
        build-essential cmake git curl wget pkg-config whiptail \
        python3 python3-pip python3-venv python3-dev \
        libopenblas-dev libomp-dev
        
    log_info "Dipendenze installate con successo."
    pause
}

# ------------------------------------------------------------------------------
# Fase 2: Compilazione llama.cpp (CPU Ottimizzata)
# ------------------------------------------------------------------------------
compile_llama() {
    local backend_type="$1"
    print_header "Compilazione Motore di Inferenza (Llama.cpp - ${backend_type})"
    
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    
    if [[ ! -d "${LLAMA_DIR}" ]]; then
        log_info "Clonazione del repository ufficiale llama.cpp..."
        git clone https://github.com/ggerganov/llama.cpp.git "${LLAMA_DIR}"
    else
        log_info "Aggiornamento codice sorgente locale..."
        git -C "${LLAMA_DIR}" pull
    fi

    log_info "Pulizia ambiente di build..."
    rm -rf "${LLAMA_DIR}/build"
    
    log_info "Generazione configurazione CMake..."
    case "${backend_type}" in
        "native")
            # Usa set di istruzioni native della CPU ospite (AVX2, AVX-512)
            cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" -DGGML_NATIVE=ON
            ;;
        "openblas")
            cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS
            ;;
    esac

    log_info "Avvio compilazione in parallelo ($(nproc) thread allocati)..."
    cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
    
    log_info "Compilazione terminata. Generazione servizio systemd..."
    auto_setup_systemd_service
    pause
}

auto_setup_systemd_service() {
    local host="0.0.0.0"
    local port="8080"
    local model_path="${MODELS_DIR}/model.gguf"
    local cpu_threads=$(nproc)

    cat <<EOF > "${SERVICE_FILE}"
[Unit]
Description=Homelab AI Backend Service (llama.cpp CPU)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
Environment="OMP_NUM_THREADS=${cpu_threads}"
ExecStart=${LLAMA_DIR}/build/bin/llama-server --host ${host} --port ${port} -m "${model_path}" -t ${cpu_threads} -c 4096
Restart=always
RestartSec=5
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"
    log_info "Servizio '${SERVICE_NAME}' creato con successo (${cpu_threads} thread allocati)."
}

# ------------------------------------------------------------------------------
# Fase 3: Installazione Frontend (Open WebUI)
# ------------------------------------------------------------------------------
install_open_webui() {
    print_header "Installazione Frontend (Open WebUI)"
    
    log_info "Creazione ambiente virtuale Python (venv)..."
    if [[ ! -d "${WEBUI_DIR}/venv" ]]; then
        python3 -m venv "${WEBUI_DIR}/venv"
    fi
    
    source "${WEBUI_DIR}/venv/bin/activate"
    log_info "Aggiornamento pip e installazione/aggiornamento pacchetto open-webui..."
    pip install --upgrade pip
    pip install open-webui
    deactivate

    log_info "Generazione servizio systemd per il frontend..."
    cat <<EOF > "${FRONTEND_SERVICE_FILE}"
[Unit]
Description=Homelab AI Frontend Service (Open WebUI)
After=network.target ${SERVICE_NAME}.service

[Service]
Type=simple
User=root
WorkingDirectory=${WEBUI_DIR}
Environment="PORT=3000"
Environment="OPENAI_API_BASE_URL=http://127.0.0.1:8080/v1"
ExecStart=${WEBUI_DIR}/venv/bin/open-webui serve
Restart=always
RestartSec=5
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable homelab-ai-frontend
    log_info "Servizio frontend creato. In ascolto sulla porta 3000."
    pause
}

# ------------------------------------------------------------------------------
# Fase 4: Gestione Modelli CPU
# ------------------------------------------------------------------------------
download_model() {
    local choice
    choice=$(whiptail --title "Catalogo Modelli Ottimizzati per CPU" \
        --menu "\nScegli un modello con un rapporto quantizzazione/prestazioni adatto per RAM di sistema:\n" 22 90 6 \
        "1" "[1.5B] Qwen2.5-Coder (Richiede ~1.5GB RAM) - Velocissimo per test/script" \
        "2" "[3.0B] Llama-3.2-Instruct (Richiede ~3.0GB RAM) - Bilanciato, buon ragionamento" \
        "3" "[7.0B] Qwen2.5-Coder (Richiede ~5.5GB RAM) - Lento su CPU, logica avanzata" \
        "4" "[8.0B] Llama-3.1-Instruct (Richiede ~6.0GB RAM) - General Purpose Standard" \
        "5" "Inserimento Manuale (Incolla un URL diretto al file .gguf)" \
        "6" "Annulla e Torna Indietro" \
        3>&1 1>&2 2>&3)

    local model_url=""
    
    case "$choice" in
        1) model_url="https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf" ;;
        2) model_url="https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf" ;;
        3) model_url="https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf" ;;
        4) model_url="https://huggingface.co/QuantFactory/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct.Q4_K_M.gguf" ;;
        5) model_url=$(whiptail --title "URL Personalizzato" --inputbox "Inserisci l'URL diretto del file (deve terminare in .gguf):" 10 80 "" 3>&1 1>&2 2>&3) ;;
        *) return ;;
    esac

    if [[ -n "${model_url}" ]]; then
        print_header "Download Modello in Corso"
        local filename
        filename=$(basename "${model_url}" | cut -d? -f1)
        
        log_info "Scaricamento di: ${filename}"
        log_info "Destinazione: ${MODELS_DIR}/${filename}"
        
        # Mostra barra di progresso nativa di wget
        wget --progress=dot:giga -O "${MODELS_DIR}/${filename}" "${model_url}"
        
        # Aggiorna il symlink al nuovo modello di default
        ln -sf "${MODELS_DIR}/${filename}" "${MODELS_DIR}/model.gguf"
        
        log_info "Download completato. Collegamento simbolico (model.gguf) aggiornato."
        if systemctl is-active --quiet "${SERVICE_NAME}"; then
            log_info "Riavvio del servizio backend per caricare il nuovo modello in RAM..."
            systemctl restart "${SERVICE_NAME}"
        fi
        pause
    fi
}

# ------------------------------------------------------------------------------
# Fase 5: Gestione Log Estesa
# ------------------------------------------------------------------------------
manage_logs() {
    while true; do
        local log_size
        if [[ -f "${LOG_FILE}" ]]; then
            log_size=$(du -sh "${LOG_FILE}" | cut -f1)
        else
            log_size="0B"
        fi

        local log_action
        log_action=$(whiptail --title "Analisi e Controllo Log di Sistema" \
            --menu "\nFile di log globale: ${LOG_FILE}\nDimensione attuale: ${log_size}\n\nSeleziona un'operazione di audit:" 20 85 5 \
            "1" "Monitoraggio in Tempo Reale (tail -f) [Premi Ctrl+C per uscire]" \
            "2" "Leggi le ultime 100 righe" \
            "3" "Ispeziona Log Completo (tramite 'less')" \
            "4" "Azzera e Svuota il File di Log" \
            "5" "Ritorna al Menu Principale" \
            3>&1 1>&2 2>&3)

        case "$log_action" in
            1) 
                print_header "Monitoraggio Real-Time (${LOG_FILE})"
                echo -e "${C_YELLOW}Premi Ctrl+C per fermare il monitoraggio e tornare al menu.${C_NC}\n"
                # Trap SIGINT in modo temporaneo per non uscire dallo script quando si chiude il tail
                trap '' INT
                tail -f "${LOG_FILE}" || true
                trap 'echo -e "\n\033[1;31m[ERRORE FATALE] Lo script si è interrotto alla riga $LINENO.\033[0m\n"' ERR
                trap - INT
                ;;
            2) 
                print_header "Ultime 100 righe di Log"
                tail -n 100 "${LOG_FILE}"
                pause
                ;;
            3) 
                # Nessun clear qui, 'less' gestisce il proprio buffer di schermo
                less "${LOG_FILE}"
                ;;
            4) 
                > "${LOG_FILE}"
                whiptail --title "Svuotamento Log" --msgbox "Il file ${LOG_FILE} è stato azzerato correttamente." 8 60
                ;;
            *) 
                break 
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Fase 6: Gestione Servizi Systemd
# ------------------------------------------------------------------------------
manage_service_menu() {
    local action
    action=$(whiptail --title "Orchestrazione Servizi Systemd" \
        --menu "\nServizi registrati:\n - Backend: ${SERVICE_NAME}\n - Frontend: homelab-ai-frontend\n\nSeleziona l'azione desiderata:" 20 80 4 \
        "1" "Avvia tutti i servizi (Start)" \
        "2" "Ferma tutti i servizi (Stop)" \
        "3" "Riavvia tutti i servizi (Restart)" \
        "4" "Torna al Menu Principale" \
        3>&1 1>&2 2>&3)
    
    print_header "Esecuzione Comandi Systemd"
    case "$action" in
        1) 
            systemctl start "${SERVICE_NAME}" homelab-ai-frontend 2>/dev/null || true
            log_info "Comando Start inviato ai demoni." 
            pause
            ;;
        2) 
            systemctl stop "${SERVICE_NAME}" homelab-ai-frontend 2>/dev/null || true
            log_info "Comando Stop inviato ai demoni." 
            pause
            ;;
        3) 
            systemctl restart "${SERVICE_NAME}" homelab-ai-frontend 2>/dev/null || true
            log_info "Comando Restart inviato ai demoni." 
            pause
            ;;
        *) ;;
    esac
}

# ------------------------------------------------------------------------------
# Menu Principale TUI
# ------------------------------------------------------------------------------
main_menu() {
    while true; do
        local env_str
        env_str=$(detect_environment)
        
        # Controllo rapido stato servizi
        local status_be="Inattivo"
        local status_fe="Inattivo"
        if systemctl is-active --quiet "${SERVICE_NAME}"; then status_be="Attivo"; fi
        if systemctl is-active --quiet "homelab-ai-frontend"; then status_fe="Attivo"; fi

        local choice
        choice=$(whiptail --title "Homelab AI - Console di Gestione Architettura CPU" \
            --menu "\nAmbiente rilevato: ${env_str}\nStato Backend: [${status_be}] | Stato Frontend: [${status_fe}]\n\nScegliere l'operazione di deployment:" 22 95 7 \
            "1" "Configura e Compila Backend (Llama.cpp - Analisi e Build)" \
            "2" "Configura Frontend Web (Open WebUI - Installazione PIP)" \
            "3" "Gestione Modelli AI (Download GGUF consigliati per CPU)" \
            "4" "Orchestrazione Servizi (Avvia / Ferma / Riavvia)" \
            "5" "Monitoraggio e Analisi Log di Sistema" \
            "6" "Installazione Dipendenze Preliminari (Esegui per prima volta)" \
            "7" "Esci dalla Console" \
            3>&1 1>&2 2>&3)

        case "$choice" in
            1) 
                local be_choice
                be_choice=$(whiptail --title "Librerie Matematiche CPU" --menu "\nSeleziona il set di ottimizzazione per il compilatore:" 15 85 2 \
                    "1" "Nativo (AVX2/AVX-512) - Raccomandato per Hardware Moderno" \
                    "2" "OpenBLAS - Stabilita' per Hardware Legacy" 3>&1 1>&2 2>&3)
                case "$be_choice" in
                    1) compile_llama "native" ;;
                    2) compile_llama "openblas" ;;
                esac
                ;;
            2) install_open_webui ;;
            3) download_model ;;
            4) manage_service_menu ;;
            5) manage_logs ;;
            6) install_dependencies ;;
            7) print_header "Chiusura"; echo -e "Uscita dal sistema di gestione. Arrivederci.\n"; break ;;
            *) break ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Entrypoint
# ------------------------------------------------------------------------------
check_root
init_env
main_menu
