#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - First Boot Interactive Setup Wizard
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

clear
echo -e "${CYAN}"
echo "  _  _  ___  __  __  ___ _    _   ___   _   ___   ___  ___  ___  _   _ ___ ___ "
echo " | || |/ _ \|  \/  || __| |  /_\ | _ ) /_\ |_ _| |   \/ __|| _ \/_\ / __| __|"
echo " | __ | (_) | |\/| || _|| |_/ _ \| _ \/ _ \ | |  | |) \__ \|  _/ _ \ (__| _| "
echo " |_||_|\___/|_|  |_||___|___/_/ \_\___/_/ \_\___| |___/|___/|_|/_/ \_\___|___|"
echo -e "${NC}"
echo "=============================================================================="
echo "         CONFIGURAZIONE INIZIALE UTENTE E LOCALIZZAZIONE SISTEMA              "
echo "=============================================================================="
echo ""

# 1. Creazione Utente Non-Root
read -p "Inserisci il nome utente principale (default: user): " NEW_USER
NEW_USER="${NEW_USER:-user}"

if ! id "$NEW_USER" &>/dev/null; then
    while true; do
        read -s -p "Inserisci la password per l'utente $NEW_USER: " USER_PASS
        echo ""
        read -s -p "Conferma la password: " USER_PASS_CONF
        echo ""
        [ "$USER_PASS" = "$USER_PASS_CONF" ] && [ -n "$USER_PASS" ] && break
        echo -e "${RED}Le password non coincidono o sono vuote! Riprova.${NC}"
    done

    useradd -m -s /bin/bash "$NEW_USER"
    echo "$NEW_USER:$USER_PASS" | chpasswd
    usermod -aG sudo,video,render "$NEW_USER"
    echo -e "${GREEN}[OK] Utente '$NEW_USER' creato con successo!${NC}\n"
fi

# 2. Scelta della Lingua e del Layout della Tastiera
whiptail --title " Localizzazione Tastiera " --menu "Seleziona il layout della tastiera:" 15 60 4 \
  "it" "Italiano" \
  "us" "Inglese (US)" \
  "de" "Tedesco" \
  "fr" "Francese" 2>/tmp/kb_choice || true

KB_LAYOUT=$(cat /tmp/kb_choice 2>/dev/null || echo "it")
loadkeys "$KB_LAYOUT" 2>/dev/null || true
sed -i "s/KEYMAP=.*/KEYMAP=$KB_LAYOUT/" /etc/vconsole.conf 2>/dev/null || true

# 3. Disabilitazione del servizio di first-boot per i riavvii successivi
systemctl disable first-boot.service 2>/dev/null || true
rm -f /etc/systemd/system/first-boot.service

echo -e "${GREEN}[OK] Configurazione completata! Avvio del Proxmox AI Deployer (main.sh)...${NC}"
sleep 2

# Avvio automatico del Dispatcher principale
if [ -f "/opt/homelab-ai-deployer/main.sh" ]; then
    cd /opt/homelab-ai-deployer && ./main.sh
fi
