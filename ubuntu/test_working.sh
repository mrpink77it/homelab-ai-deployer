#!/usr/bin/env bash
# ==============================================================================
# test_dual_gpu_bench.sh - Selezione modello e Benchmark Dual-GPU (/opt/llama.cpp)
# ==============================================================================
set -e

MODELS_DIR="/home/alex/llama_models"
LLAMA_DIR="/opt/llama.cpp"

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

if [ ! -d "$MODELS_DIR" ] || [ -z "$(ls -A "$MODELS_DIR"/*.gguf 2>/dev/null)" ]; then
  echo "[-] Nessun file .gguf trovato in $MODELS_DIR."
  exit 1
fi

if [ -f "$LLAMA_DIR/build/bin/llama-bench" ]; then
    LLAMA_BENCH_PATH="$LLAMA_DIR/build/bin/llama-bench"
elif [ -f "$LLAMA_DIR/llama-bench" ]; then
    LLAMA_BENCH_PATH="$LLAMA_DIR/llama-bench"
else
    echo "[!] Eseguibile llama-bench non trovato in $LLAMA_DIR. Compilazione in corso..."
    cd "$LLAMA_DIR"
    cmake -B build -DGGML_VULKAN=ON
    cmake --build build --config Release -j$(nproc)
    LLAMA_BENCH_PATH="$LLAMA_DIR/build/bin/llama-bench"
fi

echo "======================================================================="
echo "         SELEZIONE MODELLO GGUF PER BENCHMARK DUAL-GPU                 "
echo "======================================================================="

models=("$MODELS_DIR"/*.gguf)
select model_path in "${models[@]}"; do
    if [ -n "$model_path" ]; then
        SELECTED_MODEL=$(basename "$model_path")
        echo "[+] Modello selezionato: $SELECTED_MODEL"
        break
    else
        echo "Selezione non valida. Riprova."
    fi
done

FULL_MODEL_PATH="$MODELS_DIR/$SELECTED_MODEL"

echo -e "\n======================================================================="
echo " 1. BENCHMARK AMD RX 5700 XT (Vulkan)"
echo "======================================================================="
GGML_VK_VISIBLE_DEVICES=0 "$LLAMA_BENCH_PATH" -m "$FULL_MODEL_PATH" -p 512 -n 128 -r 3 || echo "[!] Test Vulkan fallito."

echo -e "\n======================================================================="
echo " 2. BENCHMARK NVIDIA RTX 3060 Ti (CUDA / Device 0)"
echo "======================================================================="
if command -v nvidia-smi &> /dev/null; then
    CUDA_VISIBLE_DEVICES=0 GGML_CUDA_DEVICE=0 "$LLAMA_BENCH_PATH" -m "$FULL_MODEL_PATH" -p 512 -n 128 -r 3 || echo "[!] Test NVIDIA fallito."
else
    echo "[!] Driver NVIDIA non rilevati."
fi

echo -e "\n[OK] Benchmark completati!"
