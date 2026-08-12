#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Manager Script
# Repo: mrpink77it/homelab-ai-deployer
# ==============================================================================

set -e

# Format e Colori
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

UNSLOTH_ENV="/root/unsloth_env"
CODE_RUNNER_DIR="/opt/code_runner"
OPENCODE_DIR="/opt/opencode"

# Controllo Permessi Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Questo script deve essere eseguito come root!${NC}"
  exit 1
fi

# Fix preventivo per xdg-open su ambienti headless LXC/Server
setup_xdg_fix() {
    if ! command -v xdg-open &> /dev/null; then
        echo -e "${YELLOW}[FIX] Creazione symlink xdg-open -> /bin/true per headless server...${NC}"
        ln -sf /bin/true /usr/local/bin/xdg-open
    fi
}

# ------------------------------------------------------------------------------
# FUNZIONE 1: INSTALLA SERVIZI & CONFIGURA SYSTEMD
# ------------------------------------------------------------------------------
install_services() {
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}       AVVIO INSTALLAZIONE HOMELAB AI STACK        ${NC}"
    echo -e "${BLUE}====================================================${NC}"

    # Fix per xdg-open (evita crash ENOENT su Bun/OpenCode in LXC/Server)
    setup_xdg_fix

    # 1. Aggiornamento Sistema e Dipendenze Base
    echo -e "${YELLOW}[1/5] Aggiornamento pacchetti di sistema e dipendenze...${NC}"
    apt update && apt install -y curl wget git build-essential python3 python3-pip python3-venv openssh-client net-tools

    # 2. Configurazione Unsloth Studio Virtualenv & Jupyter Lab (Porta 8888)
    echo -e "${YELLOW}[2/5] Setup Unsloth Studio & Jupyter Lab...${NC}"
    if [ ! -d "$UNSLOTH_ENV" ]; then
        python3 -m venv "$UNSLOTH_ENV"
    fi
    "$UNSLOTH_ENV/bin/pip" install --upgrade pip setuptools wheel
    "$UNSLOTH_ENV/bin/pip" install jupyterlab torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121

    cat <<EOF > /etc/systemd/system/unsloth-studio.service
[Unit]
Description=Unsloth Studio AI Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=$UNSLOTH_ENV/bin/jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root --ServerApp.token='' --ServerApp.password=''
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # 3. Setup OpenCode AI Web Service (Porta 8000)
    echo -e "${YELLOW}[3/5] Setup OpenCode AI Web Service...${NC}"
    mkdir -p "$OPENCODE_DIR"
    
    # Se il binario opencode non è presente in PATH, crea uno stub Python FastAPI
    if ! command -v opencode &> /dev/null && [ ! -f "$OPENCODE_DIR/main.py" ]; then
        cat <<EOF > "$OPENCODE_DIR/main.py"
from fastapi import FastAPI
import uvicorn

app = FastAPI(title="OpenCode AI Web Interface")

@app.get("/")
def read_root():
    return {"status": "online", "service": "OpenCode AI"}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
EOF
        "$UNSLOTH_ENV/bin/pip" install fastapi uvicorn
    fi

    # Configura service systemd per OpenCode
    if command -v opencode &> /dev/null; then
        OPENCODE_BIN=$(which opencode)
        cat <<EOF > /etc/systemd/system/opencode.service
[Unit]
Description=OpenCode AI Web Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=$OPENCODE_BIN web --port 8000 --host 0.0.0.0
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    else
        cat <<EOF > /etc/systemd/system/opencode.service
[Unit]
Description=OpenCode AI Web Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$OPENCODE_DIR
ExecStart=$UNSLOTH_ENV/bin/python3 -m uvicorn main:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    fi

    # 4. Setup Code Runner API Service (Porta 9000)
    echo -e "${YELLOW}[4/5] Setup Code Runner API Service...${NC}"
    mkdir -p "$CODE_RUNNER_DIR"
    if [ ! -f "$CODE_RUNNER_DIR/code_runner_api.py" ]; then
        cat <<EOF > "$CODE_RUNNER_DIR/code_runner_api.py"
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import subprocess

app = FastAPI(title="Code Runner API")

class ExecutionRequest(BaseModel):
    code: str
    sandbox_ip: str

@app.get("/")
def health():
    return {"status": "active", "service": "Code Runner API"}

@app.post("/execute")
def execute_code(req: ExecutionRequest):
    ssh_cmd = [
        "ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=5",
        f"root@{req.sandbox_ip}", f"python3 -c '{req.code}'"
    ]
    try:
        res = subprocess.run(ssh_cmd, capture_output=True, text=True, timeout=30)
        return {"stdout": res.stdout, "stderr": res.stderr, "exit_code": res.returncode}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
EOF
    fi

    cat <<EOF > /etc/systemd/system/code-runner.service
[Unit]
Description=Code Runner API Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$CODE_RUNNER_DIR
ExecStart=/usr/bin/python3 -m uvicorn code_runner_api:app --host 0.0.0.0 --port 9000
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # 5. Ricarico Systemd, Abilito PERMANENTEMENTE all'Avvio (ENABLE) e Avvio i Servizi
    echo -e "${YELLOW}[5/5] Ricarico systemd, abilito ed avvio tutti i servizi...${NC}"
    systemctl daemon-reload
    
    for srv in unsloth-studio opencode code-runner; do
        systemctl enable "$srv.service"
        systemctl restart "$srv.service"
        echo -e "${GREEN}[OK] Servizio $srv.service abilitato e avviato.${NC}"
    done

    echo -e "${GREEN}====================================================${NC}"
    echo -e "${GREEN}     INSTALLAZIONE E CONFIGURAZIONE COMPLETATA!     ${NC}"
    echo -e "${GREEN}====================================================${NC}"
}

# ------------------------------------------------------------------------------
# FUNZIONE 2: VERIFICA STATO SERVIZI E GPU
# ------------------------------------------------------------------------------
check_status() {
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}             VERIFICA STATO DEL SISTEMA             ${NC}"
    echo -e "${BLUE}====================================================${NC}"

    # Stato Servizi Systemd
    echo -e "${YELLOW}---> Stato Servizi Systemd (is-enabled & is-active):${NC}"
    for srv in unsloth-studio opencode code-runner; do
        EN_STATE=$(systemctl is-enabled "$srv.service" 2>/dev/null || echo "not-found")
        ACT_STATE=$(systemctl is-active "$srv.service" 2>/dev/null || echo "inactive")
        
        if [ "$ACT_STATE" = "active" ]; then
            ACT_STR="${GREEN}ATTIVO (Running)${NC}"
        else
            ACT_STR="${RED}INATTIVO ($ACT_STATE)${NC}"
        fi

        if [ "$EN_STATE" = "enabled" ]; then
            EN_STR="${GREEN}ENABLED${NC}"
        else
            EN_STR="${RED}DISABLED ($EN_STATE)${NC}"
        fi

        echo -e "  $srv.service -> Boot: [$EN_STR] | Stato: [$ACT_STR]"
    done

    # Verifica Porte in Ascolto
    echo -e "\n${YELLOW}---> Porte di Rete in Ascolto:${NC}"
    for port in 8000 8888 9000; do
        if ss -tulpn 2>/dev/null | grep -q ":$port " || netstat -tulpn 2>/dev/null | grep -q ":$port "; then
            echo -e "  Porta $port: ${GREEN}IN ASCOLTO${NC}"
        else
            echo -e "  Porta $port: ${RED}NON ATTIVA${NC}"
        fi
    done

    # Verifica Driver GPU / CUDA
    echo -e "\n${YELLOW}---> Verifica GPU e CUDA PyTorch:${NC}"
    if [ -f "$UNSLOTH_ENV/bin/python3" ]; then
        "$UNSLOTH_ENV/bin/python3" -c "
import torch
cuda_avail = torch.cuda.is_available()
print(f'  CUDA Disponibile: {\"${GREEN}SI${NC}\" if cuda_avail else \"${RED}NO${NC}\"}')
if cuda_avail:
    print(f'  GPU Riconosciuta: {torch.cuda.get_device_name(0)}')
" 2>/dev/null || echo -e "  ${RED}Errore durante il test di PyTorch/CUDA${NC}"
    else
        echo -e "  ${RED}Virtualenv Unsloth non trovato su $UNSLOTH_ENV${NC}"
    fi
}

# ------------------------------------------------------------------------------
# FUNZIONE 3: AGGIORNA COMPONENTI
# ------------------------------------------------------------------------------
update_components() {
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}               AGGIORNAMENTO COMPONENTI             ${NC}"
    echo -e "${BLUE}====================================================${NC}"

    echo -e "${YELLOW}---> Aggiornamento Repository Git...${NC}"
    git pull origin main || echo -e "${RED}Impossibile eseguire git pull.${NC}"

    if [ -d "$UNSLOTH_ENV" ]; then
        echo -e "${YELLOW}---> Aggiornamento pacchetti Python...${NC}"
        "$UNSLOTH_ENV/bin/pip" install --upgrade jupyterlab fastapi uvicorn torch
    fi

    echo -e "${YELLOW}---> Riavvio dei servizi systemd...${NC}"
    systemctl daemon-reload
    systemctl restart unsloth-studio opencode code-runner
    echo -e "${GREEN}[OK] Aggiornamento completato e servizi riavviati.${NC}"
}

# ------------------------------------------------------------------------------
# FUNZIONE 4: CONFIGURA SANDBOX
# ------------------------------------------------------------------------------
configure_sandbox() {
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}               CONFIGURAZIONE SANDBOX               ${NC}"
    echo -e "${BLUE}====================================================${NC}"

    if [ ! -f /root/.ssh/id_ed25519 ]; then
        echo -e "${YELLOW}[1/3] Generazione chiave SSH sul Controller...${NC}"
        ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519
    else
        echo -e "${GREEN}[1/3] Chiave SSH presente su /root/.ssh/id_ed25519${NC}"
    fi

    echo -ne "\n${YELLOW}Inserisci l'IP della macchina Sandbox: ${NC}"
    read -r SANDBOX_IP

    if [ -z "$SANDBOX_IP" ]; then
        echo -e "${RED}IP non valido. Operazione annullata.${NC}"
        return
    fi

    echo -e "${YELLOW}[2/3] Invio chiave SSH a root@$SANDBOX_IP...${NC}"
    ssh-copy-id -i /root/.ssh/id_ed25519.pub "root@$SANDBOX_IP"

    echo -e "${YELLOW}[3/3] Test di esecuzione remota tramite API Code Runner (:9000)...${NC}"
    curl -X POST http://localhost:9000/execute \
      -H "Content-Type: application/json" \
      -d "{
        \"code\": \"import sys, platform; print(f'Sandbox OK! Node: {platform.node()} - Python: {sys.version}')\",
        \"sandbox_ip\": \"$SANDBOX_IP\"
      }"
    echo -e "\n${GREEN}[OK] Configurazione Sandbox completata.${NC}"
}

# ------------------------------------------------------------------------------
# FUNZIONE 5: DISINSTALLA SERVIZI
# ------------------------------------------------------------------------------
uninstall_services() {
    echo -e "${RED}====================================================${NC}"
    echo -e "${RED}                DISINSTALLAZIONE STACK             ${NC}"
    echo -e "${RED}====================================================${NC}"
    echo -ne "${YELLOW}Sei sicuro di voler rimuovere tutti i servizi systemd e le configurazioni? (s/N): ${NC}"
    read -r CONFIRM

    if [[ "$CONFIRM" =~ ^[Ss]$ ]]; then
        echo -e "${YELLOW}---> Arresto e disattivazione servizi...${NC}"
        for srv in unsloth-studio opencode code-runner; do
            systemctl stop "$srv.service" 2>/dev/null || true
            systemctl disable "$srv.service" 2>/dev/null || true
            rm -f "/etc/systemd/system/$srv.service"
        done
        systemctl daemon-reload

        echo -e "${YELLOW}---> Pulizia directory di lavoro...${NC}"
        rm -rf "$CODE_RUNNER_DIR" "$OPENCODE_DIR"

        echo -e "${GREEN}[OK] Disinstallazione completata con successo.${NC}"
    else
        echo -e "${BLUE}Operazione annullata.${NC}"
    fi
}

# ------------------------------------------------------------------------------
# MENU INTERATTIVO PRINCIPALE
# ------------------------------------------------------------------------------
show_menu() {
    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}      🦥 HOMELAB AI DEPLOYER - MANAGER MENU        ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    echo -e " 1) ${GREEN}INSTALLA Servizi${NC}   (Setup Unsloth, OpenCode, API & Systemd)"
    echo -e " 2) ${YELLOW}VERIFICA Stato${NC}     (Check Servizi, Boot state, Porte e GPU)"
    echo -e " 3) ${BLUE}AGGIORNA Componenti${NC} (Git pull & Python package update)"
    echo -e " 4) ${YELLOW}CONFIGURA Sandbox${NC}   (Setup Chiavi SSH & Test API :9000)"
    echo -e " 5) ${RED}DISINSTALLA${NC}        (Rimozione Servizi e Directory)"
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
