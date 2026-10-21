#!/usr/bin/env bash
set -euo pipefail

MODELS_DIR="${HOME}/llama_models"
HF_CACHE="${HOME}/.cache/huggingface/hub"
UNSLOTH_LOCAL="${HOME}/.unsloth/studio/models"
API_URL="http://127.0.0.1:8080"

mkdir -p "$MODELS_DIR"

sync_models() {
    echo "=== Sincronizzazione modelli da Unsloth / HF Cache ==="
    local count=0
    
    for search_dir in "$HF_CACHE" "$UNSLOTH_LOCAL"; do
        if [ -d "$search_dir" ]; then
            while IFS= read -r src; do
                [ -z "$src" ] && continue
                filename=$(basename "$src")
                target="$MODELS_DIR/$filename"
                if [ ! -e "$target" ]; then
                    ln -s "$src" "$target"
                    echo "[+] Link creato: $filename"
                    ((count++))
                fi
            done < <(find "$search_dir" \( -type f -o -type l \) -name "*.gguf" 2>/dev/null || true)
        fi
    done
    
    echo "Sincronizzazione completata. Nuovi link aggiunti: $count"
    echo ""
}

list_models() {
    echo "=== Modelli disponibili in $MODELS_DIR ==="
    mapfile -t models < <(find "$MODELS_DIR" -maxdepth 1 -name "*.gguf" -exec basename {} \; | sort)
    
    if [ ${#models[@]} -eq 0 ]; then
        echo "Nessun modello trovato."
        return 1
    fi

    for i in "${!models[@]}"; do
        echo "$((i+1))) ${models[$i]}"
    done
    return 0
}

sync_models

if ! list_models; then
    exit 0
fi

echo ""
read -p "Seleziona il numero del modello da caricare (o invio per uscire): " choice

if [[ -z "$choice" ]]; then
    echo "Uscita."
    exit 0
fi

mapfile -t models < <(find "$MODELS_DIR" -maxdepth 1 -name "*.gguf" -exec basename {} \; | sort)
selected_model="${models[$((choice-1))]:-}"

if [ -z "$selected_model" ]; then
    echo "Scelta non valida."
    exit 1
fi

model_id="${selected_model%.gguf}"
echo "Caricamento del modello '$model_id' tramite API..."

response=$(curl -s -X POST "$API_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$model_id\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Test caricamento modello\"}],
    \"max_tokens\": 1
  }")

if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
    echo "Errore durante il caricamento:"
    echo "$response" | jq .
    exit 1
fi

echo "Modello caricato e pronto all'uso su $API_URL"
