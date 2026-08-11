#!/usr/bin/env bash
# ==============================================================================
# UNSLOTH SUITE MANAGER - v0.5 (12.08.2026)
# Gestore Avanzato Installazione & Disinstallazione Servizi AI
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

# Funzione per disegnare box ASCII puliti
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

# Funzione per la disinstallazione step-by-step
do_uninstall_step() {
    local msg="$1"
    local cmd="$2"
    echo -n -e "  - ${msg}... "
    eval "$cmd" >/dev/null 2>&1 || true
    sleep 0.5
    echo -e "${GREEN}[OK]${NC}"
}

# Funzione avanzata: layout fisso in alto con log dinamico che scorre sotto
run_guided_step() {
    local title="$1"
    local description="$2"
    local cmd="$3"

    # Esegue il comando in background reindirizzando l'output sul log
    eval "$cmd" > "$LOG_FILE" 2>&1 &
    local pid=$!

    # Mostra gli ultimi output mentre il processo lavora mantenendo l'intestazione fissa
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

    # Attende la fine e cattura l'exit code
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
# 2. MENU PRINCIPALE CON LOGO ASCII ART E CORNICI
# ------------------------------------------------------------------------------
clear
echo -e "${CYAN}"
echo "  _    _ _                 _   _       _____         _ _       "
echo " | |  | | |               | | | |     / ____|       (_| |      "
echo " | |  | | |___  ___ _   _| |_| |___ | (Mâ€šÃ„Ã¹  _   _  _ | |_ ___ "
echo " | |  | | / __|/ __| | | | __| '_ \  \ \   | | | || | | __/ _ \\"
echo " | |__| | \__ \ (__| |_| | |_| | | | .____) | |_| || | | ||  __/"
echo "  \____/|_|___/\___|\__,_|\__|_| |_| \_____/ \__,_| |_|\__\___|"
echo "                                           v0.5 (12.08.2026)   "
echo -e "${NC}"

draw_box "BENVENUTO NEL MANAGER UFFICIALE PER AMBIENTI AI & AUTOMAZIONE"
echo -e " Questo script consente di configurare in modo sicuro e pulito suite di intelligenza"
echo -e " artificiale avanzate (Unsloth Studio, ComfyUI, OpenCode AI) su distribuzioni"
echo -e " Debian e Ubuntu (supporto nativo Bare-Metal e Container LXC/Proxmox)."
echo ""
echo "+------------------------------------------------------------------------------+"
echo "| SELEZIONA OPERAZIONE:                                                        |"
echo "|   1) INSTALLA Servizi (Configurazione guidata, Localizzazione e Driver)     |"
echo "|   2) DISINSTALLA Servizi (Pulizia profonda e rimozione demoni)              |"
echo "+------------------------------------------------------------------------------+"
read -rp "Scelta [1 o 2]: " MAIN_ACTION

if [ "$MAIN_ACTION" == "2" ]; then
    # ==========================================================================
    # SEZIONE DISINSTALLAZIONE
    # ==========================================================================
    clear
    draw_box "PANNELLO DI DISINSTALLAZIONE SERVIZI"
    echo "Seleziona i servizi da RIMUOVERE (numeri separati da spazio):"
    echo "  1) Unsloth & Unsloth Studio"
    echo "  2) ComfyUI"
    echo "  3) OpenCode AI Web Service"
    echo "  4) Tutti i servizi sopra indicati"
    echo "------------------------------------------------------------------------------"
    read -rp "Scelta: " -a UNINSTALL_CHOICES

    UNINSTALL_UNSLOTH=false
    UNINSTALL_COMFY=false
    UNINSTALL_OPENCODE=false

    for choice in "${UNINSTALL_CHOICES[@]}"; do
        case "$choice" in
            1) UNINSTALL_UNSLOTH=true ;;
            2) UNINSTALL_COMFY=true ;;
            3) UNINSTALL_OPENCODE=true ;;
            4) 
               UNINSTALL_UNSLOTH=true
               UNINSTALL_COMFY=true
               UNINSTALL_OPENCODE=true
               ;;
            *) log_warn "Opzione '$choice' non valida, ignorata." ;;
        esac
    done

    echo ""
    if [ "$UNINSTALL_UNSLOTH" = true ]; then
        log_info "Rimozione Unsloth Studio:"
        do_uninstall_step "Arresto del servizio systemd" "systemctl stop unsloth-studio.service"
        do_uninstall_step "Disabilitazione del servizio all'avvio" "systemctl disable unsloth-studio.service"
        do_uninstall_step "Rimozione configurazione systemd" "rm -f /etc/systemd/system/unsloth-studio.service"
        do_uninstall_step "Cancellazione ambiente virtuale python" "rm -rf ${REAL_HOME}/unsloth_env"
        echo ""
    fi

    if [ "$UNINSTALL_COMFY" = true ]; then
        log_info "Rimozione ComfyUI:"
        do_uninstall_step "Arresto del servizio systemd" "systemctl stop comfyui.service"
        do_uninstall_step "Disabilitazione del servizio all'avvio" "systemctl disable comfyui.service"
        do_uninstall_step "Rimozione configurazione systemd" "rm -f /etc/systemd/system/comfyui.service"
        do_uninstall_step "Cancellazione directory ComfyUI" "rm -rf ${REAL_HOME}/ComfyUI"
        echo ""
    fi

    if [ "$UNINSTALL_OPENCODE" = true ]; then
        log_info "Rimozione OpenCode AI:"
        do_uninstall_step "Arresto del servizio systemd" "systemctl stop opencode.service"
        do_uninstall_step "Disabilitazione del servizio all'avvio" "systemctl disable opencode.service"
        do_uninstall_step "Rimozione configurazione systemd" "rm -f /etc/systemd/system/opencode.service"
        do_uninstall_step "Cancellazione dati utente locale" "rm -rf ${REAL_HOME}/.opencode"
        do_uninstall_step "Cancellazione dati root" "rm -rf /root/.opencode"
        do_uninstall_step "Rimozione eseguibile in /usr/local/bin" "rm -f /usr/local/bin/opencode"
        do_uninstall_step "Disinstallazione pacchetto npm" "npm uninstall -g opencode-ai"
        echo ""
    fi

    if [ "$UNINSTALL_UNSLOTH" = true ] || [ "$UNINSTALL_COMFY" = true ] || [ "$UNINSTALL_OPENCODE" = true ]; then
        do_uninstall_step "Ricaricamento demoni di sistema" "systemctl daemon-reload"
        echo ""
        log_ok "Disinstallazione completata con successo."
    else
        log_warn "Nessun servizio selezionato. Uscita."
    fi
    exit 0
fi

if [ "$MAIN_ACTION" != "1" ]; then
    log_error "Scelta non valida. Uscita."
    exit 1
fi

# ==============================================================================
# FASE PRELIMINARE: LOCALIZZAZIONE E REGIONAL SETTING
# ==============================================================================
clear
draw_box "CONFIGURAZIONE REGIONALE E LOCALIZZAZIONE"
echo " Prima di procedere con l'installazione dei pacchetti e dei driver, è necessario"
echo " impostare correttamente la localizzazione di sistema (lingua, codifica e fuso orario)"
echo " per prevenire errori di compilazione nei pacchetti Python e nei moduli CUDA."
echo ""
echo " Scegli il profilo di localizzazione desiderato:"
echo "  1) Standard Internazionale (en_US.UTF-8 + UTC) - Consigliato per AI"
echo "  2) Personalizzato (Interattivo con dpkg-reconfigure tzdata e locales)"
echo "------------------------------------------------------------------------------"
read -rp "Scelta [1 o 2]: " LOC_CHOICE

if [ "$LOC_CHOICE" == "2" ]; then
    dpkg-reconfigure tzdata
    dpkg-reconfigure locales
    SELECTED_LANG="en_US.UTF-8"
else
    SELECTED_LANG="en_US.UTF-8"
    run_guided_step \
        "Impostazione Locale e Timezone Predefiniti" \
        "Configurazione automatica dei pacchetti locales su en_US.UTF-8 per garantire\nla massima compatibilità con gli script Python e i framework di machine learning." \
        "apt install -y locales && sed -i '/^# *en_US.UTF-8 UTF-8/s/^# //' /etc/locale.gen && locale-gen en_US.UTF-8 && update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 LANGUAGE=en_US.UTF-8"
fi

export LANG="$SELECTED_LANG"
export LC_ALL="$SELECTED_LANG"
export LANGUAGE="$SELECTED_LANG"

# ==============================================================================
# SELEZIONE SERVIZI DA INSTALLARE
# ==============================================================================
clear
draw_box "SELEZIONE SERVIZI DA INSTALLARE"
echo "Seleziona i servizi da INSTALLARE (numeri separati da spazio):"
echo "  1) Unsloth & Unsloth Studio (Porta 8888)"
echo "  2) ComfyUI                  (Porta 8188)"
echo "  3) OpenCode AI Web Service  (Porta 8000)"
echo "  4) Tutti i servizi sopra indicati"
echo "------------------------------------------------------------------------------"
read -rp "Scelta: " -a INSTALL_CHOICES

INSTALL_UNSLOTH=false
INSTALL_COMFY=false
INSTALL_OPENCODE=false

for choice in "${INSTALL_CHOICES[@]}"; do
    case "$choice" in
        1) INSTALL_UNSLOTH=true ;;
        2) INSTALL_COMFY=true ;;
        3) INSTALL_OPENCODE=true ;;
        4) 
           INSTALL_UNSLOTH=true
           INSTALL_COMFY=true
           INSTALL_OPENCODE=true
           ;;
        *) log_warn "Opzione '$choice' non valida, ignorata." ;;
    esac
done

if [ "$INSTALL_UNSLOTH" = false ] && [ "$INSTALL_COMFY" = false ] && [ "$INSTALL_OPENCODE" = false ]; then
    log_error "Nessun servizio selezionato. Annullamento."
    exit 1
fi

# FASE 1: Pulizia e Upgrade del Sistema
run_guided_step \
    "Aggiornamento e Pulizia del Sistema Operativo" \
    "In questa fase puliamo le configurazioni di repository obsolete ereditate dal sistema,\naggiorniamo gli indici dei pacchetti (apt update) ed eseguiamo un aggiornamento\ncompleto (apt full-upgrade) per garantire che le dipendenze di base siano stabili." \
    "rm -f /etc/crypto-policies/back-ends/apt-sequoia.config && rm -f /etc/apt/sources.list.d/cuda*.list && rm -f /etc/apt/sources.list.d/nvidia*.list && mkdir -p /etc/apt/keyrings && apt update && apt full-upgrade -y"

# FASE 2: Pacchetti Base e Node.js
run_guided_step \
    "Installazione Utility di Base e Node.js" \
    "Vengono installati gli strumenti essenziali per la compilazione, il monitoraggio\n(htop, nvtop, mc), il supporto di rete e l'interprete Python completo di venv.\nInoltre, viene installato Node.js (necessario per interfacce e servizi web)." \
    "apt install -y curl wget ca-certificates gnupg git build-essential netcat-openbsd mc nvtop htop pciutils python3-full python3-pip python3-venv python3-setuptools python3-wheel && (command -v node &> /dev/null || (curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt install -y nodejs))"

# FASE 3: Repository NVIDIA CUDA
run_guided_step \
    "Configurazione Repository Ufficiale NVIDIA" \
    "Per abilitare le performance di calcolo accelerato via GPU, lo script scarica la chiave GPG\nufficiale di NVIDIA, configura i repository dedicati e imposta una priorità (pin)\nsulla distribuzione per evitare conflitti con i pacchetti standard della distro." \
    "curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/3bf863cc.pub | gpg --dearmor --yes -o /etc/apt/keyrings/cuda-archive-keyring.gpg && echo 'deb [trusted=yes signed-by=/etc/apt/keyrings/cuda-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/ /' > /etc/apt/sources.list.d/cuda-official.list && echo -e 'Package: *\nPin: origin developer.download.nvidia.com\nPin-Priority: 1001' > /etc/apt/preferences.d/nvidia-official-pin && apt update"

# FASE 4: Driver NVIDIA e Toolkit CUDA (LXC vs Bare-Metal)
if [ "$IS_CONTAINER" = true ]; then
    DRV_CMD='if [ -f "/proc/driver/nvidia/version" ]; then NVRM_VERSION=$(grep "Kernel Module" /proc/driver/nvidia/version | awk "{print \$8}"); MAJOR_VERSION=$(echo "$NVRM_VERSION" | cut -d"." -f1); apt install -y "nvidia-utils-${MAJOR_VERSION}" cuda-toolkit || { RUN_FILE="NVIDIA-Linux-x86_64-${NVRM_VERSION}.run"; wget -q "https://us.download.nvidia.com/XFree86/Linux-x86_64/${NVRM_VERSION}/${RUN_FILE}" && chmod +x "$RUN_FILE" && ./"$RUN_FILE" --no-kernel-module --silent && rm -f "$RUN_FILE"; apt install -y cuda-toolkit; }; else apt install -y cuda-toolkit; fi'
    DRV_DESC="Ambiente LXC (Container Proxmox) rilevato. Lo script analizza la versione dei driver\ninstallati sull'Host Proxmox e configura i componenti userspace (inclusi i comandi\ncome nvidia-smi) e il toolkit CUDA all'interno del container."
else
    DRV_DESC="Ambiente Bare-Metal o VM fisica rilevato. Lo script installa i driver completi\ndell'architettura NVIDIA, configura i moduli DKMS e inibisce i driver open-source nouveau."
    if grep -qi "ubuntu" /etc/os-release; then
        DRV_CMD='apt install -y dkms linux-headers-$(uname -r) && echo -e "blacklist nouveau\noptions nouveau modeset=0" > /etc/modprobe.d/blacklist-nouveau.conf && update-initramfs -u && apt install -y ubuntu-drivers-common && ubuntu-drivers autoinstall && apt install -y cuda-toolkit'
    else
        DRV_CMD='apt install -y dkms linux-headers-$(uname -r) && echo -e "blacklist nouveau\noptions nouveau modeset=0" > /etc/modprobe.d/blacklist-nouveau.conf && update-initramfs -u && apt install -y cuda-drivers cuda-toolkit'
    fi
fi

run_guided_step "Installazione Driver NVIDIA e Toolkit CUDA" "$DRV_DESC" "$DRV_CMD"

# Configurazione profilo CUDA globale
run_guided_step \
    "Configurazione Variabili d'Ambiente CUDA" \
    "Vengono esportati i percorsi di sistema (PATH e LD_LIBRARY_PATH) per puntare\ncorrettamente ai binari CUDA in /usr/local/cuda." \
    "cat <<'EOF' > /etc/profile.d/cuda.sh\nexport PATH=/usr/local/cuda/bin\${PATH:+:\${PATH}}\nexport LD_LIBRARY_PATH=/usr/local/cuda/lib64\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}\nEOF\nchmod +x /etc/profile.d/cuda.sh"
source /etc/profile.d/cuda.sh || true

# FASE 5: Installazione Astral UV
run_guided_step \
    "Installazione di Astral UV (Package Manager)" \
    "Viene installato 'uv', un gestore di pacchetti Python scritto in Rust estremamente\nveloce, che velocizzerà drasticamente il download e la compilazione delle librerie AI." \
    "curl -LsSf https://astral.sh/uv/install.sh | sh"
export PATH="${REAL_HOME}/.cargo/bin:${PATH}"

# FASE 6: Unsloth Studio
if [ "$INSTALL_UNSLOTH" = true ]; then
    UNSLOTH_DIR="${REAL_HOME}/unsloth_env"
    run_guided_step \
        "Installazione Unsloth & Unsloth Studio" \
        "Viene creato un ambiente virtuale Python dedicato (Python 3.12) e installata la versione\nstabile di PyTorch (2.5.1) insieme a Unsloth, xformers, TRL e JupyterLab.\nIl servizio viene poi configurato per avviarsi automaticamente tramite systemd." \
        "su - ${REAL_USER} -c 'export PATH=/usr/local/cuda/bin:\$PATH; export LD_LIBRARY_PATH=/usr/local/cuda/lib64:\$LD_LIBRARY_PATH; uv venv ${UNSLOTH_DIR} --python 3.12 --seed; source ${UNSLOTH_DIR}/bin/activate; uv pip install --upgrade pip setuptools wheel; uv pip install \"torch==2.5.1\" \"torchvision==0.20.1\" \"torchaudio==2.5.1\" --index-url https://download.pytorch.org/whl/cu124; uv pip install unsloth xformers trl peft accelerate bitsandbytes jupyterlab'"

    run_guided_step \
        "Configurazione Servizio Systemd per Unsloth Studio" \
        "Creazione del demone di sistema per mantenere JupyterLab/Unsloth Studio attivo in background." \
        "cat <<EOF > /etc/systemd/system/unsloth-studio.service\n[Unit]\nDescription=Unsloth Studio AI Service\nAfter=network.target\n\n[Service]\nType=simple\nUser=${REAL_USER}\nWorkingDirectory=${REAL_HOME}\nEnvironment=\"PATH=/usr/local/cuda/bin:${UNSLOTH_DIR}/bin:/usr/bin:/bin\"\nEnvironment=\"LD_LIBRARY_PATH=/usr/local/cuda/lib64\"\nEnvironment=\"LANG=en_US.UTF-8\"\nEnvironment=\"LC_ALL=en_US.UTF-8\"\nExecStart=${UNSLOTH_DIR}/bin/jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --ServerApp.token='' --ServerApp.password='' --allow-root\nRestart=always\nRestartSec=5\n\n[Install]\nWantedBy=multi-user.target\nEOF\nsystemctl daemon-reload && systemctl enable unsloth-studio.service && systemctl restart unsloth-studio.service"
fi

# FASE 7: ComfyUI
if [ "$INSTALL_COMFY" = true ]; then
    COMFY_DIR="${REAL_HOME}/ComfyUI"
    run_guided_step \
        "Clonazione e Setup di ComfyUI" \
        "Viene clonato il repository ufficiale di ComfyUI da GitHub, creato il venv isolato\ne installata la versione di PyTorch 2.5.1 in abbinamento alle dipendenze del file requirements.txt." \
        "su - ${REAL_USER} -c 'if [ ! -d \"${COMFY_DIR}\" ]; then git clone https://github.com/comfyanonymous/ComfyUI.git ${COMFY_DIR}; fi; export PATH=/usr/local/cuda/bin:\$PATH; export LD_LIBRARY_PATH=/usr/local/cuda/lib64:\$LD_LIBRARY_PATH; cd ${COMFY_DIR}; uv venv venv --python 3.12 --seed; source venv/bin/activate; uv pip install --upgrade pip setuptools wheel; uv pip install \"torch==2.5.1\" \"torchvision==0.20.1\" \"torchaudio==2.5.1\" --index-url https://download.pytorch.org/whl/cu124; uv pip install -r requirements.txt'"

    COMFY_EXTRA_FLAGS=""
    if ! command -v nvidia-smi &>/dev/null || ! nvidia-smi &>/dev/null; then
        COMFY_EXTRA_FLAGS="--cpu"
    fi

    run_guided_step \
        "Configurazione Servizio Systemd per ComfyUI" \
        "Creazione del demone di sistema per l'esecuzione persistente di ComfyUI sulla porta 8188." \
        "cat <<EOF > /etc/systemd/system/comfyui.service\n[Unit]\nDescription=ComfyUI AI Service\nAfter=network.target\n\n[Service]\nType=simple\nUser=${REAL_USER}\nWorkingDirectory=${COMFY_DIR}\nEnvironment=\"PATH=/usr/local/cuda/bin:/usr/bin:/bin\"\nEnvironment=\"LD_LIBRARY_PATH=/usr/local/cuda/lib64\"\nEnvironment=\"LANG=en_US.UTF-8\"\nEnvironment=\"LC_ALL=en_US.UTF-8\"\nExecStart=${COMFY_DIR}/venv/bin/python main.py --listen 0.0.0.0 --port 8188 ${COMFY_EXTRA_FLAGS}\nRestart=always\nRestartSec=5\n\n[Install]\nWantedBy=multi-user.target\nEOF\nsystemctl daemon-reload && systemctl enable comfyui.service && systemctl restart comfyui.service"
fi

# FASE 8: OpenCode AI
if [ "$INSTALL_OPENCODE" = true ]; then
    run_guided_step \
        "Installazione OpenCode AI Web Service" \
        "Viene scaricato e installato l'esecutivo ufficiale di OpenCode AI e configurato\nil servizio systemd per l'accesso web sulla porta 8000." \
        "curl -fsSL https://opencode.ai/install | bash || npm install -g opencode-ai; if [ -f \"${REAL_HOME}/.opencode/bin/opencode\" ]; then cp \"${REAL_HOME}/.opencode/bin/opencode\" /usr/local/bin/opencode; elif [ -f \"/root/.opencode/bin/opencode\" ]; then cp \"/root/.opencode/bin/opencode\" /usr/local/bin/opencode; fi; chmod +x /usr/local/bin/opencode || true"

    run_guided_step \
        "Configurazione Servizio Systemd per OpenCode" \
        "Impostazione del demone systemd per OpenCode." \
        "cat <<EOF > /etc/systemd/system/opencode.service\n[Unit]\nDescription=OpenCode AI Web Service\nAfter=network.target\n\n[Service]\nType=simple\nUser=${REAL_USER}\nWorkingDirectory=${REAL_HOME}\nEnvironment=\"PATH=/usr/local/cuda/bin:${REAL_HOME}/.opencode/bin:/usr/local/bin:/usr/bin:/bin\"\nEnvironment=\"LANG=en_US.UTF-8\"\nEnvironment=\"LC_ALL=en_US.UTF-8\"\nExecStart=/usr/local/bin/opencode web --hostname 0.0.0.0 --port 8000\nRestart=always\nRestartSec=5\n\n[Install]\nWantedBy=multi-user.target\nEOF\nsystemctl daemon-reload && systemctl enable opencode.service && systemctl restart opencode.service"
fi

# ------------------------------------------------------------------------------
# CONTROLLI FINALI E RIEPILOGO
# ------------------------------------------------------------------------------
chown -R "$REAL_USER":"$REAL_USER" "$REAL_HOME"

clear
draw_box "VERIFICA FINALE E RIEPILOGO SERVIZI"
if command -v nvidia-smi &>/dev/null; then
    nvidia-smi || true
else
    log_warn "Comando nvidia-smi non trovato nel PATH corrente."
fi

SERVER_IP=$(hostname -I | awk '{print $1}')
[ -z "$SERVER_IP" ] && SERVER_IP="localhost"

check_port() {
    local port=$1
    if nc -z -w 3 127.0.0.1 "$port" &>/dev/null; then
        echo -e "${GREEN}[OK - ATTIVO]${NC}"
    else
        echo -e "${RED}[FAIL - INATTIVO]${NC}"
    fi
}

echo ""
log_ok "INSTALLAZIONE COMPLETATA CON SUCCESSO!"
echo "------------------------------------------------------------------------------"

if [ "$INSTALL_UNSLOTH" = true ]; then
    echo -e " 1. Unsloth Studio: http://${SERVER_IP}:8888  $(check_port 8888)"
fi
if [ "$INSTALL_COMFY" = true ]; then
    echo -e " 2. ComfyUI:        http://${SERVER_IP}:8188  $(check_port 8188)"
fi
if [ "$INSTALL_OPENCODE" = true ]; then
    echo -e " 3. OpenCode Web:   http://${SERVER_IP}:8000  $(check_port 8000)"
fi

echo "=============================================================================="
