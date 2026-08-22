#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Manager Script (NVIDIA)
# Repo: mrpink77it/homelab-ai-deployer
# Version: V.1.5.7 (Fixed NVIDIA Keyring & CUDA Repository Setup)
# ==============================================================================

set -e

# Format e Colori
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

UNSLOTH_ENV="/root/unsloth_env"
OPENWEBUI_ENV="/opt/openwebui_env"
BACKEND_DIR="/opt/homelab-ai/backend"

# File di configurazione porte persistenti
PORT_CONFIG="/etc/homelab-ai/ports.conf"
mkdir -p /etc/homelab-ai

# Porte predefinite (se non configurate)
if [ ! -f "$PORT_CONFIG" ]; then
    cat <<EOF > "$PORT_CONFIG"
LLAMACPP_PORT=8080
UNSLOTH_PORT=8888
OLLAMA_PORT=11434
OPENWEBUI_PORT=8081
EOF
fi
source "$PORT_CONFIG"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Questo script deve essere eseguito come root!${NC}"
  exit 1
fi

setup_xdg_fix() {
    if ! command -v xdg-open &> /dev/null; then
        ln -sf /bin/true /usr/local/bin/xdg-open
    fi
}

fix_apt_repos() {
    rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list
    rm -f /etc/apt/sources.list.d/cuda*.list
}

return_to_main() {
    clear
    echo -e "${GREEN}Ritorno al menu principale...${NC}"
    sleep 1
    if [ -f "./main.sh" ]; then exec ./main.sh
    elif [ -f "../main.sh" ]; then cd .. && exec ./main.sh
    else exit 0; fi
}

setup_nvidia_stack() {
    if ! command -v nvcc &> /dev/null; then
        UBUNTU_VER=$(lsb_release -rs | tr -d '.')
        
        apt update -qq && apt install -y pciutils kmod build-essential curl wget git lsb-release
        
        if [ ! -f /etc/apt/sources.list.d/cuda.list ]; then
            wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${UBUNTU_VER}/x86_64/cuda-keyring_1.1-1_all.deb -O /tmp/cuda-keyring.deb
            dpkg -i /tmp/cuda-keyring.deb
            rm -f /tmp/cuda-keyring.deb
            apt update -qq
        fi

        apt install -y cuda-toolkit pciutils kmod build-essential

        # Rileva dinamicamente la cartella CUDA installata in /usr/local/
        CUDA_DIR=$(ls -d /usr/local/cuda-* 2>/dev/null | head -n 1)
        if [ -n "$CUDA_DIR" ]; then
            ln -sfn "$CUDA_DIR" /usr/local/cuda
            ln -sf /usr/local/cuda/bin/nvcc /usr/local/bin/nvcc
            echo "/usr/local/cuda/lib64" > /etc/ld.so.conf.d/cuda.conf
            ldconfig 2>/dev/null || true
            export PATH="/usr/local/cuda/bin${PATH:+:${PATH}}"
        fi
    fi
}

# ------------------------------------------------------------------------------
# MODULI DI INSTALLAZIONE
# ------------------------------------------------------------------------------
compile_llamacpp() {
    mkdir -p "$BACKEND_DIR/models"
    if [ ! -d "$BACKEND_DIR/llama.cpp" ]; then
        git clone https://github.com/ggerganov/llama.cpp.git "$BACKEND_DIR/llama.cpp"
    fi
    cd "$BACKEND_DIR/llama.cpp"
    make clean
    make LLAMA_CUDA=1 -j$(nproc)
}

install_unsloth_stack() {
    if [ ! -d "$UNSLOTH_ENV" ]; then python3 -m venv "$UNSLOTH_ENV"; fi
    "$UNSLOTH_ENV/bin/pip" install --upgrade pip wheel "setuptools<82"
    "$UNSLOTH_ENV/bin/pip" install -U "torch<2.12.0" "torchvision<0.27.0" torchaudio --extra-index-url https://download.pytorch.org/whl/cu121
    "$UNSLOTH_ENV/bin/pip" install -U jupyterlab unsloth unsloth-zoo trl xformers
    apt install -y nodejs npm
    npm install -g opencode-ai 2>/dev/null || true
}

install_ollama_webui() {
    if ! command -v ollama &> /dev/null; then
        curl -fsSL https://ollama.com/install.sh | sh
    fi
    if ! command -v uv &> /dev/null; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi
    if [ ! -d "$OPENWEBUI_ENV" ]; then
        uv venv "$OPENWEBUI_ENV"
    fi
    "$OPENWEBUI_ENV/bin/uv" pip install open-webui
}

# ------------------------------------------------------------------------------
# CONFIGURAZIONE SERVIZI FLESSIBILE (Con Checkbox Whiptail)
# ------------------------------------------------------------------------------
configure_and_start_services() {
    source "$PORT_CONFIG"
    
    SELECTED_SERVICES=$(whiptail --title "Gestione Servizi Systemd" \
        --checklist "Seleziona quali componenti attivare nella configurazione:" 20 78 4 \
        "llama-backend" "llama.cpp server (Porta $LLAMACPP_PORT)" ON \
        "unsloth-studio" "Unsloth Jupyter Lab (Porta $UNSLOTH_PORT)" ON \
        "ollama" "Ollama Engine (Porta $OLLAMA_PORT)" OFF \
        "open-webui" "Open WebUI (Porta $OPENWEBUI_PORT)" OFF \
        3>&1 1>&2 2>&3)
        
    if [ $? -ne 0 ]; then
        return
    fi

    source "$PORT_CONFIG"

    if [[ "$SELECTED_SERVICES" == *"llama-backend"* ]]; then
        cat <<EOF > /etc/systemd/system/homelab-ai-backend.service
[Unit]
Description=Homelab AI Backend (llama.cpp)
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=$BACKEND_DIR/llama.cpp
ExecStart=$BACKEND_DIR/llama.cpp/llama-server --host 0.0.0.0 --port $LLAMACPP_PORT -m $BACKEND_DIR/models/default.gguf
Restart=always
[Install]
WantedBy=multi-user.target
EOF
        systemctl enable homelab-ai-backend.service --now
    else
        systemctl stop homelab-ai-backend.service 2>/dev/null || true
        systemctl disable homelab-ai-backend.service 2>/dev/null || true
    fi

    if [[ "$SELECTED_SERVICES" == *"unsloth-studio"* ]]; then
        cat <<EOF > /etc/systemd/system/unsloth-studio.service
[Unit]
Description=Unsloth Studio AI Service
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=$UNSLOTH_ENV/bin/jupyter lab --ip=0.0.0.0 --port=$UNSLOTH_PORT --no-browser --allow-root --ServerApp.token=''
Restart=always
[Install]
WantedBy=multi-user.target
EOF
        systemctl enable unsloth-studio.service --now
    else
        systemctl stop unsloth-studio.service 2>/dev/null || true
        systemctl disable unsloth-studio.service 2>/dev/null || true
    fi

    if [[ "$SELECTED_SERVICES" == *"ollama"* ]]; then
        systemctl enable ollama --now
    else
        systemctl stop ollama 2>/dev/null || true
        systemctl disable ollama 2>/dev/null || true
    fi

    if [[ "$SELECTED_SERVICES" == *"open-webui"* ]]; then
        cat <<EOF > /etc/systemd/system/open-webui.service
[Unit]
Description=Open WebUI Service
After=network.target ollama.service
[Service]
Type=simple
User=root
Environment="PORT=$OPENWEBUI_PORT"
Environment="OLLAMA_BASE_URL=http://127.0.0.1:$OLLAMA_PORT"
ExecStart=$OPENWEBUI_ENV/bin/open-webui serve
Restart=always
[Install]
WantedBy=multi-user.target
EOF
        systemctl enable open-webui.service --now
    else
        systemctl stop open-webui.service 2>/dev/null || true
        systemctl disable open-webui.service 2>/dev/null || true
    fi

    systemctl daemon-reload
    whiptail --title "Successo" --msgbox "Configurazione servizi applicata e avviata correttamente!" 10 60
}

# ------------------------------------------------------------------------------
# GESTIONE PORTE E STATO ATTIVO (Con Cancel uniforme)
# ------------------------------------------------------------------------------
manage_ports() {
    while true; do
        source "$PORT_CONFIG"
        
        local s_llama="CHIUSA"
        ss -tulpn | grep -q ":$LLAMACPP_PORT " && s_llama="ATTIVO"
        local s_unsloth="CHIUSA"
        ss -tulpn | grep -q ":$UNSLOTH_PORT " && s_unsloth="ATTIVO"
        local s_ollama="CHIUSA"
        ss -tulpn | grep -q ":$OLLAMA_PORT " && s_ollama="ATTIVO"
        local s_webui="CHIUSA"
        ss -tulpn | grep -q ":$OPENWEBUI_PORT " && s_webui="ATTIVO"

        PORT_CHOICE=$(whiptail --title "Gestione Porte & Stato Servizi" \
            --menu "Stato attuale e porte configurate:\n\n \
 1. llama.cpp Server  : Porta $LLAMACPP_PORT [$s_llama]\n \
 2. Unsloth Jupyter   : Porta $UNSLOTH_PORT [$s_unsloth]\n \
 3. Ollama Engine     : Porta $OLLAMA_PORT [$s_ollama]\n \
 4. Open WebUI        : Porta $OPENWEBUI_PORT [$s_webui]\n" 22 75 3 \
            "CHANGE" "Modifica una porta di ascolto" \
            "RESTART" "Riavvia i servizi con le porte aggiornate" \
            "BACK" "Torna al menu principale" \
            3>&1 1>&2 2>&3)
            
        if [ $? -ne 0 ]; then break; fi

        case $PORT_CHOICE in
            "CHANGE")
                TARGET_SRV=$(whiptail --title "Cambia Porta" --menu "Seleziona il servizio da modificare:" 15 60 4 \
                    "LLAMACPP_PORT" "llama.cpp (Attuale: $LLAMACPP_PORT)" \
                    "UNSLOTH_PORT" "Unsloth Jupyter (Attuale: $UNSLOTH_PORT)" \
                    "OLLAMA_PORT" "Ollama (Attuale: $OLLAMA_PORT)" \
                    "OPENWEBUI_PORT" "Open WebUI (Attuale: $OPENWEBUI_PORT)" \
                    3>&1 1>&2 2>&3)
                
                if [ $? -ne 0 ] || [ -z "$TARGET_SRV" ]; then
                    continue
                fi

                NEW_PORT=$(whiptail --title "Nuova Porta" --inputbox "Inserisci il nuovo numero di porta per $TARGET_SRV:" 10 50 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$NEW_PORT" ]; then
                    sed -i "s/^${TARGET_SRV}=.*/${TARGET_SRV}=${NEW_PORT}/" "$PORT_CONFIG"
                    whiptail --title "Aggiornato" --msgbox "Porta modificata nel file di configurazione. Ricordati di riavviare i servizi." 10 60
                fi
                ;;
            "RESTART")
                configure_and_start_services
                ;;
            "BACK")
                break
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# DASHBOARD IN BANNER WHIPTAIL
# ------------------------------------------------------------------------------
show_dashboard_banner() {
    source "$PORT_CONFIG"
    local LOCAL_IP
    LOCAL_IP=$(hostname -I | awk '{print $1}')
    
    local st_llama="Spento"
    ss -tulpn | grep -q ":$LLAMACPP_PORT " && st_llama="In ascolto (Porta $LLAMACPP_PORT)"
    local st_unsloth="Spento"
    ss -tulpn | grep -q ":$UNSLOTH_PORT " && st_unsloth="In ascolto (Porta $UNSLOTH_PORT)"
    local st_ollama="Spento"
    ss -tulpn | grep -q ":$OLLAMA_PORT " && st_ollama="In ascolto (Porta $OLLAMA_PORT)"
    local st_webui="Spento"
    ss -tulpn | grep -q ":$OPENWEBUI_PORT " && st_webui="In ascolto (Porta $OPENWEBUI_PORT)"

    local GPU_INFO="Nessuna GPU NVIDIA rilevata"
    if command -v nvidia-smi &> /dev/null; then
        GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader -i 0)
    fi

    local DASH_TEXT="=== HARDWARE & GPU ===\n• IP Locale : $LOCAL_IP\n• GPU        : $GPU_INFO\n\n=== STATO SERVIZI E PORTE ===\n• llama.cpp : $st_llama\n• Unsloth    : $st_unsloth\n• Ollama     : $st_ollama\n• Open WebUI: $st_webui\n\nTutti i servizi attivi operano in parallelo senza conflitti."

    whiptail --title "Dashboard di Sistema - NVIDIA Manager" --msgbox "$DASH_TEXT" 20 75
}

# ------------------------------------------------------------------------------
# BENCHMARK
# ------------------------------------------------------------------------------
run_benchmark() {
    clear
    if [ ! -f "$BACKEND_DIR/llama.cpp/llama-bench" ]; then
        whiptail --title "Errore" --msgbox "llama-bench non trovato. Compila prima llama.cpp." 10 60
        return
    fi
    local MODEL_PATH
    MODEL_PATH=$(find "$BACKEND_DIR/models" -name "*.gguf" | head -n 1)
    clear
    if [ -z "$MODEL_PATH" ]; then
        "$BACKEND_DIR/llama.cpp/llama-bench" -p 512,1024 -n 128
    else
        "$BACKEND_DIR/llama.cpp/llama-bench" -m "$MODEL_PATH" -p 512,1024 -n 128
    fi
    echo -ne "\nPremi INVIO per continuare..."
    read -r
}

# ------------------------------------------------------------------------------
# GESTIONE, DOWNLOAD E ATTIVAZIONE MODELLI (MENU 6 - Con Cancel uniforme)
# ------------------------------------------------------------------------------
manage_models() {
    while true; do
        MODEL_CHOICE=$(whiptail --title "Gestione & Attivazione Modelli GPU" \
            --menu "Scegli l'operazione sui modelli:" 18 75 5 \
            "ACTIVATE_GGUF" "Seleziona e attiva un GGUF su llama.cpp" \
            "OLLAMA_LIST"    "Visualizza modelli locali Ollama" \
            "OLLAMA_PULL"    "Scarica nuovo modello con Ollama (pull)" \
            "DOWNLOAD_GGUF" "Scarica file GGUF da HuggingFace" \
            "BACK"          "Torna al menu principale" \
            3>&1 1>&2 2>&3)
            
        if [ $? -ne 0 ]; then break; fi

        case "$MODEL_CHOICE" in
            "ACTIVATE_GGUF")
                mkdir -p "$BACKEND_DIR/models"
                if [ -z "$(ls -A "$BACKEND_DIR/models"/*.gguf 2>/dev/null)" ]; then
                    whiptail --title "Attenzione" --msgbox "Nessun file GGUF trovato in $BACKEND_DIR/models.\nScaricalo prima usando l'opzione 'Scarica file GGUF da HuggingFace'." 10 60
                    continue
                fi
                
                GGUF_LIST=()
                while IFS= read -r file; do
                    fname=$(basename "$file")
                    fsize=$(du -h "$file" | awk '{print $1}')
                    GGUF_LIST+=("$fname" "Size: $fsize")
                done < <(find "$BACKEND_DIR/models" -maxdepth 1 -name "*.gguf")

                SELECTED_GGUF=$(whiptail --title "Attiva Modello su llama.cpp" --menu "Seleziona il GGUF da mettere in esecuzione:" 20 75 8 "${GGUF_LIST[@]}" 3>&1 1>&2 2>&3)
                
                if [ $? -ne 0 ] || [ -z "$SELECTED_GGUF" ]; then
                    continue
                fi

                SERVICE_FILE="/etc/systemd/system/homelab-ai-backend.service"
                if [ -f "$SERVICE_FILE" ]; then
                    sed -i "s|-m $BACKEND_DIR/models/.*.gguf|-m $BACKEND_DIR/models/$SELECTED_GGUF|" "$SERVICE_FILE"
                    
                    systemctl daemon-reload
                    if systemctl is-active --quiet homelab-ai-backend.service; then
                        systemctl restart homelab-ai-backend.service
                        STATUS_MSG="Modello '$SELECTED_GGUF' attivato e servizio llama.cpp riavviato con successo!"
                    else
                        systemctl enable homelab-ai-backend.service --now
                        STATUS_MSG="Modello '$SELECTED_GGUF' impostato e servizio avviato per la prima volta!"
                    fi
                    
                    whiptail --title "Successo" --msgbox "$STATUS_MSG" 10 60
                else
                    whiptail --title "Errore" --msgbox "Il servizio systemd 'homelab-ai-backend.service' non esiste.\nConfigura prima i servizi tramite il menu principale." 10 60
                fi
                ;;
            "OLLAMA_LIST")
                if ! command -v ollama &> /dev/null; then
                    whiptail --title "Errore" --msgbox "Ollama non risulta installato sul sistema." 8 45
                else
                    OLLAMA_DATA=$(ollama list 2>/dev/null || echo "Ollama non è in esecuzione o nessun modello trovato.")
                    whiptail --title "Modelli Ollama Installati" --msgbox "$OLLAMA_DATA" 22 75
                fi
                ;;
            "OLLAMA_PULL")
                M_NAME=$(whiptail --title "Ollama Pull" --inputbox "Inserisci il nome del modello (es. deepseek-r1:7b, qwen2.5:7b):" 10 60 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$M_NAME" ]; then
                    clear
                    ollama pull "$M_NAME"
                    echo -ne "\nPremi INVIO per continuare..."
                    read -r
                fi
                ;;
            "DOWNLOAD_GGUF")
                URL_GGUF=$(whiptail --title "Download GGUF" --inputbox "Inserisci URL diretto del file GGUF (es. da HuggingFace):" 10 65 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$URL_GGUF" ]; then
                    mkdir -p "$BACKEND_DIR/models"
                    cd "$BACKEND_DIR/models"
                    clear
                    wget -c --show-progress "$URL_GGUF"
                    echo -ne "\nPremi INVIO per continuare..."
                    read -r
                fi
                ;;
            "BACK")
                break
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# MENU PRINCIPALE TUI
# ------------------------------------------------------------------------------
if ! command -v whiptail &> /dev/null; then apt install -y whiptail -qq; fi

while true; do
    CHOICE=$(whiptail --title "Homelab AI Deployer - Manager NVIDIA (v1.5.7)" \
        --menu "\nSeleziona un'operazione:" 22 80 11 \
        "A" "Express Auto-Deploy (Tutto in un click)" \
        "1" "Compila llama.cpp (CUDA)" \
        "2" "Installa Open WebUI & Ollama" \
        "3" "Configura & Avvia Servizi (Scelta Multipla Stack)" \
        "4" "Gestione Porte & Stato Servizi Attivi" \
        "5" "Mostra Dashboard di Sistema (Banner)" \
        "6" "Gestione & Attivazione Modelli (GGUF/Ollama)" \
        "7" "Esegui Benchmark GPU (llama-bench)" \
        "8" "Aggiorna Repository & Componenti" \
        "9" "Disinstalla / Pulizia Completa" \
        "0" "Esci al Menu Principale" \
        3>&1 1>&2 2>&3)
        
    if [ $? -ne 0 ]; then return_to_main; fi

    case "$CHOICE" in
        "A")
            setup_xdg_fix; fix_apt_repos; setup_nvidia_stack
            compile_llamacpp; install_unsloth_stack; install_ollama_webui
            configure_and_start_services
            ;;
        "1") setup_nvidia_stack; compile_llamacpp ;;
        "2") install_ollama_webui ;;
        "3") configure_and_start_services ;;
        "4") manage_ports ;;
        "5") show_dashboard_banner ;;
        "6") manage_models ;;
        "7") run_benchmark ;;
        "8") git pull origin main 2>/dev/null || true ;;
        "9") 
            if (whiptail --title "Conferma" --yesno "Vuoi rimuovere i servizi e ripulire lo stack?" 10 60); then
                systemctl stop homelab-ai-backend unsloth-studio open-webui ollama 2>/dev/null || true
                rm -f /etc/systemd/system/homelab-ai-backend.service /etc/systemd/system/unsloth-studio.service /etc/systemd/system/open-webui.service
                systemctl daemon-reload
                whiptail --title "Completato" --msgbox "Servizi rimossi con successo." 8 50
            fi
            ;;
        "0") return_to_main ;;
    esac
done
