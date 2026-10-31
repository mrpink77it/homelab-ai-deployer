#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "[-] Errore: Esegui questo script come root (sudo)." >&2
    exit 1
fi

# Estrazione sicura del token senza caricare le impostazioni interattive del terminale (evita errori con set -u)
if [ -z "${HF_TOKEN:-}" ] && [ -f "/root/.bashrc" ]; then
    HF_TOKEN=$(grep -E '^export HF_TOKEN=' /root/.bashrc 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
fi
if [ -z "${HF_TOKEN:-}" ] && [ -f "/home/alex/.bashrc" ]; then
    HF_TOKEN=$(grep -E '^export HF_TOKEN=' /home/alex/.bashrc 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
fi
export HF_TOKEN="${HF_TOKEN:-}"

UNSLOTH_DIR="/root/.unsloth/studio/models"
MODELS_DIR="/root/llama_models"
SETUP_SCRIPT="./setup_unsloth.sh"
HF_VENV="/opt/hf_env"
PYTHON_BIN="$HF_VENV/bin/python3"

echo "=== 1. Verifica prerequisiti e struttura directory ==="

if [ ! -d "/root/.unsloth" ]; then
    echo "[-] Errore: Unsloth Studio non risulta installato in /root/.unsloth." >&2
    echo "[!] Esegui prima lo script di installazione: sudo $SETUP_SCRIPT" >&2
    exit 1
fi

mkdir -p "$MODELS_DIR"
mkdir -p "$UNSLOTH_DIR"

if [ ! -f "$PYTHON_BIN" ]; then
    echo "[*] Creazione virtual environment isolato per Hugging Face in $HF_VENV..."
    python3 -m venv "$HF_VENV"
    "$HF_VENV/bin/pip" install --upgrade pip
    "$HF_VENV/bin/pip" install -q huggingface_hub
fi

download_model() {
    local repo="$1"
    local filename="$2"
    local target_path="$UNSLOTH_DIR/$filename"

    echo "----------------------------------------------------------------------"
    echo "[*] Verifica/Download: ${filename}"
    echo "    Repository: ${repo}"
    echo "----------------------------------------------------------------------"

    if [ -f "$target_path" ] || [ -f "$MODELS_DIR/$filename" ]; then
        echo "[OK] File già presente in locale, skip."
        return 0
    fi

    if ! "$PYTHON_BIN" - "$repo" "$filename" "$UNSLOTH_DIR" << 'EOF_PY'; then
from huggingface_hub import hf_hub_download
import sys
import os

repo_id = sys.argv[1]
fname = sys.argv[2]
target_dir = sys.argv[3]
token = os.getenv("HF_TOKEN") or None

try:
    hf_hub_download(
        repo_id=repo_id,
        filename=fname,
        local_dir=target_dir,
        token=token
    )
except Exception as e:
    print(f"[-] Errore download {repo_id}/{fname}: {e}", file=sys.stderr)
    sys.exit(1)
EOF_PY
        echo "[-] Avviso: Impossibile scaricare $filename da $repo. Proseguo..." >&2
    fi
}

echo ""
echo "=== 2. Download Modelli Core ed Esistenti ==="
download_model "BAAI/bge-m3" "bge-m3-FP16.gguf"
download_model "unsloth/DeepSeek-R1-Distill-Qwen-14B-GGUF" "DeepSeek-R1-Distill-Qwen-14B-Q5_K_M.gguf"
download_model "bartowski/dflash-NVIDIA-Nemotron-3.5-Bolt-E4B-GGUF" "dflash-NVIDIA-Nemotron-3.5-Bolt-E4B-Q8_0.gguf"
download_model "bartowski/gemma-2-12b-it-GGUF" "gemma-4-12b-it-Q3_K_S.gguf"
download_model "bartowski/Llama-3.3-70B-Instruct-GGUF" "Llama-3.3-70B-Instruct-Q4_K_M.gguf"
download_model "bartowski/Mistral-7B-Instruct-v0.3-GGUF" "Mistral-7B-Instruct-v0.3-Q6_K.gguf"
download_model "mradermacher/NVIDIA-Nemotron-3.5-Bolt-E4B-UD-GGUF" "NVIDIA-Nemotron-3.5-Bolt-E4B-UD-Q4_K_XL.gguf"
download_model "unsloth/Qwen2.5-Coder-32B-Instruct-GGUF" "Qwen2.5-Coder-32B-Instruct-Q4_K_M.gguf"
download_model "unsloth/Qwen2.5-Coder-14B-Instruct-GGUF" "Qwen2.5-Coder-14B-Instruct-Q5_K_M.gguf"
download_model "unsloth/Qwen2.5-Coder-7B-Instruct-GGUF" "Qwen2.5-Coder-7B-Instruct-Q8_0.gguf"
download_model "bartowski/Qwen2.5-VL-7B-Instruct-GGUF" "Qwen2.5-VL-7B-Instruct-Q5_K_M.gguf"
download_model "unsloth/Meta-Llama-3.1-8B-Instruct-GGUF" "unsloth-Meta-Llama-3.1-8B-Instruct-Q6_K.gguf"

echo ""
echo "=== 3. Download Modelli SLM, Embedding & Vision ==="
download_model "unsloth/Llama-3.2-3B-Instruct-GGUF" "Llama-3.2-3B-Instruct-Q4_K_M.gguf"
download_model "Qwen/Qwen2.5-1.5B-Instruct-GGUF" "qwen2.5-1.5b-instruct-q8_0.gguf"
download_model "bartowski/gemma-2-2b-it-GGUF" "gemma-2-2b-it-Q8_0.gguf"
download_model "nomic-ai/nomic-embed-text-v1.5-GGUF" "nomic-embed-text-v1.5.Q8_0.gguf"

echo ""
echo "=== 4. Download Modelli Specializzati Principali ==="
download_model "ggerganov/whisper.cpp" "ggml-large-v3-turbo.bin"
download_model "bartowski/Qwen2.5-32B-Instruct-GGUF" "Qwen2.5-32B-Instruct-Q4_K_M.gguf"
download_model "bartowski/Hermes-3-Llama-3.1-8B-GGUF" "Hermes-3-Llama-3.1-8B-Q6_K.gguf"
download_model "bartowski/Mistral-Nemo-Instruct-2407-GGUF" "Mistral-Nemo-Instruct-2407-Q5_K_M.gguf"
download_model "bartowski/DeepSeek-Coder-V2-Lite-Instruct-GGUF" "DeepSeek-Coder-V2-Lite-Instruct-Q4_K_M.gguf"

echo ""
echo "=== 5. Sincronizzazione Link Simbolici con manage_models.sh ==="
if [ -f "./manage_models.sh" ]; then
    echo "[*] Esecuzione sincronizzazione..."
    chmod +x ./manage_models.sh
    ./manage_models.sh || true
else
    echo "[!] Avviso: ./manage_models.sh non trovato. I file sono in $UNSLOTH_DIR." >&2
fi

echo "================================================================="
echo "[OK] Script completato con successo!"
echo " Modelli in Unsloth: $UNSLOTH_DIR"
echo " Modelli in Llama:   $MODELS_DIR"
echo "================================================================="
