#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

echo "[*] Rimozione pacchetti Python/pip legati a unsloth..."
python3 -m pip uninstall -y unsloth unsloth-zoo 2>/dev/null || true
if [ -d "/opt/gateway/venv" ]; then
    /opt/gateway/venv/bin/pip uninstall -y unsloth unsloth-zoo 2>/dev/null || true
fi

echo "[*] Pulizia delle cache di Hugging Face e Unsloth..."
rm -rf /root/.cache/huggingface
rm -rf /root/.cache/unsloth
rm -rf /root/.unsloth
rm -rf /root/llama_models/*

# Pulizia anche per utenti non-root esistenti nel sistema
for home_dir in /home/*; do
    if [ -d "$home_dir/.cache/huggingface" ]; then
        rm -rf "$home_dir/.cache/huggingface"
        echo "[*] Rimossa cache HF per $home_dir"
    fi
    if [ -d "$home_dir/.cache/unsloth" ]; then
        rm -rf "$home_dir/.cache/unsloth"
    fi
done

echo "[*] Pulizia completata con successo."
