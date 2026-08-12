#!/usr/bin/env bash
# ==============================================================================
# UNSLOTH SUITE - CONFIGURAZIONE SANDBOX (ESECUTORE DI CODICE)
# ==============================================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$(id -u)" -ne 0 ]; then
    log_error "Questo script deve essere eseguito come root (sudo)."
    exit 1
fi

clear
echo -e "${CYAN}"
echo "  ____                 _ _               "
echo " / ___|  __ _ _ __   __| | |__   ___  _   _ "
echo " \___ \ / _\` | '_ \ / _\` | '_ \ / _ \| | | |"
echo "  ___) | (_| | | | | (_| | |_) | (_) | |_| |"
echo " |____/ \__,_|_| |_|\__,_|_.__/ \___/ \__, |"
echo "                                      |___/ "
echo -e "${NC}"
echo "=============================================================================="
echo " Configurazione automatica della Sandbox (Nodo di Esecuzione Sicuro)"
echo " Questa macchina eseguirà il codice inviato dal Controller AI."
echo "=============================================================================="
echo ""

# 1. Aggiornamento e installazione dipendenze di base + Locales
log_info "Aggiornamento pacchetti e installazione Python3, Git, Curl e Locales..."
apt update && apt install -y python3-full python3-pip python3-venv git curl locales openssh-server

# 2. Configurazione Locale UTF-8 (Risoluzione warning setlocale)
log_info "Configurazione locale en_US.UTF-8..."
sed -i '/^# *en_US.UTF-8 UTF-8/s/^# //' /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# 3. Configurazione di sicurezza SSH (PermitRootLogin yes)
log_info "Abilitazione PermitRootLogin e configurazione SSH..."
sed -i 's/#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null

echo ""
log_ok "La Sandbox è pronta per ricevere le connessioni con UTF-8 e SSH Root abilitati!"
echo "------------------------------------------------------------------------------"
echo " PROSSIMI PASSI (Dalla macchina CONTROLLER):"
echo " 1. Genera una chiave SSH (se non l'hai già fatto):"
echo "    ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519"
echo ""
echo " 2. Copia la chiave pubblica su questa Sandbox:"
echo "    ssh-copy-id root@$(hostname -I | awk '{print $1}')"
echo ""
echo " 3. Fatto! L'IA potrà ora inviare codice da eseguire in sicurezza qui."
echo "=============================================================================="
