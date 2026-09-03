#!/usr/bin/env bash

MODELS=(
  "codestral:22b"
  "mistral-small:24b"
  "qwen2.5:14b"
  "mistral-nemo:12b"
  "mxbai-embed-large:latest"
  "nomic-embed-text:latest"
  "qwen2.5-coder:32b"
  "deepseek-coder-v2:latest"
  "qwen2.5-coder:14b"
  "qwen2.5-coder:7b"
  "llama3.1:8b"
  "gemma4:e2b"
  "32k-DSC6.7B:latest"
  "32k-llama2.1:8b"
  "qwen-25k:latest"
  "llama2:latest"
  "qwen-16k:latest"
  "gemma4:e4b"
  "qwen2.5-coder:7b-instruct-q4_K_M"
  "codellama:7b"
  "deepseek-coder:6.7b"
  "qwen2.5-coder:latest"
  "mistral:7b"
  "qwen2.5-coder:7b-instruct"
  "aseio8886/aseio-deepseek-coder6.7b:latest"
  "novaforgeai/deepseek-coder:6.7b-optimized"
  "qwen3.5:9b-q4_K_M"
  "gemma4:latest"
  "llama3.2:3b"
  "qwen3.5:9b"
  "llama3:8b"
  "openthinker:7b"
  "deepseek-r1:7b"
  "codegemma:7b"
  "carstenuhlig/omnicoder-9b:latest"
  "phi4-mini:latest"
  "deepseek-coder:1.3b"
  "qwen3.5:4b"
)

echo "=================================================="
echo " DOWNLOAD AUTOMATICO MODELLI OLLAMA (${#MODELS[@]} totali)"
echo "=================================================="

INSTALLED=$(ollama list | awk 'NR>1 {print $1}')

for model in "${MODELS[@]}"; do
    if echo "$INSTALLED" | grep -qE "^${model}$|^${model}:latest$"; then
        echo "[✔] $model è già presente, salto."
    else
        echo -e "\n[⬇] Scarico $model..."
        ollama pull "$model"
    fi
done

echo -e "\n=================================================="
echo " Operazione completata."
echo "=================================================="
