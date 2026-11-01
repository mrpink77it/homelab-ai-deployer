#!/usr/bin/env bash
set -euo pipefail

TEST_MODE=false
if [[ "${1:-}" == "--test" ]] || [[ "${1:-}" == "-t" ]]; then
    TEST_MODE=true
    echo "=== MODO TEST ATTIVO: Verifica esistenza URL remoto senza download ==="
fi

TARGET_DIR="/opt/llama_models"
if [ "$TEST_MODE" = false ]; then
    sudo mkdir -p "$TARGET_DIR"
    sudo chmod 755 "$TARGET_DIR"
fi

HF_TOKEN=""
if [ -f "$HOME/.bashrc" ]; then
    HF_TOKEN=$(grep -E '^export HF_TOKEN=' "$HOME/.bashrc" | cut -d'=' -f2 | tr -d '"' | tr -d "'" || true)
fi
if [ -z "$HF_TOKEN" ] && [ -f "/root/.bashrc" ]; then
    HF_TOKEN=$(sudo grep -E '^export HF_TOKEN=' /root/.bashrc | cut -d'=' -f2 | tr -d '"' | tr -d "'" || true)
fi

HF_ARG=""
[ -n "$HF_TOKEN" ] && HF_ARG="--token $HF_TOKEN"

# Gestione isolata di huggingface-cli tramite virtualenv locale (evita PEP 668)
HF_CLI="huggingface-cli"
if ! command -v huggingface-cli &> /dev/null; then
    VENV_DIR="/opt/hf_cli_venv"
    if [ ! -f "$VENV_DIR/bin/huggingface-cli" ]; then
        echo "[*] huggingface-cli non trovato. Configurazione ambiente virtuale isolato in $VENV_DIR..."
        sudo apt update -qq && sudo apt install -y python3-venv python3-pip -qq
        sudo python3 -m venv "$VENV_DIR"
        sudo "$VENV_DIR/bin/pip" install --upgrade pip -qq
        sudo "$VENV_DIR/bin/pip" install huggingface_hub[cli] -qq
    fi
    HF_CLI="$VENV_DIR/bin/huggingface-cli"
fi

[ "$TEST_MODE" = false ] && echo "=== Inizio Download Modelli in $TARGET_DIR ==="

download_model() {
    local repo="$1"
    local filename="$2"
    local dest="$TARGET_DIR/$filename"
    
    if [ "$TEST_MODE" = true ]; then
        local url="https://huggingface.co/$repo/resolve/main/$filename"
        local auth_header=""
        [ -n "$HF_TOKEN" ] && auth_header="Authorization: Bearer $HF_TOKEN"
        
        local status_code
        status_code=$(curl -s -o /dev/null -I -w "%{http_code}" -L ${auth_header:+-H "$auth_header"} "$url")
        
        if [ "$status_code" -eq 200 ]; then
            echo "[OK 200] $filename -> $repo"
        else
            echo "[-] ERRORE $status_code: $filename NON TROVATO su $repo"
        fi
        return 0
    fi

    echo -e "\n[*] Download: $filename..."
    if [ -f "$dest" ]; then
        echo "    [OK] File già presente, skip."
        return 0
    fi
    
    sudo "$HF_CLI" download "$repo" "$filename" --local-dir "$TARGET_DIR" $HF_ARG && echo "    [OK] Completato" || echo "    [-] ERRORE"
}

# Modelli verificati e stabili
download_model "gpustack/bge-m3-GGUF" "bge-m3-FP16.gguf"
download_model "unsloth/DeepSeek-R1-Distill-Qwen-14B-GGUF" "DeepSeek-R1-Distill-Qwen-14B-Q5_K_M.gguf"
download_model "mradermacher/DeepSeek-V4-Pro-Qwen3.5-9B-GGUF" "DeepSeek-V4-Pro-Qwen3.5-9B.Q4_K_M.gguf"
download_model "unsloth/NVIDIA-Nemotron-3.5-Bolt-E4B-GGUF" "dflash-NVIDIA-Nemotron-3.5-Bolt-E4B-Q8_0.gguf"
download_model "bartowski/gemma-2-2b-it-GGUF" "gemma-2-2b-it-Q8_0.gguf"
download_model "bartowski/gemma-2-9b-it-GGUF" "gemma-2-9b-it-Q5_K_M.gguf"
download_model "unsloth/gemma-4-12b-it-GGUF" "gemma-4-12b-it-Q3_K_S.gguf"
download_model "mradermacher/gemma4-12B-medical-sft-GGUF" "gemma4-12B-medical-sft.Q3_K_M.gguf"
download_model "unsloth/Llama-3.2-3B-Instruct-GGUF" "Llama-3.2-3B-Instruct-Q4_K_M.gguf"
download_model "mradermacher/llama-3.2-3b-it-Medical-Terms-v8.0-GGUF" "llama-3.2-3b-it-Medical-Terms-v8.0.Q8_0.gguf"
download_model "bartowski/Mistral-7B-Instruct-v0.3-GGUF" "Mistral-7B-Instruct-v0.3-Q6_K.gguf"
download_model "bartowski/Mistral-Nemo-Instruct-2407-GGUF" "Mistral-Nemo-Instruct-2407-Q5_K_M.gguf"
download_model "unsloth/NVIDIA-Nemotron-3.5-Bolt-E4B-GGUF" "mmproj-F16.gguf"
download_model "unsloth/gemma-4-12b-it-GGUF" "mtp-gemma-4-12b-it.gguf"
download_model "mradermacher/music_generation_model-GGUF" "music_generation_model.Q6_K.gguf"
download_model "nomic-ai/nomic-embed-text-v1.5-GGUF" "nomic-embed-text-v1.5.Q8_0.gguf"
download_model "unsloth/NVIDIA-Nemotron-3.5-Bolt-E4B-GGUF" "NVIDIA-Nemotron-3.5-Bolt-E4B-UD-Q4_K_XL.gguf"
download_model "Qwen/Qwen2.5-1.5B-Instruct-GGUF" "qwen2.5-1.5b-instruct-q8_0.gguf"
download_model "unsloth/Qwen2.5-Coder-14B-Instruct-GGUF" "Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf"
download_model "unsloth/Qwen2.5-Coder-14B-Instruct-GGUF" "Qwen2.5-Coder-14B-Instruct-Q5_K_M.gguf"
download_model "unsloth/Qwen2.5-Coder-32B-Instruct-GGUF" "Qwen2.5-Coder-32B-Instruct-Q4_K_M.gguf"
download_model "unsloth/Qwen2.5-Coder-7B-Instruct-GGUF" "Qwen2.5-Coder-7B-Instruct-Q6_K.gguf"
download_model "unsloth/Qwen2.5-Coder-7B-Instruct-Q8_0.gguf" "Qwen2.5-Coder-7B-Instruct-Q8_0.gguf"
download_model "unsloth/Qwen2.5-VL-7B-Instruct-GGUF" "Qwen2.5-VL-7B-Instruct-Q5_K_M.gguf"
download_model "mudler/timestral-cpp-gguf" "209M/timestral-209m-f32.gguf"
download_model "featherless-ai-quants/unsloth-Meta-Llama-3.1-8B-Instruct-GGUF" "unsloth-Meta-Llama-3.1-8B-Instruct-Q6_K.gguf"

if [ "$TEST_MODE" = false ]; then
    sudo chmod 644 "$TARGET_DIR"/* 2>/dev/null || true
    echo -e "\n=== DOWNLOAD COMPLETATO ==="
    ls -lh "$TARGET_DIR"
else
    echo -e "\n=== VERIFICA TEST COMPLETATA ==="
fi
