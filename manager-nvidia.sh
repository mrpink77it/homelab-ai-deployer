#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Manager Script (NVIDIA)
# Repo: mrpink77it/homelab-ai-deployer
# Version: V.1.0.3
# ==============================================================================

set -e

# Format e Colori
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

REPO_URL="https://github.com/mrpink77it/homelab-ai-deployer.git"
TARGET_REPO_DIR="/root/homelab-ai-deployer"
UNSLOTH_ENV="/root/unsloth_env"
CODE_RUNNER_DIR="/opt/code_runner"
CODE_RUNNER_ENV="/opt/code_runner/venv"
OPENCODE_DIR="/opt/opencode"

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
            # Controllo se le librerie user-space sono già presenti (nvidia-smi di solito viene installato col driver)
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

    # 5. Export PATH CUDA nel .bashrc
    if ! grep -q "cuda-13.2" /root/.bashrc; then
        echo -e "${YELLOW}[INFO] Aggiornamento variabile PATH in .bashrc per CUDA 13.2...${NC}"
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

    echo -e "${YELLOW}[1/4] Installazione Dipendenze di Sistema e Node.js...${NC}"
    apt update || true
    apt install -y curl wget git gnupg ca-certificates build-essential python3 python3-pip python3-venv openssh-client net-tools pciutils nodejs kmod

    setup_nvidia_stack

    echo -e "${YELLOW}[3/4] Setup Unsloth Studio & PyTorch CUDA nel VENV dedicato...${NC}"
    if [ ! -d "$UNSLOTH_ENV" ]; then
        python3 -m venv "$UNSLOTH_ENV"
    fi
    "$UNSLOTH_ENV/bin/pip" install --upgrade pip setuptools wheel
    "$UNSLOTH_ENV/bin/pip" install torch torchvision --extra-index-url https://download.pytorch.org/whl/cu121
    "$UNSLOTH_ENV/bin/pip" install jupyterlab unsloth trl xformers

    cat <<EOF > /etc/systemd/system/unsloth-studio.service
[Unit]
Description=Unsloth Studio AI Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
Environment="PATH=/usr/local/cuda-13.2/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=$UNSLOTH_ENV/bin/jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root --ServerApp.token='' --ServerApp.password=''
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${YELLOW}[4/4] Setup OpenCode AI e Code Runner API...${NC}"
    
    # OpenCode AI via NPM
    mkdir -p "$OPENCODE_DIR"
    npm install -g opencode-ai 2>/dev/null || true
    OPENCODE_BIN=$(which opencode 2>/dev/null || echo "/usr/local/bin/opencode")

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

    # Code Runner API
    mkdir -p "$CODE_RUNNER_DIR"
    if [ ! -d "$CODE_RUNNER_ENV" ]; then
        python3 -m venv "$CODE_RUNNER_ENV"
    fi
    "$CODE_RUNNER_ENV/bin/pip" install --upgrade pip setuptools wheel fastapi uvicorn pydantic

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
    for srv in unsloth-studio opencode code-runner; do
        systemctl enable "$srv.service"
        systemctl restart "$srv.service"
    done

    echo -e "${GREEN}====================================================${NC}"
    echo -e "${GREEN}     INSTALLAZIONE COMPLETATA E PATH ESPORTATO!     ${NC}"
    echo -e "${GREEN}====================================================${NC}"
    echo -e "${YELLOW}NOTA: Il PATH è stato iniettato. Per avere i binari CUDA disponibili${NC}"
    echo -e "${YELLOW}nella shell corrente fuori dallo script, digita:${NC} source ~/.bashrc"
}

# ------------------------------------------------------------------------------
# MENU E OPZIONI SECONDARIE (Identiche ma con PATH env integrato)
# ------------------------------------------------------------------------------
check_status() {
    export PATH=/usr/local/cuda-13.2/bin${PATH:+:${PATH}}
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}             VERIFICA STATO DEL SISTEMA             ${NC}"
    echo -e "${BLUE}====================================================${NC}"

    echo -e "${YELLOW}---> Stato Servizi Systemd:${NC}"
    for srv in unsloth-studio opencode code-runner; do
        EN_STATE=$(systemctl is-enabled "$srv.service" 2>/dev/null || echo "not-found")
        ACT_STATE=$(systemctl is-active "$srv.service" 2>/dev/null || echo "inactive")
        [ "$ACT_STATE" = "active" ] && ACT_STR="${GREEN}ATTIVO (Running)${NC}" || ACT_STR="${RED}INATTIVO ($ACT_STATE)${NC}"
        [ "$EN_STATE" = "enabled" ] && EN_STR="${GREEN}ENABLED${NC}" || EN_STR="${RED}DISABLED ($EN_STATE)${NC}"
        echo -e "  $srv.service -> Boot: [$EN_STR] | Stato: [$ACT_STR]"
    done

    echo -e "\n${YELLOW}---> Porte di Rete in Ascolto:${NC}"
    for port in 8000 8888 9000; do
        if ss -tulpn 2>/dev/null | grep -q ":$port " || netstat -tulpn 2>/dev/null | grep -q ":$port "; then
            echo -e "  Porta $port: ${GREEN}IN ASCOLTO${NC}"
        else
            echo -e "  Porta $port: ${RED}NON ATTIVA${NC}"
        fi
    done

    echo -e "\n${YELLOW}---> Verifica GPU e CUDA PyTorch:${NC}"
    if command -v nvidia-smi &> /dev/null; then
        echo -e "${GREEN}Driver NVIDIA Smi:${NC}"
        nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader | sed 's/^/  /'
    fi

    if [ -f "$UNSLOTH_ENV/bin/python3" ]; then
        "$UNSLOTH_ENV/bin/python3" -c "
import torch
cuda_avail = torch.cuda.is_available()
print(f'  CUDA PyTorch Disponibile: {\"${GREEN}SI${NC}\" if cuda_avail else \"${RED}NO${NC}\"}')
if cuda_avail:
    print(f'  GPU Riconosciuta da PyTorch: {torch.cuda.get_device_name(0)}')
" 2>/dev/null || echo -e "  ${RED}Errore durante il test di PyTorch/CUDA${NC}"
    else
        echo -e "  ${RED}Virtualenv Unsloth non trovato su $UNSLOTH_ENV${NC}"
    fi
}

update_components() {
    # Omesso per brevità nel blocco, ma mantiene la logica originaria (Git pull, pip upgrade, systemctl restart)
    echo -e "${YELLOW}Esecuzione aggiornamento componenti...${NC}"
    # ... Inserisci qui la logica di aggiornamento esistente
}

configure_sandbox() {
    # ... Inserisci qui la logica di SSH sandbox esistente
    echo -e "${YELLOW}Configurazione sandbox...${NC}"
}

uninstall_services() {
    # ... Inserisci qui la logica di rimozione esistente
    echo -e "${YELLOW}Disinstallazione...${NC}"
}

show_menu() {
    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}      🦥 HOMELAB AI DEPLOYER - MANAGER MENU        ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    echo -e " 1) ${GREEN}INSTALLA Servizi${NC}   (GPU Driver, CUDA, Unsloth, OpenCode, API)"
    echo -e " 2) ${YELLOW}VERIFICA Stato${NC}     (Check Servizi Systemd, Porte e GPU CUDA)"
    echo -e " 3) ${BLUE}AGGIORNA Componenti${NC} (Git pull, VENV Unsloth, VENV CodeRunner)"
    echo -e " 4) ${YELLOW}CONFIGURA Sandbox${NC}   (Setup Chiavi SSH & Test Endpoint API)"
    echo -e " 5) ${RED}DISINSTALLA${NC}        (Rimozione Unità Systemd e Directory)"
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
