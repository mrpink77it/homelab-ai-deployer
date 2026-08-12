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
echo "  ____                  _ _                 "
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

# 1. Aggiornamento e installazione dipendenze di base
log_info "Aggiornamento pacchetti e installazione Python3..."
apt update && apt install -y python3-full python3-pip python3-venv git curl

# 2. Configurazione di sicurezza SSH per accettare comandi remoti
log_info "Verifica configurazione SSH..."
systemctl enable ssh --now || systemctl enable sshd --now

echo ""
log_ok "La Sandbox è pronta per ricevere le connessioni!"
echo "------------------------------------------------------------------------------"
echo " PROSSIMI PASSI (Dalla macchina CONTROLLER):"
echo " 1. Genera una chiave SSH (se non l'hai già fatto):"
echo "    ssh-keygen -t rsa -b 4096"
echo ""
echo " 2. Copia la chiave pubblica su questa Sandbox:"
echo "    ssh-copy-id root@$(hostname -I | awk '{print $1}')"
echo ""
echo " 3. Fatto! L'IA potrà ora inviare codice da eseguire in sicurezza qui."
echo "=============================================================================="
