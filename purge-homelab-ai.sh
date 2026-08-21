#!/usr/bin/env bash
# ==============================================================================
# Script: purge-homelab-ai.sh
# Versione: 1.0.0
# Descrizione: Disinstallazione profonda ("Piallatore Estremo") suite Homelab AI
# Rilevamento: Servizi AI, Web Server, Dipendenze Hardware (NVIDIA/AMD/CPU)
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERRORE] Lo script richiede i privilegi di root. Avvialo con sudo.${NC}"
    exit 1
fi

if ! command -v whiptail &> /dev/null; then
    apt-get update >/dev/null && apt-get install -y whiptail >/dev/null
fi

echo -e "${RED}=================================================================${NC}"
echo -e "${RED} ATTENZIONE: PURGE ESTREMO HOMELAB AI E SERVIZI CORRELATI${NC}"
echo -e "${RED}=================================================================${NC}"

# ------------------------------------------------------------------------------
# Fase 1: Rilevamento e Rimozione Dinamica Servizi Systemd
# ------------------------------------------------------------------------------
echo -e "${CYAN}>>> Scansione dei servizi di sistema in corso...${NC}"

# Regex per includere tutte le parole chiave richieste
SERVICE_REGEX='homelab|ollama|open-?webui|unsloth|nginx|llama|cpp|apache'

# Popola l'array con i nomi dei servizi trovati, rimuovendo i duplicati
mapfile -t FOUND_SERVICES < <(find /etc/systemd/system/ /lib/systemd/system/ -type f -name "*.service" 2>/dev/null | grep -iE "$SERVICE_REGEX" | awk -F/ '{print $NF}' | sort -u || true)

if [[ ${#FOUND_SERVICES[@]} -eq 0 ]]; then
    whiptail --title "Rimozione Servizi" --msgbox "Nessun servizio correlato a AI o Web Server trovato." 8 60
else
    CHECKLIST_OPTIONS=()
    for srv in "${FOUND_SERVICES[@]}"; do
        CHECKLIST_OPTIONS+=("$srv" "" "OFF")
    done

    SELECTED_SERVICES=$(whiptail --title "Piallatore Servizi Systemd" \
        --checklist "\nATTENZIONE: Seleziona i servizi da ARRESTARE e ELIMINARE.\nFai attenzione a Nginx/Apache se ospitano altri siti!\n(SPAZIO per selezionare, INVIO per confermare)" \
        22 78 12 "${CHECKLIST_OPTIONS[@]}" 3>&1 1>&2 2>&3 || true)

    if [[ -n "$SELECTED_SERVICES" ]]; then
        echo -e "\n${GREEN}[1/4] Arresto e disabilitazione dei servizi selezionati...${NC}"
        SELECTED_SERVICES=$(echo "$SELECTED_SERVICES" | tr -d '"')
        
        for srv in $SELECTED_SERVICES; do
            echo -e "${YELLOW} -> Rimozione di $srv...${NC}"
            systemctl stop "$srv" 2>/dev/null || true
            systemctl disable "$srv" 2>/dev/null || true
            rm -f "/etc/systemd/system/$srv"
            rm -f "/lib/systemd/system/$srv"
        done
        systemctl daemon-reload
    else
        echo -e "\n${YELLOW}Nessun servizio selezionato per la rimozione.${NC}"
    fi
fi

# ------------------------------------------------------------------------------
# Fase 2: Pulizia Directory, Modelli e Ambienti Python
# ------------------------------------------------------------------------------
if whiptail --title "Pulizia Profonda File e Repository" \
    --yesno "\nVuoi procedere con la piallatura totale dei file?\n\nVerranno eliminati:\n- Cartelle /opt/homelab-ai (inclusi modelli e Unsloth)\n- Eseguibili UV (root e utenti)\n- Cache (pip, uv, compilazione)\n- Repository iniettati (ROCm, CUDA, ecc.)" \
    14 78; then
    
    echo -e "\n${GREEN}[2/4] Rimozione directory di installazione e log...${NC}"
    rm -rf /opt/homelab-ai
    rm -f /var/log/homelab-ai-*.log
    
    echo -e "${GREEN}[3/4] Distruzione ambienti Python, UV e cache...${NC}"
    rm -f /root/.cargo/bin/uv /root/.cargo/bin/uvx
    rm -f /root/.local/bin/uv /root/.local/bin/uvx
    rm -f /home/*/.cargo/bin/uv /home/*/.cargo/bin/uvx 2>/dev/null || true
    rm -f /home/*/.local/bin/uv /home/*/.local/bin/uvx 2>/dev/null || true
    
    rm -rf /root/.cache/ccache /root/.cache/pip /root/.cache/uv
    rm -rf /home/*/.cache/ccache /home/*/.cache/pip /home/*/.cache/uv 2>/dev/null || true

# ------------------------------------------------------------------------------
# Fase 3: Purge Repository e Toolkit Hardware (AMD/NVIDIA)
# ------------------------------------------------------------------------------
    echo -e "\n${GREEN}[4/4] Pulizia repository hardware e pacchetti di sistema...${NC}"

    # AMD ROCm Purge
    if ls /etc/apt/sources.list.d/*rocm* 1> /dev/null 2>&1 || ls /etc/apt/sources.list.d/*amdgpu* 1> /dev/null 2>&1; then
        echo -e "${YELLOW} -> Rilevati repository AMD. Procedo con la rimozione...${NC}"
        rm -f /etc/apt/sources.list.d/rocm.list
        rm -f /etc/apt/sources.list.d/amdgpu.list
        rm -f /etc/apt/preferences.d/99-rocm-amd
        rm -f /etc/apt/keyrings/rocm.gpg
        # Purge dei pacchetti di sviluppo ROCm (non tocca i driver video di base)
        apt-get purge -y "rocm-dev" "rocm-hip-sdk" "hipcc" "rocminfo" 2>/dev/null || true
    fi

    # NVIDIA CUDA Purge
    if ls /etc/apt/sources.list.d/*cuda* 1> /dev/null 2>&1 || ls /etc/apt/sources.list.d/*nvidia* 1> /dev/null 2>&1; then
        echo -e "${YELLOW} -> Rilevati repository NVIDIA/CUDA. Procedo con la rimozione...${NC}"
        rm -f /etc/apt/sources.list.d/cuda*.list
        rm -f /etc/apt/sources.list.d/nvidia*.list
        rm -f /etc/apt/keyrings/cuda*.gpg
        # Purge estremo toolkit CUDA (non tocca il driver nvidia proprietario base per evitare kernel panic/display rotto)
        apt-get purge -y "cuda-toolkit*" "*cublas*" "*cufft*" "*curand*" "*cusolver*" "*cusparse*" 2>/dev/null || true
    fi

    echo -e "${CYAN}>>> Esecuzione Autoremove e svuotamento cache APT...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get autoremove --purge -y
    apt-get clean

    echo -e "\n${GREEN}=================================================================${NC}"
    echo -e "${GREEN} Piallatura completata con successo! L'ambiente è immacolato.${NC}"
    echo -e "${GREEN}=================================================================${NC}"
else
    echo -e "\n${YELLOW}Pulizia profonda file e repository saltata dall'utente.${NC}"
fi
