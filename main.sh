#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Main Dispatcher Menu
# Repo: mrpink77it/homelab-ai-deployer
# Version: V.1.0.6
# ==============================================================================

set -e

# Format e Colori
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Controllo Permessi Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Questo script deve essere eseguito come root!${NC}"
  echo -e "${YELLOW}Usa: sudo ./main.sh${NC}"
  exit 1
fi

# Assicuriamoci che tutti gli script manager abbiano i permessi di esecuzione
chmod +x manager-*.sh 2>/dev/null || true

# Funzione per eseguire in modo sicuro gli script esterni
run_script() {
    local script_name=$1
    if [ -f "./$script_name" ]; then
        echo -e "${CYAN}Avvio di $script_name in corso...${NC}\n"
        sleep 1
        exec "./$script_name"
    else
        echo -e "${RED}[ERROR] File $script_name non trovato nella directory corrente!${NC}"
        echo -e "${YELLOW}Assicurati di aver clonato correttamente la repository.${NC}"
    fi
}

show_menu() {
    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}        🦥 HOMELAB AI DEPLOYER - MAIN MENU         ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    echo -e " Seleziona l'ambiente di destinazione:"
    echo -e ""
    echo -e " 1) 🟢 ${GREEN}Ambiente NVIDIA${NC}       (manager-nvidia.sh)"
    echo -e " 2) 🔴 ${RED}Ambiente AMD${NC}          (manager-amd.sh)"
    echo -e " 3) ⚪ ${CYAN}Ambiente CPU-Only${NC}     (manager-cpu.sh)"
    echo -e " 4) 🛠️  ${YELLOW}Modulo Fine-Tuning${NC}    (manager-finetuning.sh)"
    echo -e " 5) 🚪 ${BLUE}Esci${NC}"
    echo -e "${BLUE}====================================================${NC}"
    echo -ne "Scegli un'opzione [1-5]: "
}

while true; do
    show_menu
    read -r choice
    case $choice in
        1) 
            run_script "manager-nvidia.sh"
            ;;
        2) 
            run_script "manager-amd.sh"
            ;;
        3) 
            run_script "manager-cpu.sh"
            ;;
        4) 
            run_script "manager-finetuning.sh"
            ;;
        5) 
            echo -e "\n${GREEN}Uscita dal deployer. A presto!${NC}"
            exit 0 
            ;;
        *) 
            echo -e "\n${RED}Opzione non valida! Inserisci un numero da 1 a 5.${NC}"
            sleep 2
            ;;
    esac
done
