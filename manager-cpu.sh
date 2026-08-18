#!/usr/bin/env bash
# ==============================================================================
# Script Name: manager-cpu.sh
# Version:     1.3.3
# Project:     homelab-ai-deployer
# Description: CPU Manager per llama.cpp (AVX2/AVX-512 + OpenMP) & Open WebUI
# ==============================================================================

set -euo pipefail

# --- VARIABILI GLOBALI DI SISTEMA ---
BASE_DIR="/opt/homelab-ai"
MODELS_DIR="${BASE_DIR}/models"
LLAMA_DIR="${BASE_DIR}/llama.cpp"
WEBUI_DIR="${BASE_DIR}/open-webui"
WEBUI_VENV="${WEBUI_DIR}/venv"

ACTIVE_MODEL=""
OPTIMIZED_THREADS=4
OPTIMIZED_CTX=32768
OPTIMIZED_BATCH=512
AUTO_MODE="false"

if [[ "${1:-}" == "--auto" ]]; then
    AUTO_MODE="true"
fi

# --- CATALOGO MODELLI CPU PRESETTATI (Tutti Open Weights, Nessun Token Richiesto) ---
# Contesto portato a 32768 (32k) su tutti i modelli.
declare -A CPU_MODELS=(
    ["01. Qwen2.5-3B-Instruct"]="https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf|Qwen2.5-3B-Instruct-Q4_K_M.gguf|32768|1024|4"
    ["02. Phi-3.5-mini-instruct"]="https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf|Phi-3.5-mini-instruct-Q4_K_M.gguf|32768|512|6"
    ["03. Qwen2.5-7B-Instruct"]="https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf|Qwen2.5-7B-Instruct-Q4_K_M.gguf|32768|512|8"
    ["04. DeepSeek-R1-Distill-Qwen-7B"]="https://huggingface.co/unsloth/DeepSeek-R1-Distill-Qwen-7B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf|DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf|32768|256|8"
    ["05. Hermes-3-Llama-3.1-8B"]="https://huggingface.co/bartowski/Hermes-3-Llama-3.1-8B-GGUF/resolve/main/Hermes-3-Llama-3.1-8B-Q4_K_M.gguf|Hermes-3-Llama-3.1-8B-Q4_K_M.gguf|32768|512|8"
    ["06. Mistral-Nemo-Instruct (12B)"]="https://huggingface.co/bartowski/Mistral-Nemo-Instruct-2407-GGUF/resolve/main/Mistral-Nemo-Instruct-2407-Q4_K_M.gguf|Mistral-Nemo-Instruct-2407-Q4_K_M.gguf|32768|512|16"
    ["07. Qwen2.5-14B-Instruct"]="https://huggingface.co/bartowski/Qwen2.5-14B-Instruct-GGUF/resolve/main/Qwen2.5-14B-Instruct-Q4_K_M.gguf|Qwen2.5-14B-Instruct-Q4_K_M.gguf|32768|512|16"
    ["08. Qwen2.5-32B-Instruct"]="https://huggingface.co/bartowski/Qwen2.5-32B-Instruct-GGUF/resolve/main/Qwen2.5-32B-Instruct-Q4_K_M.gguf|Qwen2.5-32B-Instruct-Q4_K_M.gguf|32768|256|32"
    ["09. DeepSeek-R1-Distill-Qwen-32
