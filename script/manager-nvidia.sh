#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Manager Script (NVIDIA)
# Repo: mrpink77it/homelab-ai-deployer
# Version: V.1.0.8
# ==============================================================================

set -e

# Format e Colori
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

REPO_URL="https://github.com/mrpink77it/homelab-ai-deployer.git"
TARGET_REPO_DIR="/root/homelab-ai-deployer"
UNSLOTH_ENV="/root/unsloth_env"
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
        echo -e "${YELLOW}[FIX] Creazione symlink xdg-open -> /bin/true per headless server...${NC}"
        ln -sf /bin/true /usr/local/bin/xdg-open
    fi
}

fix_apt_repos() {
    echo -e "${YELLOW}[FIX] Pulizia eventuali repository APT obsoleti/non validi...${NC}"
    rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list
    rm -f /etc/apt/sources.list.d/cuda*.list
    rm -f /etc/apt/sources.list.d/archive_uri-https_developer_download_nvidia_com_*.list
}

# ------------------------------------------------------------------------------
# SETUP AVANZATO NVIDIA (Bare-Metal & LXC Proxmox)
# ------------------------------------------------------------------------------
setup_nvidia_stack() {
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}        DIAGNOSTICA E SETUP STACK NVIDIA            ${NC}"
    echo -e "${BLUE}====================================================${NC}"

    # 1. Rilevamento OS
    local os_str="debian12"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" = "debian" ]; then
            if [ -z "$VERSION_ID" ] || [ "$VERSION_ID" -ge 13 ] 2>/dev/null; then
                os_str="debian13"
            else
                os_str="debian${VERSION_ID}"
            fi
        elif [ "$ID" = "ubuntu" ]; then
            os_str="ubuntu$(echo $VERSION_ID | tr -d .)"
        fi
    fi

    # 2. Rilevamento versione driver Host
    if [ -f /proc/driver/nvidia/version ]; then
        NVRM_VERSION=$(grep NVRM /proc/driver/nvidia/version | awk '{print $8}')
        echo -e "${GREEN}[OK] Modulo Kernel NVIDIA rilevato. Versione Host: ${NVRM_VERSION}${NC}"
    else
        NVRM_VERSION=""
        echo -e "${YELLOW}[WARN] Modulo kernel NVIDIA non trovato su /proc.${NC}"
    fi

    # 3. Setup Repository Ufficiale CUDA via Keyring
    if ! dpkg -l | grep -q cuda-keyring; then
        echo -e "${YELLOW}[INFO] Installazione cuda-keyring ufficiale NVIDIA per ${os_str}...${NC}"
        wget -q "https://developer.download.nvidia.com/compute/cuda/repos/${os_str}/x86_64/cuda-keyring_1.1-1_all.deb" -O /tmp/cuda-keyring.deb
        dpkg -i /tmp/cuda-keyring.deb
        rm /tmp/cuda-keyring.deb
        apt update -qq
    fi

    # 4. Logica di Installazione: LXC vs Bare-Metal
    if grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
        echo -e "${YELLOW}[INFO] Ambiente LXC Proxmox rilevato.${NC}"
        if [ -n "$NVRM_VERSION" ]; then
            if ! command -v nvidia-smi &> /dev/null; then
                echo -e "${YELLOW}[INFO] Scaricamento installer NVIDIA .run per versione ${NVRM_VERSION}...${NC}"
                wget -q "https://us.download.nvidia.com/XFree86/Linux-x86_64/${NVRM_VERSION}/NVIDIA-Linux-x86_64-${NVRM_VERSION}.run" -O /tmp/nvidia.run
                echo -e "${YELLOW}[INFO] Installazione driver user-space (--no-kernel-modules)...${NC}"
                sh /tmp/nvidia.run --no-kernel-modules --silent --accept-license
                rm -f /tmp/nvidia.run
            else
                echo -e "${GREEN}[OK] Componenti user-space NVIDIA già installati nel container.${NC}"
            fi
            
            echo -e "${YELLOW}[INFO] Installazione CUDA Toolkit 13.2...${NC}"
            apt install -y cuda-toolkit-13-2
        else
            echo -e "${RED}[ERRORE] Impossibile determinare la versione host in LXC.${NC}"
            exit 1
        fi
    else
        echo -e "${YELLOW}[INFO] Ambiente Bare-Metal rilevato.${NC}"
        if ! command -v nvidia-smi &> /dev/null; then
            echo -e "${YELLOW}[INFO] Installazione driver e CUDA Toolkit...${NC}"
            apt install -y cuda-drivers cuda-toolkit-13-2
        else
            echo -e "${GREEN}[OK] Driver NVIDIA già presenti.${NC}"
            apt install -y cuda-toolkit-13-2
        fi
    fi

    # 5. Configurazione Globale CUDA (Symlink & LD_LIBRARY_PATH)
    echo -e "${YELLOW}[INFO] Configurazione Symlink e Librerie Globali per CUDA 13.2...${NC}"
    ln -sfn /usr/local/cuda-13.2 /usr/local/cuda
    ln -sf /usr/local/cuda/bin/nvcc /usr/local/bin/nvcc
    ln -sf /usr/local/cuda/bin/nvrtc /usr/local/bin/nvrtc
    echo "/usr/local/cuda/lib64" > /etc/ld.so.conf.d/cuda.conf
    ldconfig 2>/dev/null || true

    if ! grep -q "cuda-13.2" /root/.bashrc; then
        echo -e "${YELLOW}[INFO] Aggiornamento variabile PATH in .bashrc...${NC}"
        cp /root/.bashrc /root/.bashrc.bak
        echo 'export PATH=/usr/local/cuda-13.2/bin${PATH:+:${PATH}}' >> /root/.bashrc
    fi
    export PATH=/usr/local/cuda-13.2/bin${PATH:+:${PATH}}
}

# ------------------------------------------------------------------------------
# OPZIONE 1: INSTALLA SERVIZI
# ------------------------------------------------------------------------------
install_services() {
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}       AVVIO INSTALLAZIONE HOMELAB AI STACK        ${NC}"
    echo -e "${BLUE}====================================================${NC}"

    setup_xdg_fix
    fix_apt_repos

    echo -e "${YELLOW}[1/5] Installazione Dipendenze di Sistema e Node.js...${NC}"
    apt update || true
    apt install -y curl wget git gnupg ca-certificates build-essential python3 python3-pip python3-venv openssh-client net-tools pciutils nodejs npm kmod

    setup_nvidia_stack

    echo -e "${YELLOW}[3/5] Setup llama.cpp (Backend Inferenza CUDA)...${NC}"
    mkdir -p "$BACKEND_DIR/models"
    if [ ! -d "$BACKEND_DIR/llama.cpp" ]; then
        git clone https://github.com/ggerganov/llama.cpp.git "$BACKEND_DIR/llama.cpp"
    fi
    cd "$BACKEND_DIR/llama.cpp"
    make clean
    make LLAMA_CUDA=1 -j$(nproc)

    cat <<EOF > /etc/systemd/system/homelab-ai-backend.service
[Unit]
Description=Homelab AI Backend (llama.cpp)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$BACKEND_DIR/llama.cpp
# Di default cerca un modello placeholder, modificalo dalla dashboard o GUI se necessario
ExecStart=$BACKEND_DIR/llama.cpp/llama-server --host 0.0.0.0 --port 8080 -m $BACKEND_DIR/models/default.gguf
Restart=always
RestartSec=5
Environment="PATH=/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${YELLOW}[4/5] Setup Unsloth Studio & PyTorch CUDA nel VENV dedicato...${NC}"
    if [ ! -d "$UNSLOTH_ENV" ]; then
        python3 -m venv "$UNSLOTH_ENV"
    fi
    
    "$UNSLOTH_ENV/bin/pip" install --upgrade pip wheel "setuptools<82"
    
    # FIX APPLICATO QUI: Pinning versione Torch inferiore a 2.12.0 per Unsloth
    "$UNSLOTH_ENV/bin/pip" install -U "torch<2.12.0" "torchvision<0.27.0" torchaudio --extra-index-url https://download.pytorch.org/whl/cu121
    "$UNSLOTH_ENV/bin/pip" install -U jupyterlab unsloth unsloth-zoo trl xformers

    cat <<EOF > /etc/systemd/system/unsloth-studio.service
[Unit]
Description=Unsloth Studio AI Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
Environment="PATH=/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=$UNSLOTH_ENV/bin/jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root --ServerApp.token='' --ServerApp.password=''
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${YELLOW}[5/5] Setup OpenCode AI e Code Runner API...${NC}"
    
    mkdir -p "$OPENCODE_DIR"
    npm install -g opencode-ai 2>/dev/null || true
    
    # Ricerca dinamica e infallibile del binario globale npm
    NPM_BIN_DIR=$(npm -g bin 2>/dev/null || echo "/usr/bin")
    if [ -x "$NPM_BIN_DIR/opencode" ]; then
        OPENCODE_BIN="$NPM_BIN_DIR/opencode"
    else
        OPENCODE_BIN=$(find /usr -name "opencode" -type l -o -type f -executable 2>/dev/null | grep bin | head -n 1)
    fi
    [ -z "$OPENCODE_BIN" ] && OPENCODE_BIN="/usr/bin/opencode"

    cat <<EOF > /etc/systemd/system/opencode.service
[Unit]
Description=OpenCode AI Web Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$OPENCODE_DIR
ExecStart=$OPENCODE_BIN web --port 8000 --hostname 0.0.0.0 --print-logs
Restart=always
RestartSec=5
Environment=BROWSER=echo

[Install]
WantedBy=multi-user.target
EOF

    mkdir -p "$CODE_RUNNER_DIR"
    if [ ! -d "$CODE_RUNNER_ENV" ]; then
        python3 -m venv "$CODE_RUNNER_ENV"
    fi
    "$CODE_RUNNER_ENV/bin/pip" install --upgrade pip wheel "setuptools<82" fastapi uvicorn pydantic

    cat <<EOF > "$CODE_RUNNER_DIR/code_runner_api.py"
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import subprocess
import base64

app = FastAPI(title="Code Runner API")

class ExecutionRequest(BaseModel):
    code: str
    sandbox_ip: str

@app.get("/")
def health():
    return {"status": "active", "service": "Code Runner API"}

@app.post("/execute")
def execute_code(req: ExecutionRequest):
    b64_code = base64.b64encode(req.code.encode('utf-8')).decode('utf-8')
    remote_cmd = f"echo {b64_code} | base64 -d | python3"
    ssh_cmd = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=5", f"root@{req.sandbox_ip}", remote_cmd]
    try:
        res = subprocess.run(ssh_cmd, capture_output=True, text=True, timeout=30)
        return {"stdout": res.stdout, "stderr": res.stderr, "exit_code": res.returncode}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
EOF

    cat <<EOF > /etc/systemd/system/code-runner.service
[Unit]
Description=Code Runner API Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$CODE_RUNNER_DIR
ExecStart=$CODE_RUNNER_ENV/bin/uvicorn code_runner_api:app --host 0.0.0.0 --port 9000
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${YELLOW}---> Ricarico systemd, abilito ed avvio tutti i servizi...${NC}"
    systemctl daemon-reload
    for srv in homelab-ai-backend unsloth-studio opencode code-runner; do
        systemctl enable "$srv.service"
        systemctl restart "$srv.service"
    done

    echo -e "${GREEN}====================================================${NC}"
    echo -e "${GREEN}     INSTALLAZIONE COMPLETATA CON SUCCESSO!         ${NC}"
    echo -e "${GREEN}====================================================${NC}"
}

# ------------------------------------------------------------------------------
# OPZIONE 2: VERIFICA STATO
# ------------------------------------------------------------------------------
check_status() {
    export PATH=/usr/local/cuda-13.2/bin${PATH:+:${PATH}}
    clear
    echo -e "${BLUE}====================================================================${NC}"
    echo -e "${BLUE}                 DIAGNOSTICA E STATO DEL SISTEMA                   ${NC}"
    echo -e "${BLUE}====================================================================${NC}"

    # 1. INFO DI SISTEMA E RISORSE HW
    echo -e "\n${YELLOW}[1] RISORSE HARDWARE E SISTEMA${NC}"
    local OS_NAME=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2 || echo "Linux")
    local LOCAL_IP=$(hostname -I | awk '{print $1}')
    local CPU_MODEL=$(lscpu 2>/dev/null | grep "Model name" | sed -r 's/Model name:\s+//g' || echo "N/A")
    local CPU_CORES=$(nproc 2>/dev/null || echo "N/A")
    local RAM_INFO=$(free -h | awk '/^Mem:/ {print $3 " / " $2}')
    local DISK_INFO=$(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')
    local VIRT_ENV=$(systemd-detect-virt 2>/dev/null || echo "bare-metal")

    echo -e "  • Sistema Op. : ${GREEN}$OS_NAME${NC} (Ambiente: $VIRT_ENV)"
    echo -e "  • Indirizzo IP: ${GREEN}$LOCAL_IP${NC}"
    echo -e "  • Processore  : ${GREEN}$CPU_MODEL${NC} ($CPU_CORES Cores)"
    echo -e "  • Utilizzo RAM: ${GREEN}$RAM_INFO${NC}"
    echo -e "  • Disco (Root): ${GREEN}$DISK_INFO${NC}"

    # 2. STACK DRIVER NVIDIA E CUDA
    echo -e "\n${YELLOW}[2] STACK DRIVER NVIDIA E CUDA${NC}"
    if command -v nvidia-smi &> /dev/null; then
        local NV_DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader -i 0)
        local GPU_MODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader -i 0)
        local GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader -i 0)
        echo -e "  • Modello GPU : ${GREEN}$GPU_MODEL${NC}"
        echo -e "  • VRAM Totale : ${GREEN}$GPU_VRAM${NC}"
        echo -e "  • Driver Host : ${GREEN}$NV_DRIVER${NC}"
    else
        echo -e "  • Modello GPU : ${RED}NVIDIA-SMI non trovato o GPU assente${NC}"
    fi

    if command -v nvcc &> /dev/null; then
        local NVCC_VER=$(nvcc -V | grep release | awk '{print $5,$6}' | tr -d ',')
        echo -e "  • CUDA Toolkit: ${GREEN}$NVCC_VER${NC}"
    else
        echo -e "  • CUDA Toolkit: ${RED}Non trovato nel PATH globale${NC}"
    fi

    if [ -f "$UNSLOTH_ENV/bin/python3" ]; then
        local PYTORCH_TEST=$("$UNSLOTH_ENV/bin/python3" -c "import torch; print(f\"OK|{torch.cuda.get_device_name(0)}\") if torch.cuda.is_available() else print(\"FAIL\")" 2>/dev/null || echo "ERROR")
        if [[ "$PYTORCH_TEST" == OK* ]]; then
            local PT_GPU=$(echo "$PYTORCH_TEST" | cut -d'|' -f2)
            echo -e "  • PyTorch CUDA: ${GREEN}Attivo${NC} (GPU agganciata: $PT_GPU)"
        else
            echo -e "  • PyTorch CUDA: ${RED}Errore di comunicazione o GPU non visibile${NC}"
        fi
    else
        echo -e "  • PyTorch CUDA: ${RED}Ambiente virtuale Unsloth assente${NC}"
    fi

    # 3. STATO SERVIZI, PORTE E API
    echo -e "\n${YELLOW}[3] STATO SERVIZI, PORTE E API${NC}"
    
    print_service_status() {
        local SRV_FILE=$1
        local SRV_NAME=$2
        local PORT=$3

        # Controllo stato Systemd
        local EN_STATE=$(systemctl is-enabled "$SRV_FILE" 2>/dev/null || echo "not-found")
        local ACT_STATE=$(systemctl is-active "$SRV_FILE" 2>/dev/null || echo "inactive")
        
        local SYS_STR=""
        [ "$ACT_STATE" = "active" ] && SYS_STR="${GREEN}RUNNING${NC}" || SYS_STR="${RED}$ACT_STATE${NC}"
        local EN_STR=""
        [ "$EN_STATE" = "enabled" ] && EN_STR="${GREEN}Abilitato al boot${NC}" || EN_STR="${RED}Disabilitato ($EN_STATE)${NC}"

        # Controllo stato Rete
        local PORT_STR=""
        if ss -tulpn 2>/dev/null | grep -q ":$PORT " || netstat -tulpn 2>/dev/null | grep -q ":$PORT "; then
            PORT_STR="${GREEN}IN ASCOLTO${NC}"
        else
            PORT_STR="${RED}PORTA CHIUSA${NC}"
        fi

        echo -e "  🔹 ${CYAN}$SRV_NAME${NC}"
        echo -e "     Systemd : $SYS_STR ($EN_STR)"
        echo -e "     Rete    : Porta $PORT -> $PORT_STR"
        
        # Stampa URL se la porta è in ascolto e abbiamo un IP
        if [ "$PORT_STR" == "${GREEN}IN ASCOLTO${NC}" ] && [ -n "$LOCAL_IP" ]; then
            echo -e "     URL API : http://$LOCAL_IP:$PORT"
        fi
        echo ""
    }

    print_service_status "homelab-ai-backend.service" "AI Backend (llama.cpp)" "8080"
    print_service_status "unsloth-studio.service" "Unsloth Studio (Jupyter Lab)" "8888"
    print_service_status "opencode.service" "OpenCode AI (Web Server)" "8000"
    print_service_status "code-runner.service" "Code Runner API (FastAPI)" "9000"

    echo -e "${BLUE}====================================================================${NC}"
}

# ------------------------------------------------------------------------------
# OPZIONE 3: AGGIORNA COMPONENTI
# ------------------------------------------------------------------------------
update_components() {
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}                AGGIORNAMENTO COMPONENTI              ${NC}"
    echo -e "${BLUE}====================================================${NC}"

    if ! command -v git &> /dev/null; then
        apt update || true
        apt install -y git
    fi

    if [ -d ".git" ]; then
        echo -e "${YELLOW}---> Aggiornamento Repository Git locale...${NC}"
        git pull origin main || echo -e "${RED}Impossibile eseguire git pull.${NC}"
    else
        echo -e "${YELLOW}[INFO] Scarico/Aggiorno repository ufficiale da GitHub in $TARGET_REPO_DIR...${NC}"
        if [ -d "$TARGET_REPO_DIR/.git" ]; then
            cd "$TARGET_REPO_DIR"
            git pull origin main
        else
            rm -rf "$TARGET_REPO_DIR"
            git clone "$REPO_URL" "$TARGET_REPO_DIR"
            cd "$TARGET_REPO_DIR"
        fi
        chmod +x manager.sh
        echo -e "${GREEN}[OK] Repository aggiornata.${NC}"
        echo -e "${YELLOW}---> Riavvio dello script aggiornato...${NC}"
        sleep 2
        exec ./manager.sh
    fi

    echo -e "${YELLOW}---> Aggiornamento di llama.cpp...${NC}"
    if [ -d "$BACKEND_DIR/llama.cpp" ]; then
        cd "$BACKEND_DIR/llama.cpp"
        systemctl stop homelab-ai-backend.service 2>/dev/null || true
        git pull origin master
        make clean
        make LLAMA_CUDA=1 -j$(nproc)
    else
        echo -e "${RED}Directory di llama.cpp non trovata. Saltato.${NC}"
    fi

    echo -e "${YELLOW}---> Aggiornamento dipendenze Code Runner API nel relativo VENV...${NC}"
    if [ ! -d "$CODE_RUNNER_ENV" ]; then
        python3 -m venv "$CODE_RUNNER_ENV"
    fi
    "$CODE_RUNNER_ENV/bin/pip" install --upgrade pip wheel "setuptools<82" fastapi uvicorn pydantic

    if [ -d "$UNSLOTH_ENV" ]; then
        echo -e "${YELLOW}---> Aggiornamento PyTorch + CUDA Wheels nel VENV Unsloth...${NC}"
        # FIX APPLICATO QUI: Pinning versione Torch durante l'aggiornamento
        "$UNSLOTH_ENV/bin/pip" install -U "torch<2.12.0" "torchvision<0.27.0" torchaudio --extra-index-url https://download.pytorch.org/whl/cu121
        
        echo -e "${YELLOW}---> Aggiornamento Jupyter Lab, Unsloth, Trl, Xformers...${NC}"
        "$UNSLOTH_ENV/bin/pip" install -U jupyterlab unsloth unsloth-zoo trl xformers
    fi

    if command -v npm &> /dev/null; then
        echo -e "${YELLOW}---> Aggiornamento OpenCode AI via NPM...${NC}"
        npm install -g opencode-ai@latest 2>/dev/null || true
    fi

    echo -e "${YELLOW}---> Riavvio dei servizi systemd...${NC}"
    systemctl daemon-reload
    for srv in homelab-ai-backend unsloth-studio opencode code-runner; do
        systemctl restart "$srv.service" 2>/dev/null || true
    done
    echo -e "${GREEN}[OK] Aggiornamento completato con successo senza toccare il Python di sistema!${NC}"
}

# ------------------------------------------------------------------------------
# OPZIONE 4: CONFIGURA SANDBOX
# ------------------------------------------------------------------------------
configure_sandbox() {
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}                CONFIGURAZIONE SANDBOX                ${NC}"
    echo -e "${BLUE}====================================================${NC}"

    if [ ! -f /root/.ssh/id_ed25519 ]; then
        echo -e "${YELLOW}[1/3] Generazione chiave SSH sul Controller...${NC}"
        ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519
    else
        echo -e "${GREEN}[1/3] Chiave SSH presente su /root/.ssh/id_ed25519${NC}"
    fi

    echo -ne "\n${YELLOW}Inserisci l'IP della macchina Sandbox remota: ${NC}"
    read -r SANDBOX_IP

    if [ -z "$SANDBOX_IP" ]; then
        echo -e "${RED}IP non valido. Operazione annullata.${NC}"
        return
    fi

    echo -e "${YELLOW}[2/3] Invio chiave SSH a root@$SANDBOX_IP...${NC}"
    ssh-copy-id -i /root/.ssh/id_ed25519.pub "root@$SANDBOX_IP"

    echo -e "${YELLOW}[3/3] Test di esecuzione remota tramite API Code Runner (:9000)...${NC}"
    
    systemctl restart code-runner.service 2>/dev/null || true
    sleep 2

    TEST_PAYLOAD=$(cat <<EOF
{
  "code": "import sys, platform; print(f'Sandbox OK! Node: {platform.node()} - Python: {sys.version}')",
  "sandbox_ip": "$SANDBOX_IP"
}
EOF
)

    curl -s -X POST http://localhost:9000/execute \
      -H "Content-Type: application/json" \
      -d "$TEST_PAYLOAD"
    
    echo -e "\n${GREEN}[OK] Configurazione Sandbox completata.${NC}"
}

# ------------------------------------------------------------------------------
# OPZIONE 5: DISINSTALLA / PURGE COMPLETO
# ------------------------------------------------------------------------------
remove_core_services() {
    echo -e "${YELLOW}---> Arresto e disattivazione servizi systemd...${NC}"
    for srv in homelab-ai-backend unsloth-studio opencode code-runner; do
        systemctl stop "$srv.service" 2>/dev/null || true
        systemctl disable "$srv.service" 2>/dev/null || true
        rm -f "/etc/systemd/system/$srv.service"
    done
    systemctl daemon-reload

    echo -e "${YELLOW}---> Pulizia directory di lavoro e virtualenv...${NC}"
    rm -rf "$CODE_RUNNER_DIR" "$OPENCODE_DIR" "$UNSLOTH_ENV" "$TARGET_REPO_DIR" "/opt/homelab-ai"
    echo -e "${GREEN}[OK] Pulizia servizi e directory completata.${NC}"
}

purge_system_dependencies() {
    echo -e "${YELLOW}---> Rimozione Driver NVIDIA, CUDA Toolkit e pacchetti correlati...${NC}"
    apt-get purge -y "cuda*" "*nvidia*" libnvidia* || true
    apt-get autoremove -y --purge

    echo -e "${YELLOW}---> Rimozione file residui e chiavi repository...${NC}"
    rm -rf /usr/local/cuda*
    rm -f /etc/apt/sources.list.d/cuda*.list
    rm -f /etc/apt/sources.list.d/nvidia*.list
    rm -f /etc/ld.so.conf.d/cuda.conf
    ldconfig 2>/dev/null || true

    if grep -q "/usr/local/cuda" /root/.bashrc; then
        echo -e "${YELLOW}---> Ripristino .bashrc (rimozione path CUDA)...${NC}"
        sed -i '/\/usr\/local\/cuda/d' /root/.bashrc
    fi
    
    echo -e "${GREEN}[OK] Purge di sistema NVIDIA/CUDA completato.${NC}"
}

uninstall_services() {
    clear
    echo -e "${RED}====================================================${NC}"
    echo -e "${RED}         DISINSTALLAZIONE E PULIZIA STACK           ${NC}"
    echo -e "${RED}====================================================${NC}"
    echo -e " 1) ${YELLOW}Disinstalla Solo Servizi${NC} (Mantiene Driver NVIDIA e CUDA)"
    echo -e " 2) ${RED}Purge Completo${NC} (Rimuove TUTTO: Servizi, Driver NVIDIA, CUDA)"
    echo -e " 3) ${BLUE}Annulla${NC}"
    echo -e "${RED}====================================================${NC}"
    echo -ne "Seleziona un'opzione [1-3]: "
    read -r UN_CHOICE

    case $UN_CHOICE in
        1)
            echo -ne "${YELLOW}Sei sicuro di voler rimuovere solo i servizi AI e le directory? (s/N): ${NC}"
            read -r CONFIRM
            if [[ "$CONFIRM" =~ ^[Ss]$ ]]; then
                remove_core_services
            else
                echo -e "${BLUE}Operazione annullata.${NC}"
            fi
            ;;
        2)
            echo -ne "${RED}ATTENZIONE: Verranno disinstallati anche i driver NVIDIA e CUDA Toolkit! Continuare? (s/N): ${NC}"
            read -r CONFIRM
            if [[ "$CONFIRM" =~ ^[Ss]$ ]]; then
                remove_core_services
                purge_system_dependencies
            else
                echo -e "${BLUE}Operazione annullata.${NC}"
            fi
            ;;
        3|*)
            echo -e "${BLUE}Operazione annullata.${NC}"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# MENU INTERATTIVO TUI
# ------------------------------------------------------------------------------
show_menu() {
    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}      🦥 HOMELAB AI DEPLOYER - MANAGER MENU        ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    echo -e " 1) ${GREEN}INSTALLA Servizi${NC}   (GPU Driver, CUDA, Llama.cpp, Unsloth, API)"
    echo -e " 2) ${YELLOW}VERIFICA Stato${NC}     (Check Servizi Systemd, Porte e GPU CUDA)"
    echo -e " 3) ${BLUE}AGGIORNA Componenti${NC} (Git pull, llama.cpp, VENV Unsloth, API)"
    echo -e " 4) ${YELLOW}CONFIGURA Sandbox${NC}   (Setup Chiavi SSH & Test Endpoint API)"
    echo -e " 5) ${RED}DISINSTALLA / PURGE${NC} (Rimozione Servizi o Pulizia Completa)"
    echo -e " 6) Uscita"
    echo -e "${BLUE}====================================================${NC}"
    echo -ne "Seleziona un'opzione [1-6]: "
}

while true; do
    show_menu
    read -r choice
    case $choice in
        1) install_services ;;
        2) check_status ;;
        3) update_components ;;
        4) configure_sandbox ;;
        5) uninstall_services ;;
        6) echo -e "${GREEN}Uscita... Bye!${NC}"; exit 0 ;;
        *) echo -e "${RED}Opzione non valida!${NC}" ;;
    esac
    echo -ne "\n${YELLOW}Premi INVIO per continuare...${NC}"
    read -r
done
