#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Main Dispatcher
# Repo: mrpink77it/homelab-ai-deployer
# Version: V.1.1.5
# ==============================================================================

set -e

# Controllo Permessi Root
if [ "$EUID" -ne 0 ]; then
  echo -e "\033[0;31m[ERROR] Questo script deve essere eseguito come root!\033[0m"
  exit 1
fi

# Installa whiptail se mancante (necessario per l'interfaccia grafica TUI)
if ! command -v whiptail &> /dev/null; then
    echo "Installazione dipendenze interfaccia (whiptail) in corso..."
    apt-get update -qq && apt-get install -y whiptail -qq
fi

# ------------------------------------------------------------------------------
# RISOLUZIONE PERMESSI NELLA CARTELLA 'script'
# ------------------------------------------------------------------------------
if [ -d "script" ]; then
    find script/ -type f -name "*.sh" -exec chmod +x {} + 2>/dev/null || true
else
    # Fallback se eseguito dall'interno della cartella
    find . -maxdepth 1 -type f -name "*.sh" -exec chmod +x {} + 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# DIAGNOSTICA HARDWARE E AMBIENTE
# ------------------------------------------------------------------------------
if grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
    VIRT_ENV="LXC (Proxmox)"
else
    VIRT_ENV="Bare-Metal / VM"
fi

HW_DETECTED="Nessuna GPU dedicata (Fallback CPU)"
DEFAULT_ITEM="3" # Di default posiziona su CPU-Only

if lspci | grep -iq "NVIDIA" || [ -d "/proc/driver/nvidia" ] || command -v nvidia-smi &> /dev/null; then
    HW_DETECTED="NVIDIA GPU"
    DEFAULT_ITEM="1" # Posiziona su NVIDIA
elif lspci | grep -i "vga\|3d\|display" | grep -iq "AMD\|Radeon" || [ -d "/sys/module/amdgpu" ]; then
    HW_DETECTED="AMD GPU"
    DEFAULT_ITEM="2" # Posiziona su AMD
fi

# ------------------------------------------------------------------------------
# BANNER INTRODUTTIVO
# ------------------------------------------------------------------------------
show_intro_banner() {
    clear
    echo -e "\033[0;36m"
    cat << "EOF"
 _   _                      _       _        ___  ___ 
| | | | ___  _ __ ___   ___| | __ _| |__    / _ \|_ _|
| |_| |/ _ \| '_ ` _ \ / _ \ |/ _` | '_ \  | |_| || | 
|  _  | (_) | | | | | |  __/ | (_| | |_) | |  _  || | 
|_| |_|\___/|_| |_| |_|\___|_|\__,_|_.__/  |_| |_|___|
                                                      
                  DEPLOYER V.1.1.5
EOF
    echo -e "\033[0m"
    echo -e "\033[1;37m=================================================================\033[0m"
    echo -e "\033[1;32m Benvenuto nell'ecosistema Homelab AI Deployer!\033[0m"
    echo -e "\033[1;37m=================================================================\033[0m"
    echo -e "Questo strumento analizza automaticamente il tuo hardware"
    echo -e "e ti guida nell'installazione e orchestrazione del tuo stack AI:"
    echo -e ""
    echo -e "  \033[0;33m•\033[0m \033[1;36mBackend:\033[0m  llama.cpp ottimizzato per (NVIDIA / AMD / CPU)"
    echo -e "  \033[0;33m•\033[0m \033[1;36mFrontend:\033[0m Unsloth Studio, Open WebUI, OpenCode AI"
    echo -e "  \033[0;33m•\033[0m \033[1;36mServizi:\033[0m  Configurazione automatica systemd e API remote"
    echo -e ""
    echo -e "\033[1;37m=================================================================\033[0m"
    echo -e " \033[1;35mAmbiente rilevato:\033[0m $VIRT_ENV"
    echo -e " \033[1;35mHardware rilevato:\033[0m $HW_DETECTED"
    echo -e "\033[1;37m=================================================================\033[0m"
    echo -e ""
    echo -e "\033[1;33mPremi un tasto qualsiasi per avviare la console di gestione..."
    echo -e "(L'avvio automatico avverrà tra 120 secondi)\033[0m"
    
    # Aspetta la pressione di un tasto (-n 1) per 120 secondi (-t 120) in modalità silenziosa (-s)
    read -t 120 -n 1 -s -r || true
}

# ------------------------------------------------------------------------------
# FUNZIONE DI ESECUZIONE (Fix Percorsi)
# ------------------------------------------------------------------------------
run_script() {
    local target_script="$1"
    local script_path=""
    
    # Cerca il file prima nella cartella script/, poi nella radice
    if [ -f "script/$target_script" ]; then
        script_path="script/$target_script"
    elif [ -f "./$target_script" ]; then
        script_path="./$target_script"
    fi

    if [ -n "$script_path" ]; then
        clear
        echo -e "\033[0;36mAvvio di $script_path in corso...\033[0m\n"
        sleep 1
        exec "$script_path"
    else
        whiptail --title "Errore" --msgbox "File '$target_script' non trovato!\n\nAssicurati che il file esista all'interno della cartella 'script/'." 10 60
    fi
}

# ------------------------------------------------------------------------------
# MENU GRAFICO PRINCIPALE
# ------------------------------------------------------------------------------
show_menu() {
    CHOICE=$(whiptail --title "Homelab AI - Main Dispatcher" \
        --default-item "$DEFAULT_ITEM" \
        --menu "\nAmbiente: $VIRT_ENV\nHardware Rilevato: $HW_DETECTED\n\nScegli un'operazione:" 20 75 7 \
        "1" "Ambiente NVIDIA      (manager-nvidia.sh)" \
        "2" "Ambiente AMD         (manager-amd.sh)" \
        "3" "Ambiente CPU-Only    (manager-cpu.sh)" \
        "4" "Modulo Fine-Tuning   (manager-finetuning.sh)" \
        "5" "Disinstalla Servizi  (uninstall.sh)" \
        "6" "Purge Estremo        (purge-homelab-ai.sh)" \
        3>&1 1>&2 2>&3)
        
    # Gestione tasto Cancel o ESC
    if [ $? -ne 0 ]; then
        clear
        echo -e "\033[0;32mUscita dal deployer. A presto!\033[0m"
        exit 0
    fi
}

# ------------------------------------------------------------------------------
# AVVIO E LOOP DI GESTIONE
# ------------------------------------------------------------------------------

# Mostra il banner introduttivo una sola volta all'avvio
show_intro_banner

while true; do
    show_menu
    case $CHOICE in
        1) run_script "manager-nvidia.sh" ;;
        2) run_script "manager-amd.sh" ;;
        3) run_script "manager-cpu.sh" ;;
        4) run_script "manager-finetuning.sh" ;;
        5) run_script "uninstall.sh" ;;
        6) run_script "purge-homelab-ai.sh" ;;
    esac
done
