#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="/opt/llama_models"
sudo mkdir -p "$TARGET_DIR"
sudo chmod 755 "$TARGET_DIR"

HF_TOKEN=""
if [ -f "$HOME/.bashrc" ]; then
    HF_TOKEN=$(grep -E '^export HF_TOKEN=' "$HOME/.bashrc" | cut -d'=' -f2 | tr -d '"' | tr -d "'" || true)
fi
if [ -z "$HF_TOKEN" ] && [ -f "/root/.bashrc" ]; then
    HF_TOKEN=$(sudo grep -E '^export HF_TOKEN=' /root/.bashrc | cut -d'=' -f2 | tr -d '"' | tr -d "'" || true)
fi

HF_ARG=""
[ -n "$HF_TOKEN" ] && HF_ARG="--token $HF_TOKEN"

echo "=== Inizio Download Modelli in $TARGET_DIR ==="

download_model() {
    local repo="$1" filename="$2" dest="$TARGET_DIR/$filename"
    echo -e "\n[*] Download: $filename..."
    if [ -f "$dest" ]; then
        echo "    [OK] File già presente, skip."
        return 0
    fi
    huggingface-cli download "$repo" "$filename" --local-dir "$TARGET_DIR" --local-dir-use-symlinks False $HF_ARG && echo "    [OK] Completato" || echo "    [-] ERRORE"
}

download_model "mradermacher/automotive-diagnostics-llm-GGUF" "automotive-diagnostics-llm-f16.gguf"
download_model "gpustack/bge-m3-GGUF" "bge-m3-FP16.gguf"
download_model "unsloth/DeepSeek-Coder-V2-Lite-Instruct-GGUF" "DeepSeek-Coder-V2-Lite-Instruct-Q4_K_M.gguf"
download_model "unsloth/DeepSeek-R1-Distill-Qwen-14B-GGUF" "DeepSeek-R1-Distill-Qwen-14B-Q5_K_M.gguf"
download_model "mradermacher/DeepSeek-V4-Pro-Qwen3.5-9B-GGUF" "DeepSeek-V4-Pro-Qwen3.5-9B.Q4_K_M.gguf"
download_model "unsloth/NVIDIA-Nemotron-3.5-Bolt-E4B-GGUF" "dflash-NVIDIA-Nemotron-3.5-Bolt-E4B-Q8_0.gguf"
download_model "bartowski/gemma-2-2b-it-GGUF" "gemma-2-2b-it-Q8_0.gguf"
download_model "bartowski/gemma-2-9b-it-GGUF" "gemma-2-9b-it-Q5_K_M.gguf"
download_model "unsloth/gemma-4-12b-it-GGUF" "gemma-4-12b-it-Q3_K_S.gguf"
download_model "mradermacher/gemma4-12B-medical-sft-GGUF" "gemma4-12B-medical-sft.Q3_K_M.gguf"
download_model "NousResearch/Hermes-3-Llama-3.1-8B-GGUF" "Hermes-3-Llama-3.1-8B-Q6_K.gguf"
download_model "unsloth/Llama-3.2-3B-Instruct-GGUF" "Llama-3.2-3B-Instruct-Q4_K_M.gguf"
download_model "mradermacher/llama-3.2-3b-it-Legal-Chatbot-GGUF" "llama-3.2-3b-it-Legal-Chatbot.Q8_0.gguf"
download_model "mradermacher/llama-3.2-3b-it-Medical-Terms-v8.0-GGUF" "llama-3.2-3b-it-Medical-Terms-v8.0.Q8_0.gguf"
download_model "mradermacher/ltx-2b-v0.9-GGUF" "ltx-2b-v0.9-bf16.gguf"
download_model "bartowski/Mistral-7B-Instruct-v0.3-GGUF" "Mistral-7B-Instruct-v0.3-Q6_K.gguf"
download_model "bartowski/Mistral-Nemo-Instruct-2407-GGUF" "Mistral-Nemo-Instruct-2407-Q5_K_M.gguf"
download_model "unsloth/NVIDIA-Nemotron-3.5-Bolt-E4B-GGUF" "mmproj-F16.gguf"
download_model "unsloth/gemma-4-12b-it-GGUF" "mtp-gemma-4-12b-it.gguf"
download_model "mradermacher/music_generation_model-GGUF" "music_generation_model.Q6_K.gguf"
download_model "mradermacher/nexus-medical-GGUF" "nexus-medical-f16.gguf"
download_model "nomic-ai/nomic-embed-text-v1.5-GGUF" "nomic-embed-text-v1.5.Q8_0.gguf"
download_model "unsloth/NVIDIA-Nemotron-3.5-Bolt-E4B-GGUF" "NVIDIA-Nemotron-3.5-Bolt-E4B-UD-Q4_K_XL.gguf"
download_model "Qwen/Qwen2.5-1.5B-Instruct-GGUF" "qwen2.5-1.5b-instruct-q8_0.gguf"
download_model "unsloth/Qwen2.5-32B-Instruct-GGUF" "Qwen2.5-32B-Instruct-Q4_K_M.gguf"
download_model "Qwen/Qwen2.5-7B-Instruct-GGUF" "Qwen2.5-7B-Instruct.Q4_K_M.gguf"
download_model "unsloth/Qwen2.5-Coder-14B-Instruct-GGUF" "Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf"
download_model "unsloth/Qwen2.5-Coder-14B-Instruct-GGUF" "Qwen2.5-Coder-14B-Instruct-Q5_K_M.gguf"
download_model "unsloth/Qwen2.5-Coder-32B-Instruct-GGUF" "Qwen2.5-Coder-32B-Instruct-Q4_K_M.gguf"
download_model "unsloth/Qwen2.5-Coder-7B-Instruct-GGUF" "Qwen2.5-Coder-7B-Instruct-Q6_K.gguf"
download_model "unsloth/Qwen2.5-Coder-7B-Instruct-GGUF" "Qwen2.5-Coder-7B-Instruct-Q8_0.gguf"
download_model "unsloth/Qwen2.5-VL-7B-Instruct-GGUF" "Qwen2.5-VL-7B-Instruct-Q5_K_M.gguf"
download_model "mradermacher/Qwen3.5-4B-3D-Coder-GGUF" "Qwen3.5-4B-3D-Coder-Q8_0.gguf"
download_model "mradermacher/spark-x2.5-1.7b-rizzo-flow-lora-GGUF" "spark-x2.5-1.7b-rizzo-flow-lora-bf16.gguf"
download_model "mradermacher/terramind-7b-multitask-GGUF" "terramind-7b-multitask-Q4_K_M.gguf"
download_model "mudler/timestral-cpp-gguf" "209M/timestral-209m-f32.gguf"
download_model "featherless-ai-quants/unsloth-Meta-Llama-3.1-8B-Instruct-GGUF" "unsloth-Meta-Llama-3.1-8B-Instruct-Q6_K.gguf"
download_model "unsloth/unsloth-GGUF" "unsloth.Q5_K_M.gguf"

sudo chmod 644 "$TARGET_DIR"/* 2>/dev/null || true
echo -e "\n=== DOWNLOAD COMPLETATO ==="
ls -lh "$TARGET_DIR"
