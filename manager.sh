#!/usr/bin/env bash
# ==============================================================================
# UNSLOTH SUITE MANAGER - v0.5 (12.08.2026)
# Gestore Avanzato Installazione & Disinstallazione Servizi AI (Con Code Runner)
# ==============================================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

LOG_FILE="/tmp/unsloth_install.log"

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

draw_box() {
    local text="$1"
    local width=76
    echo -n "+"
    printf '=%.0s' $(seq 1 $width)
    echo "+"
    echo -e "| ${CYAN}${text}${NC}"
    echo -n "+"
    printf '=%.0s' $(seq 1 $width)
    echo "+"
}

do_uninstall_step() {
    local msg="$1"
    local cmd="$2"
    echo -n -e "  - ${msg}... "
    eval "$cmd" >/dev/null 2>&1 || true
    sleep 0.5
    echo -e "${GREEN}[OK]${NC}"
}

run_guided_step() {
    local title="$1"
    local description="$2"
    local cmd="$3"

    eval "$cmd" > "$LOG_FILE" 2>&1 &
    local pid=$!

    while kill -0 $pid 2>/dev/null; do
        clear
        echo "=============================================================================="
        echo -e "${CYAN} +--------------------------------------------------------------------------+${NC}"
        echo -e "${CYAN} |                    UNSLOTH SUITE MANAGER - INSTALLAZIONE                 |${NC}"
        echo -e "${CYAN} +--------------------------------------------------------------------------+${NC}"
        echo -e "${YELLOW} >> FASE ATTIVA: ${title}${NC}"
        echo "------------------------------------------------------------------------------"
        echo -e "${description}"
        echo "=============================================================================="
        echo -e "${BLUE} Progressione comandi in tempo reale (ultime righe del log):${NC}"
        echo "------------------------------------------------------------------------------"
        tail -n 8 "$LOG_FILE" 2>/dev/null || true
        sleep 0.4
    done

    wait $pid
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        echo ""
        log_ok "Fase completata con successo: ${title}"
        sleep 1
    else
        echo ""
        log_error "Errore riscontrato durante: ${title}"
        echo -e "${RED}Ultime righe del log di errore:${NC}"
        tail -n 15 "$LOG_FILE"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# 1. VERIFICA PRIVILEGI E RILEVAMENTO AMBIENTE
# ------------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    log_error "Questo script deve essere eseguito con i privilegi di root (usa sudo)."
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~${REAL_USER}")

IS_CONTAINER=false
if [ -f /.dockerenv ] || [ -f /run/.containerenv ] || grep -qa 'container=lxc' /proc/1/environ 2>/dev/null || grep -q 'lxc' /proc/1/cgroup 2>/dev/null; then
    IS_CONTAINER=true
fi

# ------------------------------------------------------------------------------
# 2. MENU PRINCIPALE
# ------------------------------------------------------------------------------
clear
echo -e "${CYAN}"
echo "  _    _ _                 _   _       _____         _ _       "
echo " | |  | | |               | | | |     / ____|       (_| |      "
echo " | |  | | |___  ___ _   _| |_| |___ | (M     _   _  _ | |_ ___ "
echo " | |  | | / __|/ __| | | | __| '_ \  \ \   | | | || | | __/ _ \\"
echo " | |__| | \__ \ (__| |_| | |_| | | | .____) | |_| || | | ||  __/"
echo "  \____/|_|___/\___|\__,_|\__|_| |_| \_____/ \__,_| |_|\__\___|"
echo "                                           v0.5 (12.08.2026)   "
echo -e "${NC}"

draw_box "BENVENUTO NEL MANAGER UFFICIALE PER AMBIENTI AI & AUTOMAZIONE"
echo -e " Configurazione di Unsloth Studio e OpenCode AI su Debian/Ubuntu"
echo -e " (Supporto nativo Bare-Metal, Macchine Fisiche o Container LXC/Proxmox)."
echo ""
echo "+------------------------------------------------------------------------------+"
echo "| SELEZIONA OPERAZIONE:                                                        |"
echo "|   1) INSTALLA Servizi (Controller AI + Code Runner API)                     |"
echo "|   2) DISINSTALLA Servizi (Pulizia profonda e rimozione demoni)              |"
echo "+------------------------------------------------------------------------------+"
read -rp "Scelta [1 o 2]: " MAIN_ACTION

if [ "$MAIN_ACTION" == "2" ]; then
    clear
    draw_box "PANNELLO DI DISINSTALLAZIONE SERVIZI"
    echo "Seleziona i servizi da RIMUOVERE (numeri separati da spazio):"
    echo "  1) Unsloth & Unsloth Studio"
    echo "  2) OpenCode AI Web Service"
    echo "  3) Code Runner API (Automazione Sandbox)"
    echo "  4) Tutti i servizi sopra indicati"
    echo "------------------------------------------------------------------------------"
    read -rp "Scelta: " -a UNINSTALL_CHOICES

    UN_UNSLOTH=false
    UN_OPENCODE=false
    UN_RUNNER=false

    for choice in "${UNINSTALL_CHOICES[@]}"; do
        case "$choice" in
            1) UN_UNSLOTH=true ;;
            2) UN_OPENCODE=true ;;
            3) UN_RUNNER=true ;;
            4) UN_UNSLOTH=true; UN_OPENCODE=true; UN_RUNNER=true ;;
            *) log_warn "Opzione '$choice' non valida, ignorata." ;;
        esac
    done

    echo ""
    if [ "$UN_UNSLOTH" = true ]; then
        do_uninstall_step "Arresto Unsloth Studio" "systemctl stop unsloth-studio.service"
        do_uninstall_step "Rimozione systemd Unsloth" "rm -f /etc/systemd/system/unsloth-studio.service"
        do_uninstall_step "Cancellazione venv Unsloth" "rm -rf ${REAL_HOME}/unsloth_env"
    fi
    if [ "$UN_OPENCODE" = true ]; then
        do_uninstall_step "Arresto OpenCode AI" "systemctl stop opencode.service"
        do_uninstall_step "Rimozione systemd OpenCode" "rm -f /etc/systemd/system/opencode.service"
        do_uninstall_step "Rimozione binario OpenCode" "rm -f /usr/local/bin/opencode"
    fi
    if [ "$UN_RUNNER" = true ]; then
        do_uninstall_step "Arresto Code Runner API" "systemctl stop code-runner.service"
        do_uninstall_step "Rimozione systemd Code Runner" "rm -f /etc/systemd/system/code-runner.service"
        do_uninstall_step "Rimozione directory /opt/code_runner" "rm -rf /opt/code_runner"
        do_uninstall_step "Rimozione guida automazione" "rm -f ${REAL_HOME}/README_AUTOMATION.md"
    fi
    systemctl daemon-reload
    log_ok "Disinstallazione completata."
    exit 0
fi

if [ "$MAIN_ACTION" != "1" ]; then
    log_error "Scelta non valida. Uscita."
    exit 1
fi

# ==============================================================================
# FASE PRELIMINARE E INSTALLAZIONE COMPONENTI
# ==============================================================================
clear
run_guided_step \
    "Impostazione Locale e Timezone Predefiniti" \
    "Configurazione automatica dei pacchetti locales su en_US.UTF-8." \
    "apt install -y locales && sed -i '/^# *en_US.UTF-8 UTF-8/s/^# //' /etc/locale.gen && locale-gen en_US.UTF-8 && update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 LANGUAGE=en_US.UTF-8"

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export LANGUAGE="en_US.UTF-8"

# FASE 1-5: Sistema, Driver, UV e Servizi
run_guided_step "Aggiornamento e Pulizia Sistema" "Pulizia repository e full-upgrade." "rm -f /etc/crypto-policies/back-ends/apt-sequoia.config && apt update && apt full-upgrade -y"
run_guided_step "Installazione Utility e Node.js" "Installazione strumenti base e Node.js." "apt install -y curl wget ca-certificates gnupg git build-essential netcat-openbsd mc nvtop htop pciutils python3-full python3-pip python3-venv && (command -v node &> /dev/null || (curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt install -y nodejs))"

# Repository NVIDIA e Driver (Fix SHA1 policy su Debian Trixie/latest)
run_guided_step \
    "Configurazione Repository NVIDIA" \
    "Aggiunta repo CUDA con trust esplicito per evitare errori di firme SHA1 deprecate." \
    "echo 'deb [trusted=yes] https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/ /' > /etc/apt/sources.list.d/cuda-official.list && apt update"

if [ "$IS_CONTAINER" = true ]; then
    DRV_CMD='if [ -f "/proc/driver/nvidia/version" ]; then NVRM_VERSION=$(grep "Kernel Module" /proc/driver/nvidia/version | awk "{print \$8}"); MAJOR_VERSION=$(echo "$NVRM_VERSION" | cut -d"." -f1); apt install -y --allow-unauthenticated "nvidia-utils-${MAJOR_VERSION}" cuda-toolkit || true; else apt install -y --allow-unauthenticated cuda-toolkit; fi'
    DRV_DESC="Ambiente Container rilevato. Configurazione toolkit e userspace."
else
    DRV_DESC="Ambiente Bare-Metal / Macchina Fisica rilevato. Installazione driver completi."
    DRV_CMD='apt install -y --allow-unauthenticated dkms linux-headers-$(uname -r) && echo -e "blacklist nouveau\noptions nouveau modeset=0" > /etc/modprobe.d/blacklist-nouveau.conf && update-initramfs -u && apt install -y --allow-unauthenticated cuda-drivers cuda-toolkit'
fi
run_guided_step "Installazione Driver e Toolkit CUDA" "$DRV_DESC" "$DRV_CMD"

# Astral UV e Unsloth
run_guided_step "Installazione Astral UV" "Installazione package manager in Rust." "curl -LsSf https://astral.sh/uv/install.sh | sh"
export PATH="${REAL_HOME}/.cargo/bin:${PATH}"

UNSLOTH_DIR="${REAL_HOME}/unsloth_env"
run_guided_step "Installazione Unsloth & Studio" "Creazione venv e dipendenze AI." "su - ${REAL_USER} -c 'uv venv ${UNSLOTH_DIR} --python 3.12 --seed && source ${UNSLOTH_DIR}/bin/activate && uv pip install torch==2.5.1 torchvision==0.20.1 torchaudio==2.5.1 --index-url https://download.pytorch.org/whl/cu124 && uv pip install unsloth xformers trl peft accelerate bitsandbytes jupyterlab'"

cat <<EOF > /etc/systemd/system/unsloth-studio.service
[Unit]
Description=Unsloth Studio AI Service
After=network.target
[Service]
Type=simple
User=${REAL_USER}
WorkingDirectory=${REAL_HOME}
ExecStart=${UNSLOTH_DIR}/bin/jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --ServerApp.token='' --ServerApp.password='' --allow-root
Restart=always
[Install]
WantedBy=multi-user.target
EOF

# OpenCode AI
run_guided_step "Installazione OpenCode AI" "Setup servizio web." "curl -fsSL https://opencode.ai/install | bash || npm install -g opencode-ai; if [ -f \"${REAL_HOME}/.opencode/bin/opencode\" ]; then cp \"${REAL_HOME}/.opencode/bin/opencode\" /usr/local/bin/opencode; fi"

cat <<EOF > /etc/systemd/system/opencode.service
[Unit]
Description=OpenCode AI Web Service
After=network.target
[Service]
Type=simple
User=${REAL_USER}
WorkingDirectory=${REAL_HOME}
ExecStart=/usr/local/bin/opencode web --hostname 0.0.0.0 --port 8000
Restart=always
[Install]
WantedBy=multi-user.target
EOF

# FASE 9: Code Runner API & Guida Automazione
run_guided_step \
    "Installazione Code Runner API e Documentazione" \
    "Configurazione dell'API FastAPI su porta 9000 e generazione della guida README_AUTOMATION.md" \
    "mkdir -p /opt/code_runner && apt install -y python3-uvicorn python3-fastapi && \
    cat <<'EOF' > /opt/code_runner/code_runner_api.py
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import subprocess
app = FastAPI()
class CodeRequest(BaseModel):
    code: str
    sandbox_ip: str
@app.post('/execute')
async def execute_code(request: CodeRequest):
    command = f'python3 -c \\"{request.code.replace(\\"\\"\\", \\"\\\\\\"\\")}\\"'
    try:
        result = subprocess.run(
            ['ssh', '-o', 'StrictHostKeyChecking=no', f'root@{request.sandbox_ip}', command],
            capture_output=True, text=True, timeout=30
        )
        return {'stdout': result.stdout, 'stderr': result.stderr, 'exit_code': result.returncode}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
EOF
    cat <<'EOF' > /etc/systemd/system/code-runner.service
[Unit]
Description=AI Code Runner API Service
After=network.target
[Service]
Type=simple
WorkingDirectory=/opt/code_runner
ExecStart=/usr/bin/python3 -m uvicorn code_runner_api:app --host 0.0.0.0 --port 9000
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    cat <<'EOF' > ${REAL_HOME}/README_AUTOMATION.md
# Guida all'Automazione: Architettura Controller-Sandbox
Consulta la documentazione integrata per collegare una seconda macchina fisica o container LXC come esecutore isolato del codice.
EOF
    systemctl daemon-reload && systemctl enable code-runner.service && systemctl restart code-runner.service && \
    chown ${REAL_USER}:${REAL_USER} ${REAL_HOME}/README_AUTOMATION.md"

chown -R "$REAL_USER":"$REAL_USER" "$REAL_HOME"
systemctl daemon-reload && systemctl restart unsloth-studio.service opencode.service

clear
draw_box "INSTALLAZIONE COMPLETATA CON SUCCESSO"
SERVER_IP=$(hostname -I | awk '{print $1}')
[ -z "$SERVER_IP" ] && SERVER_IP="localhost"

echo -e " 1. Unsloth Studio:    http://${SERVER_IP}:8888"
echo -e " 2. OpenCode Web:      http://${SERVER_IP}:8000"
echo -e " 3. Code Runner API:   http://${SERVER_IP}:9000"
echo -e " Guida generata in:    ${REAL_HOME}/README_AUTOMATION.md"
echo "=============================================================================="
