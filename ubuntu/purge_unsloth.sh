#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

echo "[*] Arresto e disattivazione di eventuali servizi systemd legati a unsloth..."
systemctl stop unsloth-studio.service 2>/dev/null || true
systemctl disable unsloth-studio.service 2>/dev/null || true
rm -f /etc/systemd/system/unsloth-studio.service
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

echo "[*] Terminazione forzata di eventuali processi residenti in memoria..."
pkill -f unsloth || true

echo "[*] Rimozione pacchetti Python/pip legati a unsloth..."
python3 -m pip uninstall -y unsloth unsloth-zoo 2>/dev/null || true
if [ -d "/opt/gateway/venv" ]; then
    /opt/gateway/venv/bin/pip uninstall -y unsloth unsloth-zoo 2>/dev/null || true
fi

echo "[*] Pulizia forzata delle cache e delle directory di configurazione..."
rm -rf /root/.cache/huggingface
rm -rf /root/.cache/unsloth
rm -rf /root/.unsloth
rm -rf /root/llama_models/*

for home_dir in /home/*; do
    if [ -d "$home_dir/.cache/huggingface" ]; then
        rm -rf "$home_dir/.cache/huggingface"
    fi
    if [ -d "$home_dir/.cache/unsloth" ]; then
        rm -rf "$home_dir/.cache/unsloth"
    fi
    if [ -d "$home_dir/.unsloth" ]; then
        rm -rf "$home_dir/.unsloth"
    fi
done

echo "[OK] Purge completato con successo."
