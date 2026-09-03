#!/bin/bash

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}======================================================${NC}"
echo -e "${GREEN}   Ollama Models Downloader: Vibecoding + AnythingLLM${NC}"
echo -e "${BLUE}======================================================${NC}\n"

MODELS=(
    # --- MODELLI CODING (Vibecoding / Agent CLI) ---
    "qwen2.5-coder:7b"      # Veloce, 100% VRAM
    "llama3.1:8b"           # Ottimo per tool-calling JSON
    "qwen2.5-coder:14b"     # Best Buy per Claude Code / Aider
    "deepseek-coder-v2"     # MoE molto efficiente
    "qwen2.5-coder:32b"     # Heavy reasoning architetturale
    
    # --- MODELLI EMBEDDING (Motore di Ricerca per AnythingLLM) ---
    "nomic-embed-text"      # Standard di mercato, super leggero (~300MB VRAM), 8k contesto
    "mxbai-embed-large"     # Più pesante (~700MB VRAM) ma precisione di recupero altissima
    
    # --- MODELLI RAG TEXT (Lettura Documenti per AnythingLLM) ---
    "mistral-nemo:12b"      # Il re del RAG locale. 128k di contesto, bilanciamento RAM/VRAM perfetto
    "qwen2.5:14b"           # Versione base (non-coder). Eccellente comprensione dell'italiano e documenti complessi
)

echo -e "${YELLOW}Inizio il pull di ${#MODELS[@]} modelli...${NC}\n"

for model in "${MODELS[@]}"; do
    echo -e "${BLUE}[*] Pulling: ${GREEN}${model}${NC}"
    ollama pull "$model"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[+] ${model} pronto!${NC}\n"
    else
        echo -e "${YELLOW}[!] Errore con ${model}.${NC}\n"
    fi
done

echo -e "${GREEN}Setup completato. Tutti i modelli sono pronti per l'uso.${NC}"
