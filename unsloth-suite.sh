#!/bin/bash
# ==============================================================================
# Unsloth + ComfyUI + OpenCode Orchestrator Suite Manager (Debian / LXC)
# ==============================================================================

CONFIG_FILE="$HOME/.unsloth_suite.conf"
INSTALL_DIR="$HOME/ComfyUI"
UNSLOTH_DIR="$HOME/unsloth"
OPENCODE_DIR="$HOME/opencode"
ORCHESTRATOR_PATH="$HOME/unsloth_comfy_orchestrator.py"

SERVICE_NAME="unsloth-orchestrator"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

OPENCODE_SERVICE_NAME="opencode-orchestrator"
OPENCODE_SERVICE_FILE="/etc/systemd/system/${OPENCODE_SERVICE_NAME}.service"

COMFYUI_HOST="http://127.0.0.1:8188"
COMFYUI_CMD_PARAMS="--highvram-up-to 6000 --listen 0.0.0.0 --port 8188"

# Colori per Output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; }

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "=========================================================================="
    echo "  _   _ _  _ ____ _    ____ ____ _  _   ____ _  _ _ ___ ____ "
    echo "  |   | |\ | [__  |    |  | |___ |__|   [__  |  | |  |  |___ "
    echo "  |___| | \| ___] |___ |__| |___ |  |   ___] |__| |  |  |___ "
    echo "                                                             "
    echo "       Unsloth + ComfyUI + OpenCode Orchestration Suite Manager           "
    echo "=========================================================================="
    echo -e "${NC}"
}

# ------------------------------------------------------------------------------
# RILEVAMENTO E GESTIONE DRIVER NVIDIA / CUDA / CONTAINER TOOLKIT
# ------------------------------------------------------------------------------
detect_host_nvidia_version() {
    log_info "Rilevamento versione Driver NVIDIA dall'Host Proxmox/Linux..."
    
    if [ -f "/proc/driver/nvidia/version" ]; then
        HOST_DRIVER_VER=$(grep -oP 'Kernel Module\s+\K[0-9.]+' /proc/driver/nvidia/version)
        HOST_MAJOR_VER=$(echo "$HOST_DRIVER_VER" | cut -d'.' -f1)
        log_info "Driver NVIDIA identificati sull'Host: v$HOST_DRIVER_VER (Branch $HOST_MAJOR_VER)"
    else
        log_warn "Impossibile leggere /proc/driver/nvidia/version."
        log_warn "Verificare che i nodi /dev/nvidia* siano mappati nel file .conf dell'LXC sull'Host."
        HOST_MAJOR_VER=""
    fi
}

install_nvidia_drivers_only() {
    log_info "Installazione User-space Driver NVIDIA..."
    detect_host_nvidia_version
    sudo apt update && sudo apt install -y curl wget gnupg2 software-properties-common

    if [ -n "$HOST_MAJOR_VER" ]; then
        log_info "Installazione pacchetto driver specifico: nvidia-driver-$HOST_MAJOR_VER..."
        sudo apt install -y "nvidia-driver-$HOST_MAJOR_VER" || sudo apt install -y nvidia-driver
    else
        sudo apt install -y nvidia-driver
    fi
}

install_cuda_toolkit_only() {
    log_info "Installazione CUDA Toolkit..."
    sudo apt update && sudo apt install -y nvidia-cuda-toolkit || {
        log_warn "Pacchetto nvidia-cuda-toolkit non trovato, aggiunta repository CUDA ufficiale..."
        wget https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb
        sudo dpkg -i cuda-keyring_1.1-1_all.deb
        sudo apt update
        sudo apt install -y cuda-toolkit
    }
}

install_container_toolkit_only() {
    log_info "Installazione e configurazione NVIDIA Container Toolkit per Docker..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/experimental/deb/libnvidia-container.list | \
      sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
      sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

    sudo apt update
    sudo apt install -y nvidia-container-toolkit

    if command -v docker &> /dev/null; then
        log_info "Configurazione del runtime NVIDIA per Docker daemon..."
        sudo nvidia-ctk runtime configure --runtime=docker
        sudo systemctl restart docker
    else
        log_warn "Docker non rilevato nel sistema. Configurazione runtime saltata."
    fi
}

cmd_install_nvidia_cuda() {
    echo ""
    echo "=========================================================================="
    log_info "INSTALLAZIONE COMPLETA STACK NVIDIA (Matching Host + CUDA + Container Toolkit)"
    echo "=========================================================================="
    install_nvidia_drivers_only
    install_cuda_toolkit_only
    install_container_toolkit_only

    log_info "Verifica rilevamento GPU (nvidia-smi):"
    if command -v nvidia-smi &> /dev/null; then
        nvidia-smi
    else
        log_err "nvidia-smi non visibile. Verificare il pass-through dei dispositivi nel file LXC Host."
    fi
}

menu_nvidia() {
    show_banner
    echo -e "${CYAN}SUB-MENU GESTIONE E INSTALLAZIONE SOFTWARE NVIDIA & CUDA${NC}"
    echo "1) Auto-detect & Install Stack Completo (Driver + CUDA + Container Toolkit)"
    echo "2) Installa Solo User-Space NVIDIA Drivers"
    echo "3) Installa Solo CUDA Toolkit"
    echo "4) Installa Solo NVIDIA Container Toolkit"
    echo "5) Test e Rilevamento GPU (nvidia-smi)"
    echo "6) Torna al Menu Installazione"
    echo ""
    read -p "Seleziona un'opzione [1-6]: " nv_choice

    case $nv_choice in
        1) cmd_install_nvidia_cuda; read -p "Premere INVIO per continuare..." ;;
        2) install_nvidia_drivers_only; read -p "Premere INVIO per continuare..." ;;
        3) install_cuda_toolkit_only; read -p "Premere INVIO per continuare..." ;;
        4) install_container_toolkit_only; read -p "Premere INVIO per continuare..." ;;
        5) detect_host_nvidia_version; nvidia-smi 2>/dev/null || log_err "nvidia-smi non trovato."; read -p "Premere INVIO per continuare..." ;;
        6) return ;;
        *) log_err "Opzione non valida."; sleep 1 ;;
    esac
}

# ------------------------------------------------------------------------------
# CONFIGURAZIONE ENDPOINT E VARIABILI UNSLOTH / OPENCODE
# ------------------------------------------------------------------------------
configure_unsloth_endpoint() {
    echo ""
    echo "=========================================================================="
    log_info "CONFIGURAZIONE SERVER UNSLOTH E OPENCODE"
    echo "=========================================================================="
    echo "Seleziona dove è in esecuzione il server Unsloth (API Endpoint):"
    echo "1) Locale (sullo stesso container LXC - http://127.0.0.1:8000/v1)"
    echo "2) Remoto (inserisci IP o Dominio personalizzato)"
    read -p "Scelta [1/2]: " choice

    case $choice in
        2)
            read -p "Inserisci IP o Dominio del server Unsloth (es. 192.168.1.50): " remote_host
            read -p "Inserisci la porta HTTP del server Unsloth [default: 8000]: " remote_port
            remote_port=${remote_port:-8000}
            remote_host=$(echo "$remote_host" | sed -e 's|^https*://||' -e 's|/$||')
            UNSLOTH_API_URL="http://${remote_host}:${remote_port}/v1"
            ;;
        *)
            UNSLOTH_API_URL="http://127.0.0.1:8000/v1"
            ;;
    esac

    read -p "Inserisci la chiave API (se richiesta da Unsloth) [default: unsloth-secret]: " UNSLOTH_API_KEY
    UNSLOTH_API_KEY=${UNSLOTH_API_KEY:-"unsloth-secret"}

    read -p "Inserisci il nome del modello predefinito per OpenCode [default: unsloth-model]: " OPENCODE_MODEL
    OPENCODE_MODEL=${OPENCODE_MODEL:-"unsloth-model"}

    cat <<EOF > "$CONFIG_FILE"
# Configurazione unsloth-suite.sh
UNSLOTH_API_URL="$UNSLOTH_API_URL"
UNSLOTH_API_KEY="$UNSLOTH_API_KEY"
OPENAI_API_BASE="$UNSLOTH_API_URL"
OPENAI_API_KEY="$UNSLOTH_API_KEY"
OPENCODE_MODEL="$OPENCODE_MODEL"
EOF

    # Esportazione automatica nel .bashrc utente per l'uso immediato da CLI
    sed -i '/# UNSLOTH_SUITE_ENV_START/,/# UNSLOTH_SUITE_ENV_END/d' "$HOME/.bashrc"
    cat <<EOF >> "$HOME/.bashrc"
# UNSLOTH_SUITE_ENV_START
export OPENAI_API_BASE="$UNSLOTH_API_URL"
export OPENAI_API_KEY="$UNSLOTH_API_KEY"
export UNSLOTH_API_URL="$UNSLOTH_API_URL"
export OPENCODE_MODEL="$OPENCODE_MODEL"
# UNSLOTH_SUITE_ENV_END
EOF

    log_info "Configurazione salvata in $CONFIG_FILE e variabili aggiunte a $HOME/.bashrc"
    echo "=========================================================================="
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        UNSLOTH_API_URL="http://127.0.0.1:8000/v1"
        UNSLOTH_API_KEY="unsloth-secret"
        OPENAI_API_BASE="http://127.0.0.1:8000/v1"
        OPENAI_API_KEY="unsloth-secret"
        OPENCODE_MODEL="unsloth-model"
    fi
}

# ------------------------------------------------------------------------------
# GENERAZIONE ORCHESTRATOR PYTHON
# ------------------------------------------------------------------------------
generate_orchestrator_python() {
    log_info "Verifica e generazione dello script Orchestrator ($ORCHESTRATOR_PATH)..."
    cat <<'PYEOF' > "$ORCHESTRATOR_PATH"
import os
import time
import json
import requests
import urllib.request
import urllib.parse

UNSLOTH_API_URL = os.getenv("UNSLOTH_API_URL", "http://127.0.0.1:8000/v1")
COMFYUI_HOST = os.getenv("COMFYUI_HOST", "127.0.0.1:8188")

def ask_unsloth(prompt: str) -> str:
    url = f"{UNSLOTH_API_URL}/chat/completions"
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {os.getenv('UNSLOTH_API_KEY', 'unsloth-secret')}"
    }
    payload = {
        "model": os.getenv("OPENCODE_MODEL", "unsloth-model"),
        "messages": [
            {"role": "system", "content": "Sei un assistente AI specializzato nella creazione di prompt ed esecuzione codice."},
            {"role": "user", "content": prompt}
        ],
        "temperature": 0.7
    }
    try:
        res = requests.post(url, headers=headers, json=payload, timeout=30)
        res.raise_for_status()
        return res.json()["choices"][0]["message"]["content"]
    except Exception as e:
        print(f"[Orchestrator] Errore Unsloth API: {e}")
        return prompt

def generate_image_comfyui(prompt_text: str) -> dict:
    prompt_workflow = {
        "3": {
            "inputs": {
                "seed": int(time.time()),
                "steps": 20,
                "cfg": 7.0,
                "sampler_name": "euler",
                "scheduler": "normal",
                "denoise": 1,
                "model": ["4", 0],
                "positive": ["6", 0],
                "negative": ["7", 0],
                "latent_image": ["5", 0]
            },
            "class_type": "KSampler"
        },
        "4": {
            "inputs": {"ckpt_name": "v1-5-pruned-emaonly.safetensors"},
            "class_type": "CheckpointLoaderSimple"
        },
        "5": {
            "inputs": {"width": 512, "height": 512, "batch_size": 1},
            "class_type": "EmptyLatentImage"
        },
        "6": {
            "inputs": {"text": prompt_text, "clip": ["4", 1]},
            "class_type": "CLIPTextEncode"
        },
        "7": {
            "inputs": {"text": "ugly, blurry, bad quality, distortion", "clip": ["4", 1]},
            "class_type": "CLIPTextEncode"
        },
        "8": {
            "inputs": {"samples": ["3", 0], "vae": ["4", 2]},
            "class_type": "VAEDecode"
        },
        "9": {
            "inputs": {"filename_prefix": "Unsloth_Comfy_Output", "images": ["8", 0]},
            "class_type": "SaveImage"
        }
    }

    p = {"prompt": prompt_workflow}
    data = json.dumps(p).encode('utf-8')
    req = urllib.request.Request(f"http://{COMFYUI_HOST}/prompt", data=data, headers={'Content-Type': 'application/json'})
    try:
        res = urllib.request.urlopen(req)
        result = json.loads(res.read())
        print(f"[Orchestrator] Task inviato a ComfyUI. Prompt ID: {result.get('prompt_id')}")
        return result
    except Exception as e:
        print(f"[Orchestrator] Errore ComfyUI API: {e}")
        return {}

if __name__ == "__main__":
    print(f"==================================================")
    print(f"Orchestrator Servizio Attivo.")
    print(f"Unsloth Target : {UNSLOTH_API_URL}")
    print(f"ComfyUI Target : http://{COMFYUI_HOST}")
    print(f"==================================================")
    
    while True:
        time.sleep(30)
PYEOF
    log_info "File Orchestrator generato con successo in $ORCHESTRATOR_PATH"
}

# ------------------------------------------------------------------------------
# GESTIONE OPENCODE INTERPRETER / STUDIO
# ------------------------------------------------------------------------------
cmd_install_opencode() {
    log_info "Installazione e configurazione di OpenCode Interpreter / Studio..."
    sudo apt update && sudo apt install -y python3-pip python3-venv git curl nodejs npm

    if [ ! -d "$OPENCODE_DIR" ]; then
        mkdir -p "$OPENCODE_DIR"
    fi

    cd "$OPENCODE_DIR"
    if [ ! -d "venv" ]; then
        python3 -m venv venv
    fi

    source venv/bin/activate
    pip install --upgrade pip
    
    pip install open-interpreter opencode-ai requests openai

    configure_unsloth_endpoint
    log_info "OpenCode installato con successo in $OPENCODE_DIR/venv"
}

cmd_service_opencode() {
    load_config
    log_info "Configurazione servizio Systemd per OpenCode daemon ($OPENCODE_SERVICE_NAME)..."

    OPENCODE_WRAPPER="$HOME/start_opencode_wrapper.sh"
    cat <<EOF > "$OPENCODE_WRAPPER"
#!/bin/bash
source $CONFIG_FILE
export OPENAI_API_BASE="$OPENAI_API_BASE"
export OPENAI_API_KEY="$OPENAI_API_KEY"
export UNSLOTH_API_URL="$UNSLOTH_API_URL"
export OPENCODE_MODEL="$OPENCODE_MODEL"

source $OPENCODE_DIR/venv/bin/activate
interpreter --api_base "$OPENAI_API_BASE" --api_key "$OPENAI_API_KEY" --model "$OPENCODE_MODEL" --os
EOF
    chmod +x "$OPENCODE_WRAPPER"

    sudo bash -c "cat <<EOF > $OPENCODE_SERVICE_FILE
[Unit]
Description=OpenCode Studio Unsloth Integration Daemon
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$OPENCODE_DIR
ExecStart=$OPENCODE_WRAPPER
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF"

    sudo systemctl daemon-reload
    sudo systemctl enable "$OPENCODE_SERVICE_NAME"
    log_info "Servizio systemd '$OPENCODE_SERVICE_NAME' registrato con successo!"
}

menu_opencode() {
    show_banner
    echo -e "${CYAN}SUB-MENU GESTIONE OPENCODE INTERPRETER / STUDIO${NC}"
    echo "1) Installa OpenCode Interpreter e pacchetti correlati"
    echo "   -> Installa l'ambiente Python, Node.js e le librerie client."
    echo "2) Configura Variabili d'Ambiente Unsloth per OpenCode"
    echo "   -> Configura OPENAI_API_BASE, OPENAI_API_KEY e il modello target."
    echo "3) Installa e Registra Servizio Systemd OpenCode"
    echo "   -> Registra opencode-orchestrator.service per l'esecuzione in background."
    echo "4) Avvia Servizio OpenCode"
    echo "5) Arresta Servizio OpenCode"
    echo "6) Torna al Menu Principale"
    echo ""
    read -p "Seleziona un'opzione [1-6]: " oc_choice

    case $oc_choice in
        1) cmd_install_opencode; read -p "Premere INVIO per continuare..." ;;
        2) configure_unsloth_endpoint; read -p "Premere INVIO per continuare..." ;;
        3) cmd_service_opencode; read -p "Premere INVIO per continuare..." ;;
        4) sudo systemctl start "$OPENCODE_SERVICE_NAME"; sudo systemctl status "$OPENCODE_SERVICE_NAME" --no-pager; read -p "Premere INVIO per continuare..." ;;
        5) sudo systemctl stop "$OPENCODE_SERVICE_NAME"; log_info "Servizio OpenCode arrestato."; read -p "Premere INVIO per continuare..." ;;
        6) return ;;
        *) log_err "Opzione non valida."; sleep 1 ;;
    esac
}

# ------------------------------------------------------------------------------
# INSTALLAZIONI APPLICAZIONI
# ------------------------------------------------------------------------------
cmd_install_unsloth_local() {
    log_info "Installazione di Unsloth nel container LXC..."
    sudo apt update && sudo apt install -y python3-pip python3-venv git
    
    if [ ! -d "$UNSLOTH_DIR" ]; then
        mkdir -p "$UNSLOTH_DIR"
    fi
    
    cd "$UNSLOTH_DIR"
    if [ ! -d "venv" ]; then
        python3 -m venv venv
    fi
    
    source venv/bin/activate
    pip install --upgrade pip
    pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
    pip install unsloth xformers trl peft accelerate bitsandbytes
    
    log_info "Unsloth installato con successo in $UNSLOTH_DIR/venv"
}

cmd_install_comfyui() {
    log_info "Installazione di ComfyUI..."
    sudo apt update && sudo apt install -y git python3-pip python3-venv ffmpeg libsm6 libxext6 wget curl

    if [ -d "$INSTALL_DIR" ]; then
        log_warn "ComfyUI risulta già presente in $INSTALL_DIR."
    else
        git clone https://github.com/comfyanonymous/ComfyUI.git "$INSTALL_DIR"
    fi

    cd "$INSTALL_DIR"
    if [ ! -d "venv" ]; then
        python3 -m venv venv
    fi

    source venv/bin/activate
    pip install --upgrade pip
    pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
    pip install -r requirements.txt requests websockets Pillow

    MANAGER_DIR="$INSTALL_DIR/custom_nodes/ComfyUI-Manager"
    if [ ! -d "$MANAGER_DIR" ]; then
        log_info "Installazione ComfyUI Manager..."
        git clone https://github.com/ltdrdata/ComfyUI-Manager.git "$MANAGER_DIR"
    fi

    CKPT_DIR="$INSTALL_DIR/models/checkpoints"
    if [ -z "$(ls -A $CKPT_DIR 2>/dev/null)" ]; then
        log_warn "Nessun modello trovato in $CKPT_DIR. Download SD 1.5..."
        wget -P "$CKPT_DIR" https://huggingface.org/runwayml/stable-diffusion-v1-5/resolve/main/v1-5-pruned-emaonly.safetensors
    fi
    log_info "ComfyUI installato con successo!"
}

menu_install() {
    show_banner
    echo -e "${CYAN}SUB-MENU INSTALLAZIONE APPLICAZIONI:${NC}"
    echo "1) Gestione e Installazione Software NVIDIA (Driver / CUDA / Container Toolkit)"
    echo "2) Gestione e Installazione OpenCode Interpreter / Studio"
    echo "3) Installa Unsloth (Locale)"
    echo "4) Installa ComfyUI + Modelli base"
    echo "5) Installa Suite Completa Automated (Unsloth + ComfyUI + OpenCode + Servizi)"
    echo "6) Ritorna al Menu Principale"
    echo ""
    read -p "Seleziona un'opzione [1-6]: " inst_choice

    case $inst_choice in
        1) menu_nvidia ;;
        2) menu_opencode ;;
        3) cmd_install_unsloth_local; read -p "Premere INVIO per continuare..." ;;
        4) cmd_install_comfyui; read -p "Premere INVIO per continuare..." ;;
        5) configure_unsloth_endpoint; generate_orchestrator_python; cmd_install_comfyui; cmd_install_opencode; cmd_service; cmd_service_opencode; read -p "Premere INVIO per continuare..." ;;
        6) return ;;
        *) log_err "Opzione non valida."; sleep 1 ;;
    esac
}

cmd_install() {
    menu_install
}

# ------------------------------------------------------------------------------
# AGGIORNAMENTO, SERVIZI E VERIFICA
# ------------------------------------------------------------------------------
cmd_update() {
    log_info "Aggiornamento ComfyUI e dipendenze..."
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        git pull
        source venv/bin/activate
        pip install -r requirements.txt --upgrade
        if [ -d "$INSTALL_DIR/custom_nodes/ComfyUI-Manager" ]; then
            cd "$INSTALL_DIR/custom_nodes/ComfyUI-Manager"
            git pull
        fi
    fi
    generate_orchestrator_python
    log_info "Aggiornamento completato!"
}

cmd_service() {
    load_config
    log_info "Configurazione ed installazione del servizio systemd Orchestrator..."
    generate_orchestrator_python

    WRAPPER_SCRIPT="$HOME/start_suite_wrapper.sh"
    cat <<EOF > "$WRAPPER_SCRIPT"
#!/bin/bash
source $CONFIG_FILE
export UNSLOTH_API_URL="$UNSLOTH_API_URL"
export UNSLOTH_API_KEY="$UNSLOTH_API_KEY"
export COMFYUI_HOST="127.0.0.1:8188"

if ! curl -s "$COMFYUI_HOST" > /dev/null; then
    cd $INSTALL_DIR
    source venv/bin/activate
    python main.py $COMFYUI_CMD_PARAMS &
    sleep 6
fi

cd $INSTALL_DIR
source venv/bin/activate
python3 $ORCHESTRATOR_PATH
EOF
    chmod +x "$WRAPPER_SCRIPT"

    sudo bash -c "cat <<EOF > $SERVICE_FILE
[Unit]
Description=Unsloth + ComfyUI Orchestrator Suite Service
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$HOME
ExecStart=$WRAPPER_SCRIPT
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF"

    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME"
    log_info "Servizio systemd '$SERVICE_NAME' registrato con successo!"
}

cmd_start() {
    log_info "Avvio dei servizi suite systemd..."
    cmd_verify
    sudo systemctl start "$SERVICE_NAME"
    sudo systemctl start "$OPENCODE_SERVICE_NAME" 2>/dev/null || true
    log_info "Stato dei servizi:"
    sudo systemctl status "$SERVICE_NAME" --no-pager
}

cmd_stop() {
    log_info "Arresto dei servizi suite systemd..."
    sudo systemctl stop "$SERVICE_NAME"
    sudo systemctl stop "$OPENCODE_SERVICE_NAME" 2>/dev/null || true
    pkill -f "main.py $COMFYUI_CMD_PARAMS" || true
    log_info "Servizi e processi fermati."
}

cmd_remove() {
    log_info "Rimozione dei servizi systemd..."
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl stop "$OPENCODE_SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$OPENCODE_SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "$SERVICE_FILE" "$OPENCODE_SERVICE_FILE"
    sudo systemctl daemon-reload
    log_info "Servizi rimossi con successo."
}

cmd_verify() {
    load_config
    echo "=========================================================================="
    log_info "VERIFICA AMBIENTE UNSLOTH + COMFYUI + OPENCODE"
    echo "=========================================================================="

    detect_host_nvidia_version

    if command -v nvidia-smi &> /dev/null; then
        log_info "Driver NVIDIA User-space: PRESENTI"
    else
        log_warn "Driver NVIDIA User-space: NON INSTALLATI o nvidia-smi assente."
    fi

    if curl -s --connect-timeout 3 "$UNSLOTH_API_URL/models" > /dev/null; then
        log_info "API Unsloth: ONLINE ($UNSLOTH_API_URL)"
    else
        log_err "API Unsloth: NON RAGGIUNGIBILE ($UNSLOTH_API_URL)"
    fi

    if [ -d "$OPENCODE_DIR" ]; then
        log_info "OpenCode Interpreter: INSTALLATO in $OPENCODE_DIR"
    else
        log_warn "OpenCode Interpreter: NON INSTALLATO."
    fi

    if [ -d "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/main.py" ]; then
        log_info "Installazione ComfyUI: PRESENTE in $INSTALL_DIR"
    else
        log_err "Installazione ComfyUI: MANCANTE."
    fi

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_info "Servizio Orchestrator Systemd: ATTIVO"
    else
        log_warn "Servizio Orchestrator Systemd: INATTIVO."
    fi

    if systemctl is-active --quiet "$OPENCODE_SERVICE_NAME"; then
        log_info "Servizio OpenCode Systemd: ATTIVO"
    else
        log_warn "Servizio OpenCode Systemd: INATTIVO."
    fi
    echo "=========================================================================="
}

# ------------------------------------------------------------------------------
# HELP DETTAGLIATO PER COMMAND-LINE INTERFACE
# ------------------------------------------------------------------------------
show_help() {
    show_banner
    echo -e "${CYAN}USO:${NC}"
    echo "  $0 [COMANDO]"
    echo ""
    echo -e "${CYAN}COMANDI DISPONIBILI:${NC}"
    echo "  (nessun argomento) Menu interattivo grafico ASCII per selezione facilitata."
    echo "  install            Apre il sub-menu d'installazione (NVIDIA, OpenCode, Unsloth, ComfyUI)."
    echo "  install-nvidia     Installa lo stack software NVIDIA completo con auto-detection Host."
    echo "  install-opencode   Installa OpenCode Interpreter e lo configura con l'API Unsloth."
    echo "  verify             Esegue una scansione diagnostica dell'ambiente (NVIDIA, API, OpenCode, ComfyUI, Systemd)."
    echo "  service            Crea e registra i servizi daemon Systemd per Orchestrator e OpenCode."
    echo "  start              Avvia i servizi Systemd per l'intera suite."
    echo "  stop               Arresta i servizi Systemd attivi."
    echo "  update             Aggiorna ComfyUI, ComfyUI-Manager e rigenera lo script Orchestrator Python."
    echo "  remove             Disabilita e rimuove completamente i servizi Systemd dal sistema."
    echo "  -h, --help         Mostra questo messaggio di aiuto ed esce."
    echo ""
    echo -e "${CYAN}ESEMPI DI UTILIZZO:${NC}"
    echo "  ./unsloth-suite.sh                 # Avvia l'interfaccia interattiva"
    echo "  ./unsloth-suite.sh install-opencode # Installa e configura OpenCode con Unsloth"
    echo "  ./unsloth-suite.sh verify          # Controlla la connettività e lo stato dell'hardware"
    echo "  ./unsloth-suite.sh start           # Avvia i daemon di background"
    echo ""
}

# ------------------------------------------------------------------------------
# MENU ASCII INTERATTIVO PRINCIPALE
# ------------------------------------------------------------------------------
interactive_menu() {
    while true; do
        show_banner
        echo -e "${CYAN}MENU PRINCIPALE:${NC}"
        echo "1) Menu Installazione Applicazioni (NVIDIA / OpenCode / Unsloth / ComfyUI)"
        echo "2) Menu Gestione OpenCode Interpreter / Studio"
        echo "3) Verifica Stato Generale (verify)"
        echo "4) Avvia Tutti i Servizi Suite (start)"
        echo "5) Ferma Tutti i Servizi Suite (stop)"
        echo "6) Configura/Installa Servizi Systemd (service)"
        echo "7) Aggiorna ComfyUI e Componenti (update)"
        echo "8) Rimuovi Servizi Systemd (remove)"
        echo "9) Mostra Guida CLI (--help)"
        echo "10) Uscita"
        echo ""
        read -p "Seleziona un'opzione [1-10]: " choice

        case $choice in
            1) menu_install ;;
            2) menu_opencode ;;
            3) cmd_verify; read -p "Premere INVIO per continuare..." ;;
            4) cmd_start; read -p "Premere INVIO per continuare..." ;;
            5) cmd_stop; read -p "Premere INVIO per continuare..." ;;
            6) cmd_service; cmd_service_opencode; read -p "Premere INVIO per continuare..." ;;
            7) cmd_update; read -p "Premere INVIO per continuare..." ;;
            8) cmd_remove; read -p "Premere INVIO per continuare..." ;;
            9) show_help; read -p "Premere INVIO per continuare..." ;;
            10) exit 0 ;;
            *) log_err "Scelta non valida."; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# DISPATCHER ARGOMENTI
# ------------------------------------------------------------------------------
if [ -z "$1" ]; then
    interactive_menu
else
    case "$1" in
        install)          cmd_install ;;
        install-nvidia)   cmd_install_nvidia_cuda ;;
        install-opencode) cmd_install_opencode ;;
        update)           cmd_update ;;
        service)          cmd_service; cmd_service_opencode ;;
        start)            cmd_start ;;
        stop)             cmd_stop ;;
        remove)           cmd_remove ;;
        verify)           cmd_verify ;;
        -h|--help)        show_help ;;
        *)
            echo "Uso: $0 {install|install-nvidia|install-opencode|update|service|start|stop|remove|verify|-h|--help}"
            exit 1
            ;;
    esac
fi
