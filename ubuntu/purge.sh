#!/bin/bash
# Nome: find_remnants.sh
# Versione: 1.0.0
# Data: 2026-10-24
# Autore: mrpink77it
# Descrizione: Cerca residui di Hugging Face, file GGUF e cartelle di modelli in /root, /opt e /home.

if [ "$EUID" -ne 0 ]; then
  echo "Esegui lo script con privilegi di root (sudo)."
  exit 1
fi

echo "=== Avvio scansione residui ==="
TARGET_DIRS=("/root" "/opt" "/home")
PATTERNS=("*huggingface*" "*.gguf" "*llama_models*" "*unsloth*")
found=0

for dir in "${TARGET_DIRS[@]}"; do
  if [ -d "$dir" ]; then
    echo "Analisi di: $dir"
    for pattern in "${PATTERNS[@]}"; do
      while IFS= read -r match; do
        if [ -n "$match" ]; then
          echo "  -> Trovato: $match"
          found=1
        fi
      done < <(find "$dir" -name "$pattern" 2>/dev/null)
    done
  fi
done

if [ $found -eq 0 ]; then
  echo "Nessun elemento corrispondente trovato."
else
  echo "Scansione completata."
fi
