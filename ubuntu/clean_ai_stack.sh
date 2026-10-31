#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo o come root."
  exit 1
fi

CURRENT_USER="${SUDO_USER:-root}"
USER_HOME=$(eval echo "~$CURRENT_USER")

echo "======================================================================="
echo " ATTENZIONE: Questo script rimuoverà tutti i servizi AI, le cartelle in"
echo " /opt, i container Docker di Dify, i modelli e le cache locali."
echo " I driver di sistema, CUDA, Vulkan e il sistema operativo NON verranno toccati."
echo "======================================================================="
read -p "Vuoi procedere con la pulizia profonda dell'ambiente AI? [S/n]: " choice

case "$choice" in
    [Nn]* ) echo "Operazione annullata."; exit 0 ;;
    * ) ;;
esac

echo -e "\n[1/5] Arresto e rimozione dei servizi systemd dell'AI stack..."
services=(
    "llama-cpp-vulkan.service"
    "unsloth-studio.service"
    "llama-cpu.service"
    "qdrant.service"
    "llm-gateway.service"
    "llama-server.service"
)

for s in "${services[@]}"; do
    if systemctl list-unit-files | grep -q "$s"; then
        echo "[-] Disattivazione e rimozione di $s..."
        systemctl disable --now "$s" 2>/dev/null || true
        rm -f "/etc/systemd/system/$s"
    fi
done
systemctl daemon-reload

echo -e "\n[2/5] Arresto e pulizia dei container Docker (Dify)..."
if command -v docker &> /dev/null; then
    if [ -d "/opt/dify" ]; then
        cd "/opt/dify" && docker compose down -v --rmi local 2>/dev/null || true
    fi
    docker system prune -f --volumes 2>/dev/null || true
fi

echo -e "\n[3/5] Rimozione delle directory applicative in /opt..."
opt_dirs=(
    "/opt/homelab-ai"
    "/opt/homelab-ai-deployer"
    "/opt/dify"
    "/opt/qdrant"
    "/opt/gateway"
    "/opt/llama.cpp"
)

for d in "${opt_dirs[@]}"; do
    if [ -d "$d" ]; then
        echo "[-] Rimozione directory: $d"
        rm -rf "$d"
    fi
done

echo -e "\n[4/5] Pulizia delle cache e dei modelli utente in $USER_HOME..."
target_paths=(
    "$USER_HOME/llama_models"
    "$USER_HOME/.cache/huggingface"
    "$USER_HOME/.unsloth"
    "$USER_HOME/.local/bin/unsloth"
)

for p in "${target_paths[@]}"; do
    if [ -e "$p" ]; then
        echo "[-] Rimozione: $p"
        rm -rf "$p"
    fi
done

echo -e "\n======================================================================="
echo "[OK] Pulizia completata con successo!"
echo " L'infrastruttura AI è stata rimossa mantenendo intatti sistema e driver."
echo "======================================================================="
