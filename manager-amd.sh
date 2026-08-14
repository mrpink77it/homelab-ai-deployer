#!/usr/bin/env bash
# ==============================================================================
# Homelab AI Deployer - AMD GPU Installer (ROCm / Vulkan / Experimental)
# ==============================================================================
set -euo pipefail

echo "=================================================="
echo "   Homelab AI Deployer - Setup GPU AMD           "
echo "=================================================="

# 1. Rilevamento modello GPU AMD via lspci
AMDGPU_INFO=$(lspci -nn | grep -iE 'vga|3d' | grep -i amd || true)

if [ -z "$AMDGPU_INFO" ]; then
    echo "[!] ERRORE: Nessuna GPU AMD rilevata nel sistema."
    exit 1
fi

echo "[+] GPU AMD Rilevata:"
echo "    $AMDGPU_INFO"
echo "--------------------------------------------------"

# 2. Selezione della modalità / Backend
echo "Seleziona il backend da configurare:"
echo " 1) ROCm Ufficiale     (RX 6000/7000 series, RDNA2/RDNA3)"
echo " 2) Vulkan / llama.cpp  (Consigliato per RX 5000 / RDNA1 - 5700 XT, stabilità 100%)"
echo " 3) ROCm Sperimentale  (Hack HSA_OVERRIDE_GFX_VERSION=10.3.0 per RX 5700/5700 XT)"
read -rp "Inserisci il numero dell'opzione [1-3]: " CHOICE

BACKEND_MODE=""
case $CHOICE in
    1)
        BACKEND_MODE="ROCM_OFFICIAL"
        ;;
    2)
        BACKEND_MODE="VULKAN"
        ;;
    3)
        BACKEND_MODE="ROCM_EXPERIMENTAL"
        ;;
    *)
        echo "[!] Scelta non valida. Uscita."
        exit 1
        ;;
esac

echo "--------------------------------------------------"
echo "[+] Avvio installazione per profilo: $BACKEND_MODE"
echo "--------------------------------------------------"

# Aggiornamento pacchetti base
sudo apt-get update && sudo apt-get install -y wget curl git build-essential cmake

# 3. Esecuzione installazione in base alla scelta
case $BACKEND_MODE in
    ROCM_OFFICIAL)
        echo "[+] Installazione stack ROCm ufficiale..."
        # Driver e librerie ROCm standard
        sudo apt-get install -y rocm-hip-sdk rocm-opencl-sdk
        
        # Setup ambiente PyTorch ROCm
        pip install --upgrade pip
        pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/rocm6.1
        
        echo "[✓] ROCm Ufficiale configurato con successo!"
        ;;

    VULKAN)
        echo "[+] Installazione backend Vulkan & compilazione llama.cpp..."
        sudo apt-get install -y libvulkan-dev vulkan-tools mesa-vulkan-drivers

        # Clona e compila llama.cpp con flag Vulkan
        if [ ! -d "llama.cpp" ]; then
            git clone https://github.com/ggerganov/llama.cpp
        fi
        cd llama.cpp
        cmake -B build -DGGML_VULKAN=1
        cmake --build build --config Release -j$(nproc)
        cd ..

        echo "[✓] Backend Vulkan compilato ed eseguibile pronto in ./llama.cpp/build/bin/llama-server"
        ;;

    ROCM_EXPERIMENTAL)
        echo "[!] Configurazione ROCm Sperimentale per RDNA1 (RX 5700 / 5700 XT)..."
        sudo apt-get install -y rocm-hip-sdk rocm-opencl-sdk

        # Installazione PyTorch ROCm
        pip install --upgrade pip
        pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/rocm6.1

        # Inserimento override permanente in .bashrc dell'utente
        if ! grep -q "HSA_OVERRIDE_GFX_VERSION" ~/.bashrc; then
            echo 'export HSA_OVERRIDE_GFX_VERSION=10.3.0' >> ~/.bashrc
            echo 'export ROCM_PATH=/opt/rocm' >> ~/.bashrc
        fi
        
        export HSA_OVERRIDE_GFX_VERSION=10.3.0
        echo "[✓] Profilo Sperimentale configurato. HSA_OVERRIDE_GFX_VERSION=10.3.0 impostato."
        echo "[!] NOTA: Se si verificano Kernel Panic o Segmentation Fault, passa alla modalità Vulkan."
        ;;
esac

echo "=================================================="
echo "   Installazione completata!"
echo "=================================================="
