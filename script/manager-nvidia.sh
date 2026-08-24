#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Manager Script (NVIDIA - Ubuntu/Debian Stable Stack)
# Repo: mrpink77it/homelab-ai-deployer
# Version: V.2.2.0 (Ollama Native, Bare-Metal WebUI & Modelli 8GB VRAM)
# ==============================================================================

set -euo pipefail

trap 'echo -e "\n\033[1;31m[ERRORE FATALE] Lo script manager-nvidia.sh si è interrotto alla riga $LINENO. Verifica di averlo avviato con privilegi elevati (sudo).\033[0m\n"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

VERSION="2.2.0"
LOG_FILE="/var/log/homelab-ai-nvidia.log"
INSTALL_DIR="/opt/homelab-ai"
WEBUI_DIR="${INSTALL_DIR}/open-webui"

FRONTEND_SERVICE_FILE="/etc/systemd/system/homelab-ai-frontend.service"
PORT_CONFIG="/etc/homelab-ai/ports.conf"
mkdir -p /etc/homelab-ai

# Inizializzazione porte standard
if [ ! -f "$PORT_CONFIG" ]; then
    cat <<EOF > "$PORT_CONFIG"
OLLAMA_PORT=11434
OPENWEBUI_PORT=8080
EOF
fi
source "$PORT_CONFIG"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    local level="$1"
    local msg="$2"
    if touch "${LOG_FILE}" 2>/dev/null; then
        echo -e "$(date "+%Y-%m-%d %H:%M:%S") [${level}] ${msg}" | tee -a "${LOG_FILE}"
    else
        echo -e "$(date "+%Y-%m-%d %H:%M:%S") [${level}] ${msg}"
    fi
}

log_info() { log "INFO" "${GREEN}$1${NC}"; }
log_warn() { log "WARN" "${YELLOW}$1${NC}"; }
log_err()  { log "ERROR" "${RED}$1${NC}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "Lo script richiede i privilegi di root. Avvialo con sudo."
        exit 1
    fi
}

detect_environment() {
    if [[ -f /proc/1/environ ]] && grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
        echo "LXC (Proxmox)"
    else
        echo "Bare-Metal / Standard VM"
    fi
}

init_env() {
    mkdir -p "$(dirname "$LOG_FILE")" "${WEBUI_DIR}"
    touch "${LOG_FILE}" || true
}

return_to_main() {
    clear
    echo -e "${GREEN}Ritorno al menu principale...${NC}"
    sleep 1
    if [ -f "./main.sh" ]; then exec ./main.sh
    elif [ -f "../main.sh" ]; then cd .. && exec ./main.sh
    else exit 0; fi
}

install_nvidia_drivers_and_cuda() {
    log_info "Avvio procedura di verifica e installazione stack NVIDIA/CUDA..."
    
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y g++ freeglut3-dev build-essential libx11-dev libxmu-dev libxi-dev \
        libglu1-mesa-dev libfreeimage-dev libglfw3-dev wget htop btop nvtop glances \
        git pciutils cmake curl libcurl4-openssl-dev -qq

    local ENV_TYPE=$(detect_environment)
    local HOST_DRIVER_VER=""

    if [ -f /proc/driver/nvidia/version ]; then
        HOST_DRIVER_VER=$(awk '/NVRM version:/ {print $8}' /proc/driver/nvidia/version)
    fi

    if [[ "$ENV_TYPE" == *"LXC"* ]]; then
        if [ -z "$HOST_DRIVER_VER" ]; then
            log_err "LXC rilevato, ma nessun modulo NVIDIA esposto dall'host in /proc/driver/nvidia/version."
            whiptail --title "Errore GPU" --msgbox "Verifica di aver configurato il passthrough su Proxmox." 10 60
            return 1
        fi

        local USER_DRIVER_VER=""
        if command -v nvidia-smi &> /dev/null; then
            USER_DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n 1)
        fi

        if [ "$HOST_DRIVER_VER" != "$USER_DRIVER_VER" ]; then
            log_warn "Disallineamento o assenza driver LXC (Host: $HOST_DRIVER_VER | LXC: ${USER_DRIVER_VER:-N/D})"
            echo -e "${YELLOW}Download e installazione del driver NVIDIA ${HOST_DRIVER_VER} (--no-kernel-modules)...${NC}"
            
            cd /tmp
            rm -f NVIDIA-Linux-*.run
            wget -q --show-progress "https://us.download.nvidia.com/XFree86/Linux-x86_64/${HOST_DRIVER_VER}/NVIDIA-Linux-x86_64-${HOST_DRIVER_VER}.run"
            chmod +x NVIDIA-Linux-x86_64-${HOST_DRIVER_VER}.run
            ./NVIDIA-Linux-x86_64-${HOST_DRIVER_VER}.run --silent --no-kernel-modules
            cd - > /dev/null
        else
            log_info "Driver NVIDIA LXC già installato e allineato all'host Proxmox ($USER_DRIVER_VER)."
        fi
    else
        if ! command -v nvidia-smi &> /dev/null; then
            log_warn "Driver NVIDIA non trovato su sistema Bare-Metal."
            local BARE_DRIVER=$(whiptail --title "Installazione Driver NVIDIA" \
                --inputbox "Inserisci la versione del driver da installare (es. 550.90.07):" 10 60 "550.90.07" 3>&1 1>&2 2>&3)
            
            if [ $? -eq 0 ] && [ -n "$BARE_DRIVER" ]; then
                cd /tmp
                rm -f NVIDIA-Linux-*.run
                wget -q --show-progress "https://us.download.nvidia.com/XFree86/Linux-x86_64/${BARE_DRIVER}/NVIDIA-Linux-x86_64-${BARE_DRIVER}.run"
                chmod +x NVIDIA-Linux-x86_64-${BARE_DRIVER}.run
                ./NVIDIA-Linux-x86_64-${BARE_DRIVER}.run --silent
                cd - > /dev/null
            fi
        else
            log_info "Driver NVIDIA già installato ($(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n 1))."
        fi
    fi

    if ! command -v /usr/local/cuda-13.2/bin/nvcc &> /dev/null; then
        log_info "Installazione di CUDA Toolkit 13.2..."
        cd /tmp
        wget -q --show-progress "https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/cuda-keyring_1.1-1_all.deb"
        dpkg -i cuda-keyring_1.1-1_all.deb
        apt-get update -qq
        apt-get -y install cuda-toolkit-13-2 -qq
        cd - > /dev/null
        
        if [ -f "$HOME/.bashrc" ]; then
            cp "$HOME/.bashrc" "$HOME/.bashrc-backup-cuda"
            if ! grep -q "/usr/local/cuda-13.2/bin" "$HOME/.bashrc"; then
                echo -e "\nexport PATH=/usr/local/cuda-13.2/bin\${PATH:+:\${PATH}}" >> "$HOME/.bashrc"
            fi
        fi
        export PATH=/usr/local/cuda-13.2/bin${PATH:+:${PATH}}
        log_info "CUDA 13.2 installato correttamente."
    else
        log_info "CUDA Toolkit 13.2 risulta già installato."
        export PATH=/usr/local/cuda-13.2/bin${PATH:+:${PATH}}
    fi
}

install_dependencies() {
    export DEBIAN_FRONTEND=noninteractive
    install_nvidia_drivers_and_cuda
    
    log_info "Configurazione e abilitazione repository non-free..."
    
    if grep -q "debian" /etc/os-release; then
        for sfile in /etc/apt/sources.list.d/*.sources; do
            if [ -f "$sfile" ]; then
                if grep -q "^Components:" "$sfile"; then
                    for comp in contrib non-free non-free-firmware; do
                        if ! grep -q "$comp" "$sfile"; then
                            sed -i "/^Components:/ s/$/ $comp/" "$sfile"
                        fi
                    done
                fi
            fi
        done
        if [ -f /etc/apt/sources.list ]; then
            sed -i 's/\bmain\b/main contrib non-free non-free-firmware/g' /etc/apt/sources.list || true
        fi
        for lfile in /etc/apt/sources.list.d/*.list; do
            [ -f "$lfile" ] && sed -i 's/\bmain\b/main contrib non-free non-free-firmware/g' "$lfile" || true
        done
    elif grep -q "ubuntu" /etc/os-release; then
        apt-get install -y software-properties-common -qq || true
        add-apt-repository -y restricted universe multiverse || true
    fi

    apt-get update -qq
    apt-get install -y zstd ffmpeg python3-pip python3-dev whiptail -qq
    log_info "Dipendenze di sistema installate con successo."
}

install_open_webui() {
    source "$PORT_CONFIG"
    log_info "Installazione di Ollama e Open WebUI..."
    if ! command -v zstd &> /dev/null; then apt-get install -y zstd -qq; fi
    if ! command -v ollama &> /dev/null; then curl -fsSL https://ollama.com/install.sh | sh; fi
    if ! command -v uv &> /dev/null; then curl -LsSf https://astral.sh/uv/install.sh | sh; fi

    local UV_BIN="$HOME/.local/bin/uv"
    [ ! -f "$UV_BIN" ] && UV_BIN="/root/.local/bin/uv"

    mkdir -p "$WEBUI_DIR"
    cd "$WEBUI_DIR"

    "$UV_BIN" venv "${WEBUI_DIR}/venv" --python 3.12 --seed --allow-existing
    "${WEBUI_DIR}/venv/bin/python" -m pip install --upgrade pip
    "$UV_BIN" pip install open-webui --python "${WEBUI_DIR}/venv/bin/python"

    cat <<EOF > "${FRONTEND_SERVICE_FILE}"
[Unit]
Description=Homelab AI Frontend Service (Open WebUI)
After=network.target ollama.service

[Service]
Type=simple
User=root
WorkingDirectory=${WEBUI_DIR}
Environment="HOST=0.0.0.0"
Environment="PORT=$OPENWEBUI_PORT"
Environment="WEBUI_PORT=$OPENWEBUI_PORT"
Environment="OLLAMA_BASE_URL=http://127.0.0.1:$OLLAMA_PORT"
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
    systemctl restart homelab-ai-frontend
    log_info "Open WebUI configurato e avviato sulla porta $OPENWEBUI_PORT."
    whiptail --title "Successo" --msgbox "Ollama e Open WebUI installati correttamente!" 10 60
}

download_models() {
    while true; do
        MODEL_CHOICE=$(whiptail --title "Download Modelli Ollama (Max 8GB VRAM)" \
            --menu "Modelli ottimizzati per schede video con 8GB di memoria.\nSeleziona il modello da scaricare:" 21 85 7 \
            "1" "qwen2.5-coder:7b (Sviluppo, Scrittura Codice, Debugging)" \
            "2" "llama3.1:8b (Generale, Ragionamento e Riassunti)" \
            "3" "mistral:7b (Creativo, Veloce, Ottimo per testi)" \
            "4" "llava:7b (Visione Artificiale, Analisi Immagini multimodale)" \
            "5" "nomic-embed-text (Embedding, Essenziale e leggerissimo per RAG)" \
            "6" "Scarica TUTTI i modelli elencati in sequenza" \
            "BACK" "Torna al Menu Principale" 3>&1 1>&2 2>&3)
            
        if [ $? -ne 0 ] || [ "$MODEL_CHOICE" = "BACK" ]; then break; fi

        clear
        echo -e "${CYAN}Avvio download tramite Ollama...${NC}"
        case "$MODEL_CHOICE" in
            1) ollama pull qwen2.5-coder:7b ;;
            2) ollama pull llama3.1:8b ;;
            3) ollama pull mistral:7b ;;
            4) ollama pull llava:7b ;;
            5) ollama pull nomic-embed-text ;;
            6)
                ollama pull qwen2.5-coder:7b
                ollama pull llama3.1:8b
                ollama pull mistral:7b
                ollama pull llava:7b
                ollama pull nomic-embed-text
                ;;
        esac
        echo -e "\n${GREEN}Download completato!${NC}"
        read -rp "Premi INVIO per tornare al menu dei modelli..."
    done
}

manage_service_dashboard() {
    while true; do
        source "$PORT_CONFIG"
        local IP=$(hostname -I | awk '{print $1}')
        [ -z "$IP" ] && IP="127.0.0.1"

        OS_INFO=$(grep -w "PRETTY_NAME" /etc/os-release | cut -d"=" -f2 | tr -d '"')
        if command -v nvidia-smi &> /dev/null; then
            GPU_INFO=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1)
        else
            GPU_INFO="Driver NVIDIA non rilevati o inattivi"
        fi

        check_status() {
            systemctl is-active --quiet "$1" && echo "ATTIVO" || echo "INATTIVO"
        }

        st_ollama=$(check_status "ollama")
        st_webui=$(check_status "homelab-ai-frontend")

        DASH_TEXT="--- Informazioni Hardware e Sistema ---\n"
        DASH_TEXT+="Sistema Operativo: $OS_INFO\n"
        DASH_TEXT+="Scheda Video     : $GPU_INFO\n"
        DASH_TEXT+="Indirizzo IP     : $IP\n\n"
        DASH_TEXT+="--- Endpoint e Stato Servizi ---\n"
        DASH_TEXT+="Ollama     [$st_ollama] : http://$IP:$OLLAMA_PORT\n"
        DASH_TEXT+="Open WebUI [$st_webui] : http://$IP:$OPENWEBUI_PORT\n\n"
        DASH_TEXT+="Seleziona un'azione rapida da eseguire:"

        SRV_CHOICE=$(whiptail --title "Dashboard Servizi & Controllo" \
            --menu "$DASH_TEXT" 24 85 7 \
            "1" "Riavvia Ollama" \
            "2" "Riavvia Open WebUI" \
            "3" "Ferma Ollama" \
            "4" "Ferma Open WebUI" \
            "5" "Avvia Ollama" \
            "6" "Avvia Open WebUI" \
            "BACK" "Torna al Menu Principale" 3>&1 1>&2 2>&3)

        if [ $? -ne 0 ] || [ "$SRV_CHOICE" = "BACK" ]; then break; fi

        case "$SRV_CHOICE" in
            1) systemctl restart ollama ; whiptail --msgbox "Ollama riavviato." 8 40 ;;
            2) systemctl restart homelab-ai-frontend ; whiptail --msgbox "Open WebUI riavviato." 8 40 ;;
            3) systemctl stop ollama ; whiptail --msgbox "Ollama fermato." 8 40 ;;
            4) systemctl stop homelab-ai-frontend ; whiptail --msgbox "Open WebUI fermato." 8 40 ;;
            5) systemctl start ollama ; whiptail --msgbox "Ollama avviato." 8 40 ;;
            6) systemctl start homelab-ai-frontend ; whiptail --msgbox "Open WebUI avviato." 8 40 ;;
        esac
    done
}

run_uninstall() {
    if (whiptail --title "Disinstalla" --yesno "Vuoi fermare e rimuovere i servizi creati?" 10 50); then
        systemctl stop homelab-ai-frontend 2>/dev/null || true
        rm -f "${FRONTEND_SERVICE_FILE}"
        systemctl daemon-reload
        whiptail --msgbox "Servizio frontend rimosso. I modelli e gli ambienti virtuali sono mantenuti in ${INSTALL_DIR}." 10 60
    fi
}

update_repo() {
    if [[ -d "${REPO_ROOT}/.git" ]]; then
        git -C "${REPO_ROOT}" pull origin main || true
        exec "${SCRIPT_DIR}/manager-nvidia.sh"
    fi
}

main_menu() {
    while true; do
        choice=$(whiptail --title "Homelab AI - NVIDIA Management Console (v${VERSION})" \
            --menu "Ambiente: $(detect_environment)\nScegli un'operazione:" 22 80 8 \
            "A" "Express Auto-Deploy (Installa tutto)" \
            "1" "Installa Dipendenze, Driver NVIDIA & CUDA" \
            "2" "Installa Ollama & Open WebUI (Bare-Metal)" \
            "3" "Download Modelli Ollama (Max 8GB VRAM)" \
            "5" "Dashboard Servizi (Stato, Info Sistema, Gestione)" \
            "9" "Visualizza Log di Sistema" \
            "10" "Aggiorna Repository" \
            "0" "Disinstalla Stack / Esci" \
            3>&1 1>&2 2>&3)

        if [ $? -ne 0 ]; then return_to_main; fi

        case "$choice" in
            "A") install_dependencies; install_open_webui ;;
            "1") install_dependencies; read -rp "Premi INVIO per continuare..." ;;
            "2") install_open_webui ;;
            "3") download_models ;;
            "5") manage_service_dashboard ;;
            "9") clear; tail -n 50 "${LOG_FILE}" || true; read -rp "Premi INVIO per continuare..." ;;
            "10") update_repo ;;
            "0") run_uninstall; exit 0 ;;
            *) return_to_main ;;
        esac
    done
}

check_root
init_env
main_menu
