#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Main Dispatcher
# Repo: mrpink77it/homelab-ai-deployer
# Version: V.1.1.6
# ==============================================================================

set -e

# ------------------------------------------------------------------------------
# CONTROLLI PRELIMINARI
# ------------------------------------------------------------------------------
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
# BANNER INTRODUTTIVO (Stile Whiptail Centrato)
# ------------------------------------------------------------------------------
show_intro_banner() {
    # Usiamo cat con 'EOF' per preservare la formattazione e gli spazi
    local ASCII_LOGO=$(cat << 'EOF'
         _   _                      _       _        ___  ___ 
        | | | | ___  _ __ ___   ___| | __ _| |__    / _ \|_ _|
        | |_| |/ _ \| '_ ` _ \ / _ \ |/ _` | '_ \  | |_| || | 
        |  _  | (_) | | | | | |  __/ | (_| | |_) | |  _  || | 
        |_| |_|\___/|_| |_| |_|\___|_|\__,_|_.__/  |_| |_|___|
EOF
)

    local INFO_TEXT="
                            DEPLOYER V.1.1.6

             Benvenuto nell'ecosistema Homelab AI Deployer!

        Questo strumento analizza automaticamente il tuo hardware
             e ti guida nell'orchestrazione del tuo stack AI:

            • Backend:  llama.cpp ottimizzato (NVIDIA / AMD / CPU)
            • Frontend: Unsloth Studio, Open WebUI, JupyterLab
            • Servizi:  Configurazione Bare-Metal via systemd

        -------------------------------------------------------
                    Ambiente: $VIRT_ENV
                    Hardware: $HW_DETECTED
        -------------------------------------------------------

           Premi <Ok> per iniziare (avvio automatico tra 120s)."

    # Uniamo il logo e il testo
    local FULL_BANNER="$ASCII_LOGO$INFO_TEXT"

    # L'opzione --foreground permette a timeout di non bloccare l'input
    # della tastiera (il TTY), facendo funzionare correttamente il tasto Ok.
    timeout --foreground 120 whiptail --title " Homelab AI Deployer " --msgbox "$FULL_BANNER" 26 75 || true
}

# ------------------------------------------------------------------------------
# FUNZIONE DI ESECUZIONE 
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

# Avvia il loop infinito del menu principale
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
