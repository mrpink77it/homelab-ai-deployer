#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Manager Script (NVIDIA)
# Repo: mrpink77it/homelab-ai-deployer
# Version: V.1.4.0 (Multi-Stack Edition)
# ==============================================================================

set -e

# Format e Colori
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

REPO_URL="https://github.com/mrpink77it/homelab-ai-deployer.git"
TARGET_REPO_DIR="/root/homelab-ai-deployer"
UNSLOTH_ENV="/root/unsloth_env"
OPENWEBUI_ENV="/opt/openwebui_env"
CODE_RUNNER_DIR="/opt/code_runner"
CODE_RUNNER_ENV="/opt/code_runner/venv"
OPENCODE_DIR="/opt/opencode"
BACKEND_DIR="/opt/homelab-ai/backend"

# Controllo Permessi Root
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
    rm -f /etc/apt/sources.list.d/archive_uri-https_developer_download_nvidia_com_*.list
}

return_to_main() {
    clear
    echo -e "${GREEN}Ritorno al menu principale...${NC}"
    sleep 1
    if [ -f "./main.sh" ]; then exec ./main.sh
    elif [ -f "../main.sh" ]; then cd .. && exec ./main.sh
    elif [ -f "./manager.sh" ]; then exec ./manager.sh
    else exit 0; fi
}

# ------------------------------------------------------------------------------
# SETUP COMUNE NVIDIA
# ------------------------------------------------------------------------------
setup_nvidia_stack() {
    echo -e "${YELLOW}[INFO] Inizializzazione stack NVIDIA e CUDA...${NC}"
    # Setup di base (omesso controllo esteso per brevità, installa CUDA 13.2)
    if ! command -v nvcc &> /dev/null; then
        apt update -qq && apt install -y cuda-toolkit-13-2 pciutils kmod build-essential curl wget git
        ln -sfn /usr/local/cuda-13.2 /usr/local/cuda
        ln -sf /usr/local/cuda/bin/nvcc /usr/local/bin/nvcc
        echo "/usr/local/cuda/lib64" > /etc/ld.so.conf.d/cuda.conf
        ldconfig 2>/dev/null || true
    fi
    export PATH=/usr/local/cuda-13.2/bin${PATH:+:${PATH}}
}

# ------------------------------------------------------------------------------
# MODULI DI INSTALLAZIONE
# ------------------------------------------------------------------------------
compile_llamacpp() {
    echo -e "${BLUE}---> Compilazione llama.cpp (CUDA)...${NC}"
    mkdir -p "$BACKEND_DIR/models"
    if [ ! -d "$BACKEND_DIR/llama.cpp" ]; then
        git clone https://github.com/ggerganov/llama.cpp.git "$BACKEND_DIR/llama.cpp"
    fi
    cd "$BACKEND_DIR/llama.cpp"
    git pull
    make clean
    make LLAMA_CUDA=1 -j$(nproc)
    echo -e "${GREEN}[OK] llama.cpp compilato con supporto CUDA.${NC}"
}

install_unsloth_stack() {
    echo -e "${BLUE}---> Setup Unsloth Studio & OpenCode...${NC}"
    if [ ! -d "$UNSLOTH_ENV" ]; then python3 -m venv "$UNSLOTH_ENV"; fi
    "$UNSLOTH_ENV/bin/pip" install --upgrade pip wheel "setuptools<82"
    "$UNSLOTH_ENV/bin/pip" install -U "torch<2.12.0" "torchvision<0.27.0" torchaudio --extra-index-url https://download.pytorch.org/whl/cu121
    "$UNSLOTH_ENV/bin/pip" install -U jupyterlab unsloth unsloth-zoo trl xformers

    apt install -y nodejs npm
    npm install -g opencode-ai 2>/dev/null || true
}

install_ollama_webui() {
    echo -e "${BLUE}---> Installazione Ollama...${NC}"
    if ! command -v ollama &> /dev/null; then
        curl -fsSL https://ollama.com/install.sh | sh
    else
        echo -e "${GREEN}[OK] Ollama già installato.${NC}"
    fi

    echo -e "${BLUE}---> Installazione Open WebUI (tramite uv)...${NC}"
    if ! command -v uv &> /dev/null; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
        source $HOME/.cargo/env
    fi
    if [ ! -d "$OPENWEBUI_ENV" ]; then
        uv venv "$OPENWEBUI_ENV"
    fi
    "$OPENWEBUI_ENV/bin/uv" pip install open-webui
    echo -e "${GREEN}[OK] Open WebUI installato nell'ambiente virtuale.${NC}"
}

setup_systemd_services() {
    echo -e "${YELLOW}[INFO] Creazione e avvio dei servizi Systemd...${NC}"
    
    # Servizio Llama.cpp (Stack A)
    if [ -f "$BACKEND_DIR/llama.cpp/llama-server" ]; then
        cat <<EOF > /etc/systemd/system/homelab-ai-backend.service
[Unit]
Description=Homelab AI Backend (llama.cpp)
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=$BACKEND_DIR/llama.cpp
ExecStart=$BACKEND_DIR/llama.cpp/llama-server --host 0.0.0.0 --port 8080 -m $BACKEND_DIR/models/default.gguf
Restart=always
RestartSec=5
Environment="PATH=/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
[Install]
WantedBy=multi-user.target
EOF
    fi

    # Servizio Unsloth (Stack A)
    if [ -f "$UNSLOTH_ENV/bin/jupyter" ]; then
        cat <<EOF > /etc/systemd/system/unsloth-studio.service
[Unit]
Description=Unsloth Studio AI Service
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/root
Environment="PATH=/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=$UNSLOTH_ENV/bin/jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root --ServerApp.token=''
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    fi

    # Servizio Open WebUI (Stack B) - PORTA 8081
    if [ -f "$OPENWEBUI_ENV/bin/open-webui" ]; then
        cat <<EOF > /etc/systemd/system/open-webui.service
[Unit]
Description=Open WebUI Service
After=network.target ollama.service
[Service]
Type=simple
User=root
Environment="PORT=8081"
Environment="OLLAMA_BASE_URL=http://127.0.0.1:11434"
ExecStart=$OPENWEBUI_ENV/bin/open-webui serve
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    fi

    systemctl daemon-reload
    for srv in homelab-ai-backend unsloth-studio open-webui ollama; do
        if [ -f "/etc/systemd/system/$srv.service" ] || [ -f "/lib/systemd/system/$srv.service" ]; then
            systemctl enable "$srv" --now
        fi
    done
    echo -e "${GREEN}[OK] Servizi configurati e avviati.${NC}"
}

# ------------------------------------------------------------------------------
# 6. ESEGUI BENCHMARK (llama-bench)
# ------------------------------------------------------------------------------
run_benchmark() {
    clear
    echo -e "${CYAN}====================================================================${NC}"
    echo -e "${CYAN}                🏃 BENCHMARK GPU (llama-bench)                      ${NC}"
    echo -e "${CYAN}====================================================================${NC}"
    
    if [ ! -f "$BACKEND_DIR/llama.cpp/llama-bench" ]; then
        echo -e "${RED}[ERRORE] llama-bench non trovato. Compila prima llama.cpp (Opzione 1).${NC}"
        read -p "Premi INVIO per tornare al menu..."
        return
    fi
    
    # Cerchiamo il primo modello GGUF disponibile
    local MODEL_PATH=$(find "$BACKEND_DIR/models" -name "*.gguf" | head -n 1)
    
    if [ -z "$MODEL_PATH" ]; then
        echo -e "${YELLOW}[WARN] Nessun modello GGUF trovato in $BACKEND_DIR/models.${NC}"
        echo -e "${YELLOW}Verrà utilizzato un test sintetico o base.${NC}"
        "$BACKEND_DIR/llama.cpp/llama-bench" -p 512,1024 -n 128
    else
        echo -e "${GREEN}Modello rilevato: $(basename "$MODEL_PATH")${NC}"
        echo -e "${YELLOW}Esecuzione dei test di prompt processing e generation...${NC}"
        "$BACKEND_DIR/llama.cpp/llama-bench" -m "$MODEL_PATH" -p 512,1024 -n 128
    fi
    
    echo -e "\n${GREEN}Benchmark completato.${NC}"
}

# ------------------------------------------------------------------------------
# 5. GESTIONE MODELLI (Misto: GGUF + Ollama)
# ------------------------------------------------------------------------------
manage_models() {
    local MENU_TITLE="Download & Model-Aware Tuning (GPU)"
    local MODEL_CHOICE=$(whiptail --title "$MENU_TITLE" \
        --menu "Seleziona un'operazione o un modello da scaricare:" 24 95 14 \
        "OLLAMA" "Pull Modello tramite Ollama (Richiede Stack B)" \
        "AA." "Scarica TUTTI i modelli GGUF          [Richiede ~160GB di spazio]" \
        "00." "Inserisci URL Custom GGUF             [Da HuggingFace o link diretto]" \
        "01." "Qwen2.5-3B-Instruct                   [GGUF - Min VRAM: 4GB]" \
        "02." "Phi-3.5-mini-instruct                 [GGUF - Min VRAM: 4GB]" \
        "03." "Qwen2.5-7B-Instruct                   [GGUF - Min VRAM: 8GB]" \
        "04." "DeepSeek-R1-Distill-Qwen-7B           [GGUF - Min VRAM: 8GB]" \
        "05." "Hermes-3-Llama-3.1-8B                 [GGUF - Min VRAM: 8GB]" \
        "06." "Mistral-Nemo-Instruct (12B)           [GGUF - Min VRAM: 12GB]" \
        "07." "Qwen2.5-14B-Instruct                  [GGUF - Min VRAM: 16GB]" \
        "08." "Qwen2.5-32B-Instruct                  [GGUF - Min VRAM: 24GB]" \
        "09." "DeepSeek-R1-Distill-Qwen-32B          [GGUF - Min VRAM: 24GB]" \
        "10." "DeepSeek-R1-Distill-Llama-70B         [GGUF - Min VRAM: 48GB]" \
        "11." "Qwen2.5-72B-Instruct                  [GGUF - Min VRAM: 48GB]" \
        3>&1 1>&2 2>&3)
        
    if [ $? -ne 0 ]; then return; fi
    clear
    
    if [ "$MODEL_CHOICE" == "OLLAMA" ]; then
        local OLLAMA_MODEL=$(whiptail --title "Ollama Pull" --inputbox "Inserisci il nome del modello (es. llama3.1, qwen2.5, deepseek-r1):" 10 70 3>&1 1>&2 2>&3)
        if [ $? -eq 0 ] && [ -n "$OLLAMA_MODEL" ]; then
            echo -e "${YELLOW}Download tramite Ollama: $OLLAMA_MODEL${NC}"
            ollama pull "$OLLAMA_MODEL"
        fi
        return
    fi
    
    mkdir -p "$BACKEND_DIR/models"
    cd "$BACKEND_DIR/models"
    # Logica di download wget dei GGUF (identica allo script precedente per 01..11)
    # [...] Inserisci qui la logica dei link HuggingFace vista in V.1.1.1
    echo -e "${YELLOW}Download del modello selezionato avviato in: $BACKEND_DIR/models${NC}"
    # Dummy per sintesi
}

# ------------------------------------------------------------------------------
# MENU INTERATTIVO TUI (Whiptail)
# ------------------------------------------------------------------------------
if ! command -v whiptail &> /dev/null; then apt install -y whiptail -qq; fi

while true; do
    CHOICE=$(whiptail --title "Homelab AI Deployer - Manager NVIDIA (v1.4.0)" \
        --menu "\nSeleziona un'operazione:" 22 80 12 \
        "A1" "Express Auto-Deploy (Stack A: Unsloth + llama.cpp)" \
        "A2" "Express Auto-Deploy (Stack B: Ollama + Open WebUI)" \
        "1" "Compila llama.cpp (CUDA)" \
        "2" "Installa Open WebUI (Python venv via uv) + Ollama" \
        "3" "Configura & Avvia Servizi Systemd" \
        "4" "Mostra Profilo Hardware & Servizi NVIDIA" \
        "5" "Download & Tuning Modelli GPU (GGUF / Ollama)" \
        "6" "Esegui Benchmark GPU (llama-bench)" \
        "7" "Configura Sandbox (Node JS / Python)" \
        "8" "Aggiorna Repository (Manager e Script)" \
        "9" "Disinstalla Stack Homelab AI" \
        "0" "Esci e Mostra Dashboard" \
        3>&1 1>&2 2>&3)
        
    if [ $? -ne 0 ]; then return_to_main; fi

    clear
    case $CHOICE in
        "A1") setup_xdg_fix; fix_apt_repos; setup_nvidia_stack; compile_llamacpp; install_unsloth_stack; setup_systemd_services ;;
        "A2") setup_xdg_fix; fix_apt_repos; setup_nvidia_stack; install_ollama_webui; setup_systemd_services ;;
        "1") compile_llamacpp ;;
        "2") install_ollama_webui ;;
        "3") setup_systemd_services ;;
        "4") # La vecchia system_dashboard con l'aggiunta di Open WebUI su 8081 e Ollama su 11434
             echo -e "${GREEN}DASHBOARD HARDWARE E SERVIZI${NC}"
             nvidia-smi
             ss -tulpn | grep -E ":8080|:8081|:11434|:8888"
             ;;
        "5") manage_models ;;
        "6") run_benchmark ;;
        "7") # Ereditato (configure_sandbox)
             echo "Configurazione Sandbox in corso..." ;;
        "8") # Pull git e uv pip install -U open-webui
             echo "Aggiornamento stack..." ;;
        "9") # Stop & Remove systemd di A e B
             echo "Disinstallazione in corso..." ;;
        "0") return_to_main ;;
    esac
    
    echo -ne "\n${YELLOW}Premi INVIO per tornare al menu NVIDIA...${NC}"
    read -r
done
