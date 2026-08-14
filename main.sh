#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - GPU Router & Entrypoint
# Rileva l'hardware presente ed esegue lo script manager dedicato.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=================================================="
echo "   Homelab AI Deployer - Hardware Discovery      "
echo "=================================================="

# 1. Controllo presenza GPU NVIDIA
HAS_NVIDIA=false
if command -v nvidia-smi &> /dev/null || lspci | grep -iE 'vga|3d|display' | grep -i nvidia &> /dev/null; then
    HAS_NVIDIA=true
fi

# 2. Controllo presenza GPU AMD
HAS_AMD=false
if lspci | grep -iE 'vga|3d|display' | grep -iE 'amd|radeon' &> /dev/null; then
    HAS_AMD=true
fi

# 3. Routing verso lo script specifico
if [ "$HAS_NVIDIA" = true ]; then
    echo "[+] Rilevata GPU NVIDIA."
    
    if [ ! -f "$SCRIPT_DIR/manager.sh" ]; then
        echo "[!] ERRORE: File '$SCRIPT_DIR/manager.sh' non trovato!"
        exit 1
    fi

    echo "[→] Avvio di manager.sh (Setup NVIDIA)..."
    echo "--------------------------------------------------"
    exec "$SCRIPT_DIR/manager.sh" "$@"

elif [ "$HAS_AMD" = true ]; then
    echo "[+] Rilevata GPU AMD."

    if [ ! -f "$SCRIPT_DIR/manager-amd.sh" ]; then
        echo "[!] ERRORE: File '$SCRIPT_DIR/manager-amd.sh' non trovato!"
        exit 1
    fi

    echo "[→] Avvio di manager-amd.sh (Setup AMD)..."
    echo "--------------------------------------------------"
    exec "$SCRIPT_DIR/manager-amd.sh" "$@"

else
    echo "[!] ERRORE: Nessuna GPU NVIDIA o AMD supportata è stata rilevata tramite lspci."
    echo "    Verifica che la scheda video sia correttamente collegata o passata in passthrough."
    exit 1
fi
