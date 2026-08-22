#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - Main Discovery & Dispatcher
# Repo: mrpink77it/homelab-ai-deployer
# ==============================================================================

set -e

# Format e Colori
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}====================================================${NC}"
echo -e "${BLUE}        🦥 HOMELAB AI DEPLOYER - INIZIALIZZAZIONE  ${NC}"
echo -e "${BLUE}====================================================${NC}"

# Controllo Permessi Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Questo script deve essere eseguito come root!${NC}"
  echo -e "${YELLOW}Suggerimento: usa 'sudo ./main.sh' oppure loggati come root.${NC}"
  exit 1
fi

# Assegna i permessi a tutti gli script nella nuova struttura
echo -e "${YELLOW}---> Impostazione permessi di esecuzione per la struttura...${NC}"
chmod +x "$0"
if [ -d "script" ]; then
    chmod +x script/*.sh
    echo -e "${GREEN}[OK] Permessi applicati alla directory script/${NC}"
else
    echo -e "${RED}[ERROR] Directory 'script/' non trovata. Assicurati di essere nella root del repository.${NC}"
    exit 1
fi

echo -e "\n${CYAN}Avvio diagnostica hardware in corso...${NC}"
sleep 1

# Rilevamento NVIDIA
if lspci | grep -i nvidia &> /dev/null || command -v nvidia-smi &> /dev/null; then
    echo -e "${GREEN}[HARDWARE] GPU NVIDIA RILEVATA.${NC}"
    echo -e "Instradamento verso il manager NVIDIA..."
    sleep 2
    exec ./script/manager-nvidia.sh

# Rilevamento AMD
elif lspci | grep -i vga | grep -i amd &> /dev/null || command -v rocm-smi &> /dev/null; then
    echo -e "${GREEN}[HARDWARE] GPU AMD RILEVATA.${NC}"
    echo -e "Instradamento verso il manager AMD (ROCm)..."
    sleep 2
    exec ./script/manager-amd.sh

# Nessuna GPU supportata trovata (CPU Mode)
else
    echo -e "${YELLOW}[HARDWARE] NESSUNA GPU DEDICATA RILEVATA.${NC}"
    echo -e "Avvio del fallback su CPU..."
    sleep 2
    exec ./script/manager-cpu.sh
fi
