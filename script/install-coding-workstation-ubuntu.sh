#!/usr/bin/env bash
# ==============================================================================
# install-workstation.sh — Setup completo per Ubuntu 24.04 LTS
# Configuration: Dual GPU (AMD RX 5700 XT Vulkan + NVIDIA RTX 3060 Ti CUDA)
# ==============================================================================
set -e

echo "=============================================================="
echo "🚀 Avvio installazione Workstation AI su Ubuntu 24.04 LTS"
echo "=============================================================="

# ----- 1. Aggiornamento Sistema e Repositories -------------------------------
echo -e "\n📦 [1/7] Aggiornamento dei pacchetti di sistema..."
sudo apt update && sudo apt upgrade -y

# ----- 2. Installazione Pacchetti Richiesti e Strumenti di Base --------------
echo -e "\n🛠️ [2/7] Installazione librerie, pacchetti base e tool..."
sudo apt install -y \
    build-essential \
    g++ \
    cmake \
    git \
    wget \
    curl \
    libcurl4-openssl-dev \
    htop \
    btop \
    nvtop \
    glances \
    pciutils \
    mc \
    libx11-dev \
    libxmu-dev \
    libxi-dev \
    libglu1-mesa-dev \
    libfreeimage-dev \
    libglfw3-dev \
    freeglut3-dev \
    nodejs \
    npm \
    python3 \
    python3-pip \
    python3-venv \
    pipx

# ----- 3. Installazione Driver Vulkan e CUDA Toolkit -------------------------
echo -e "\n🎮 [3/7] Installazione Vulkan e NVIDIA CUDA Toolkit..."
sudo apt install -y \
    vulkan-tools \
    libvulkan-dev \
    vulkan-validationlayers \
    mesa-vulkan-drivers \
    mesa-utils \
    nvidia-driver-550 \
    nvidia-cuda-toolkit

# Assicura che la directory dei binari pipx sia nel PATH
pipx ensurepath

# ----- 4. Installazione Aider e HuggingFace CLI -----------------------------
echo -e "\n🤖 [4/7] Installazione di Aider e HuggingFace CLI..."
pipx install aider-chat || pipx upgrade aider-chat
pipx install "huggingface_hub[cli]" || pipx upgrade "huggingface_hub[cli]"

# ----- 5. Configurazione Directory di Lavoro ---------------------------------
echo -e "\n📁 [5/7] Creazione strutture directory in $HOME..."
mkdir -p "$HOME/bin"
mkdir -p "$HOME/models"
mkdir -p "$HOME/src"

# ----- 6. Download e Compilazione llama.cpp (CUDA e Vulkan/Mixed) ------------
echo -e "\n⚙️ [6/7] Clonazione e compilazione di llama.cpp (CUDA & Vulkan)..."
cd "$HOME/src"
if [ ! -d "llama.cpp" ]; then
    git clone https://github.com/ggerganov/llama.cpp.git
fi
cd llama.cpp

# Build 1: CUDA Solo (build-cuda)
echo "  ↳ Compilazione Build CUDA (build-cuda)..."
cmake -B build-cuda -DGGML_CUDA=ON
cmake --build build-cuda --config Release -j$(nproc)

# Build 2: Vulkan + CUDA Misto (build-mixed)
echo "  ↳ Compilazione Build Mista Vulkan + CUDA (build-mixed)..."
cmake -B build-mixed -DGGML_VULKAN=ON -DGGML_CUDA=ON
cmake --build build-mixed --config Release -j$(nproc)

# ----- 7. Installazione Script in ~/bin e Configurazione .bashrc -------------
echo -e "\n📜 [7/7] Scrittura script in $HOME/bin e aggiornamento ~/.bashrc..."

# 7a. dual-llm.sh
cat << 'EOF' > "$HOME/bin/dual-llm.sh"
#!/usr/bin/env bash
set -o pipefail
shopt -s nullglob

MODELS_DIR="${MODELS_DIR:-$HOME/models}"
HOST="${HOST:-127.0.0.1}"
CTX="${CTX:-4096}"

die(){ echo "    ✗ $*" >&2; exit 1; }

CUDA_BIN="$HOME/src/llama.cpp/build-cuda/bin/llama-server"
VK_BIN="$HOME/src/llama.cpp/build-mixed/bin/llama-server"

[ -x "$CUDA_BIN" ] || CUDA_BIN="$(command -v llama-server 2>/dev/null || true)"
[ -x "$VK_BIN" ] || VK_BIN="$(command -v llama-server 2>/dev/null || true)"

echo "=============================================================="
echo "  dual-llm — Gestore Multi-GPU llama-server"
echo "=============================================================="

echo
echo "Seleziona la modalità di esecuzione:"
echo "   [1] MODELLO UNICO (Dual Vulkan) — 1 Modello Split su RX 5700 XT + RTX 3060 Ti (~16GB VRAM)"
echo "   [2] DUE MODELLI SEPARATI        — Modello A (CUDA/Porta 8080) + Modello B (Vulkan/Porta 8081)"

MODE=0
while [ $MODE -eq 0 ]; do
  read -rp "Scelta [1/2]: " m
  case "$m" in
    1) MODE=1 ;;
    2) MODE=2 ;;
    *) echo "      Input non valido" ;;
  esac
done

select_model() {
  local prompt_msg="$1"
  echo >&2
  echo "$prompt_msg ($MODELS_DIR):" >&2

  mapfile -t RAW < <(find "$MODELS_DIR" -maxdepth 1 -name "*.gguf" -printf "%f\n" 2>/dev/null | sort -u)
  
  if [ ${#RAW[@]} -eq 0 ]; then
    echo "    ✗ Nessun file .gguf trovato in $MODELS_DIR" >&2
    exit 1
  fi

  declare -A bases
  for f in "${RAW[@]}"; do
    local b="${f%-0000[0-9]-of-[0-9]*.gguf}"
    bases["$b"]=1
  done

  mapfile -t NAMES < <(printf "%s\n" "${!bases[@]}" | sort)

  local idx=1
  for name in "${NAMES[@]}"; do
    printf "    [%2d] %s\n" "$idx" "$name" >&2
    ((idx++))
  done

  local midx=0
  while [ $midx -eq 0 ]; do
    read -rp "Seleziona modello [1-${#NAMES[@]}]: " n < /dev/tty
    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#NAMES[@]}" ]; then
      midx=$n
    else
      echo "      Input non valido" >&2
    fi
  done
  
  local base="${NAMES[$((midx-1))]}"
  local first_shard
  first_shard=$(find "$MODELS_DIR" -maxdepth 1 -name "${base}-00001-of-*.gguf" -printf "%p\n" 2>/dev/null | head -n 1)

  if [ -n "$first_shard" ]; then
    echo "$first_shard"
  elif [[ "$base" == *.gguf ]]; then
    echo "$MODELS_DIR/$base"
  else
    echo "$MODELS_DIR/$base.gguf"
  fi
}

if [ $MODE -eq 1 ]; then
  [ -x "$VK_BIN" ] || die "Binario Vulkan non trovato in $VK_BIN"
  
  MODEL_PATH=$(select_model "Modelli disponibili per Dual Vulkan")
  [ -z "$MODEL_PATH" ] && die "Nessun modello selezionato."

  PORT="${PORT:-8080}"
  LOG=/tmp/dual-llm-vulkan.log

  echo
  echo "  Avvio Modello Unico su Dual GPU via Vulkan..."
  echo "  Modello: $(basename "$MODEL_PATH")"
  echo "  Porta: $PORT | Context: $CTX"

  nohup "$VK_BIN" \
    -m "$MODEL_PATH" \
    --split-mode layer \
    --host "$HOST" \
    --port "$PORT" \
    --ctx-size "$CTX" \
    --cache-type-k q8_0 \
    --cache-type-v q8_0 \
    > "$LOG" 2>&1 &

  SRV=$!
  echo "  PID: $SRV — Log: $LOG"
  
  echo "  Caricamento in corso..."
  for _ in $(seq 1 120); do
    sleep 1
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://$HOST:$PORT/health" 2>/dev/null)
    [ "$code" = "200" ] && { echo -e "\n  ✅ Server pronto su http://$HOST:$PORT"; exit 0; }
  done
  echo "  ✗ Errore o timeout. Verificare log: tail -n 20 $LOG"

elif [ $MODE -eq 2 ]; then
  [ -x "$CUDA_BIN" ] || die "Binario CUDA non trovato in $CUDA_BIN"
  [ -x "$VK_BIN" ] || die "Binario Vulkan non trovato in $VK_BIN"

  echo "--- MODELLO 1: GPU NVIDIA RTX 3060 Ti (CUDA) ---"
  MODEL_CUDA=$(select_model "Seleziona il modello per la RTX 3060 Ti")

  echo
  echo "--- MODELLO 2: GPU AMD RX 5700 XT (Vulkan) ---"
  MODEL_VK=$(select_model "Seleziona il modello per la RX 5700 XT")

  LOG_CUDA=/tmp/llm-cuda-8080.log
  LOG_VK=/tmp/llm-vulkan-8081.log

  echo
  echo "  Avvio Server 1 (CUDA - RTX 3060 Ti) sulla porta 8080..."
  CUDA_VISIBLE_DEVICES=0 nohup "$CUDA_BIN" \
    -m "$MODEL_CUDA" \
    --host "$HOST" \
    --port 8080 \
    --ctx-size "$CTX" \
    --cache-type-k q8_0 \
    --cache-type-v q8_0 \
    > "$LOG_CUDA" 2>&1 &
  PID_CUDA=$!

  echo "  Avvio Server 2 (Vulkan - RX 5700 XT) sulla porta 8081..."
  GGML_VK_VISIBLE_DEVICES=0 nohup "$VK_BIN" \
    -m "$MODEL_VK" \
    --host "$HOST" \
    --port 8081 \
    --ctx-size "$CTX" \
    --cache-type-k q8_0 \
    --cache-type-v q8_0 \
    > "$LOG_VK" 2>&1 &
  PID_VK=$!

  echo
  echo "  PID Server 1 (CUDA):   $PID_CUDA — Log: $LOG_CUDA"
  echo "  PID Server 2 (Vulkan): $PID_VK — Log: $LOG_VK"
  echo
  echo "  ✅ Modelli avviati! Controlla lo stato dei log o gli endpoint:"
  echo "     - NVIDIA (CUDA)    : http://$HOST:8080"
  echo "     - AMD (Vulkan)     : http://$HOST:8081"
fi
EOF
chmod +x "$HOME/bin/dual-llm.sh"

# 7b. download-models.sh
cat << 'EOF' > "$HOME/bin/download-models.sh"
#!/bin/bash

DEST_DIR="$HOME/models"
mkdir -p "$DEST_DIR"

repos=(
    "bartowski/Qwen2.5.1-Coder-7B-Instruct-GGUF"
    "ijohn07/DeepSeek-Coder-V2-Lite-Instruct-Q5_K_M-GGUF"
    "jfer1015/Codestral-22B-v0.1-Q4_K_M-GGUF"
    "NikolayKozloff/Mistral-Nemo-Instruct-2407-Q8_0-GGUF"
    "Qwen/Qwen2.5-7B-Instruct-GGUF"
    "Qwen/Qwen2.5-14B-Instruct-GGUF"
    "Qwen/Qwen2.5-Coder-7B-Instruct-GGUF"
    "sigmanih/Qwen-Qwen2.5-Coder-14B-Instruct-GGUF-Q6_K"
    "thataigod/gemma-3-27b-it-Q3_K_M-GGUF"
)

echo "=== Avvio download mirato dei soli file .gguf in: $DEST_DIR ==="

for repo in "${repos[@]}"; do
    echo -e "\n--------------------------------------------------"
    echo "📥 Download da: $repo"
    echo "--------------------------------------------------"
    
    hf download "$repo" \
        --include "*.gguf" \
        --local-dir "$DEST_DIR"
done

echo -e "\n✅ Download completato!"
ls -lh "$DEST_DIR"
EOF
chmod +x "$HOME/bin/download-models.sh"

# 7c. benchmark-llm.sh
cat << 'EOF' > "$HOME/bin/benchmark-llm.sh"
#!/usr/bin/env bash
set -o pipefail
shopt -s nullglob

MODELS_DIR="${MODELS_DIR:-$HOME/models}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8080}"
BUILD_VK="$HOME/src/llama.cpp/build-mixed/bin"
BUILD_CUDA="$HOME/src/llama.cpp/build-cuda/bin"

echo "=============================================================="
echo "  LLM & System Benchmark Tool"
echo "=============================================================="

echo "Seleziona tipo di Benchmark:"
echo "  [1] Benchmark Server Attivo (Latency, Prompt Processing & Generation speed via API)"
echo "  [2] Benchmark Hardware Diretto (llama-bench su Dual Vulkan)"
echo "  [3] Benchmark Hardware Diretto (llama-bench su CUDA)"
read -rp "Scelta [1-3]: " CHOICE

case "$CHOICE" in
  1)
    echo -e "\n--- Test Server HTTP ($HOST:$PORT) ---"
    if ! curl -s -o /dev/null "http://$HOST:$PORT/health"; then
      echo "  ✗ Server non raggiungibile su http://$HOST:$PORT. Avvialo prima!"
      exit 1
    fi

    echo "Invio richiesta di test al server (256 tokens)..."
    PAYLOAD='{
      "prompt": "Write a 300-word essay explaining quantum computing to a high school student.",
      "n_predict": 256,
      "temperature": 0.2
    }'

    curl -s -X POST "http://$HOST:$PORT/completion" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" | python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
    timings = data.get("timings", {})
    
    pp_tokens = data.get("tokens_evaluated", 0)
    tg_tokens = data.get("tokens_predicted", 0)
    
    pp_ms = timings.get("prompt_ms", 0)
    tg_ms = timings.get("predicted_ms", 0)
    
    pp_tps = (pp_tokens / (pp_ms / 1000.0)) if pp_ms > 0 else 0
    tg_tps = (tg_tokens / (tg_ms / 1000.0)) if tg_ms > 0 else 0
    
    print("\n==============================================================")
    print("  Risultati API Dettagliati:")
    print("==============================================================")
    print(f"  - Prompt Processing (PP) : {pp_tokens} tokens in {pp_ms:.2f} ms ({pp_tps:.2f} t/s)")
    print(f"  - Text Generation (TG)   : {tg_tokens} tokens in {tg_ms:.2f} ms ({tg_tps:.2f} t/s)")
    print(f"  - Time to First Token    : {pp_ms:.2f} ms")
    print("==============================================================")
except Exception as e:
    print(f"\n  ✗ Errore nel parsing della risposta JSON: {e}")
'
    ;;

  2)
    echo -e "\n--- Test Hardware via Dual Vulkan (llama-bench) ---"
    BENCH_BIN="$BUILD_VK/llama-bench"
    [ -x "$BENCH_BIN" ] || BENCH_BIN="$(command -v llama-bench 2>/dev/null || true)"
    [ -x "$BENCH_BIN" ] || { echo "  ✗ llama-bench non trovato in $BUILD_VK"; exit 1; }

    echo "Seleziona il modello per il benchmark ($MODELS_DIR):"
    mapfile -t RAW < <(find "$MODELS_DIR" -maxdepth 1 -name "*.gguf" -printf "%f\n" | sort -u)
    [ ${#RAW[@]} -eq 0 ] && { echo "  ✗ Nessun file .gguf trovato."; exit 1; }

    for i in "${!RAW[@]}"; do echo "  [$((i+1))] ${RAW[$i]}"; done
    read -rp "Modello [1-${#RAW[@]}]: " M_IDX
    MODEL_FILE="$MODELS_DIR/${RAW[$((M_IDX-1))]}"

    echo -e "\nEsecuzione benchmark su VRAM (pp512, tg128)..."
    "$BENCH_BIN" -m "$MODEL_FILE" -n 128 -p 512 -ngl 99 -sm layer -ts 8,8
    ;;

  3)
    echo -e "\n--- Test Hardware via CUDA (llama-bench su RTX 3060 Ti) ---"
    BENCH_BIN="$BUILD_CUDA/llama-bench"
    [ -x "$BENCH_BIN" ] || BENCH_BIN="$(command -v llama-bench 2>/dev/null || true)"
    [ -x "$BENCH_BIN" ] || { echo "  ✗ llama-bench CUDA non trovato in $BUILD_CUDA"; exit 1; }

    echo "Seleziona il modello per il benchmark ($MODELS_DIR):"
    mapfile -t RAW < <(find "$MODELS_DIR" -maxdepth 1 -name "*.gguf" -printf "%f\n" | sort -u)
    [ ${#RAW[@]} -eq 0 ] && { echo "  ✗ Nessun file .gguf trovato."; exit 1; }

    for i in "${!RAW[@]}"; do echo "  [$((i+1))] ${RAW[$i]}"; done
    read -rp "Modello [1-${#RAW[@]}]: " M_IDX
    MODEL_FILE="$MODELS_DIR/${RAW[$((M_IDX-1))]}"

    echo -e "\nEsecuzione benchmark CUDA..."
    CUDA_VISIBLE_DEVICES=0 "$BENCH_BIN" -m "$MODEL_FILE" -n 128 -p 512 -ngl 99
    ;;

  *)
    echo "Scelta non valida."
    ;;
esac
EOF
chmod +x "$HOME/bin/benchmark-llm.sh"

# 7d. dashboard.sh
cat << 'EOF' > "$HOME/bin/dashboard.sh"
#!/usr/bin/env bash
set -o pipefail
shopt -s nullglob

MODELS_DIR="${MODELS_DIR:-$HOME/models}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8080}"
CTX="${CTX:-16384}"
NGL="${NGL:-99}"
USER_AGENT="Mozilla/5.0"

die(){ echo "  ✗ $*" >&2; exit 1; }

MIXED_BIN="$HOME/src/llama.cpp/build-mixed/bin/llama-server"
CUDA_BIN="$HOME/src/llama.cpp/build-cuda/bin/llama-server"
VK_BIN="${VK_BIN:-$MIXED_BIN}"

BACK_OK=0; DEVICE_LIST=""
pick_bin() {
  local b="$1"
  [ -x "$b" ] || return 1
  DEVICE_LIST="$("$b" --list-devices 2>&1)"
  echo "$DEVICE_LIST" | grep -qiE "Vulkan" && VK_OK=1
  echo "$DEVICE_LIST" | grep -qiE "CUDA"   && CUDA_OK=1
}

echo "=============================================================="
echo "  dual-llm · Norad (Omarchy)"
echo "=============================================================="
echo "  backend / device (rilevati):"
for b in "$MIXED_BIN" "$VK_BIN"; do
  [ -x "$b" ] || continue
  echo "   ● $(basename "$b")"
  "$b" --list-devices 2>&1 | grep -E "^\s+(CUDA|Vulkan)" | sed 's/^/        /'
done

echo
echo "Configurazioni:"
echo "  [1] VULKAN-UNITED — entrambe le GPU via Vulkan (split strato, ~16 GiB VRAM)"
echo "  [2] CUDA+VULKAN   — RTX 3060 Ti (CUDA) + RX 5700 XT (Vulkan)  ± build misto"
CONFIG=0
while [ $CONFIG -eq 0 ]; do
  read -rp "Configurazione [1/2]: " c
  case "$c" in
    1)
      CONFIG=1
      SERVER_BIN="$VK_BIN"
      DEV_ARGS=( --split-mode layer )
      ;;
    2)
      [ -x "$MIXED_BIN" ] || die "build misto non pronto (build-mixed/bin/llama-server)"
      CONFIG=2
      SERVER_BIN="$MIXED_BIN"
      DEV_ARGS=( --split-mode layer --device cuda0 --device vulkan0 )
      ;;
    *) echo "      input non valido" ;;
  esac
done

echo
echo "Modelli GGUF in $MODELS_DIR:"
mapfile -t GGUFS < <(find "$MODELS_DIR" -maxdepth 1 -name "*.gguf" -printf "%f\n" | sort -u)
[ ${#GGUFS[@]} -eq 0 ] && die "nessun .gguf in $MODELS_DIR"
for i in "${!GGUFS[@]}"; do printf "  [%2d] %s\n" "$((i+1))" "${GGUFS[$i]}"; done

MIDX=0
while [ $MIDX -eq 0 ]; do
  read -rp "Modello [1-${#GGUFS[@]}]: " n
  if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#GGUFS[@]} )); then MIDX=$n; else echo "      input non valido"; fi
done
pick="${GGUFS[$((MIDX-1))]}"

MODEL_ARGS=()
if [[ "$pick" == *"-0000"*-of-* ]]; then
  base="${pick%-00001-of-*}"
  pattern="${MODELS_DIR}/${base}-*-of-*.gguf"
  mapfile -t SHARDS < <(find "$MODELS_DIR" -maxdepth 1 -name "$(basename "$pattern")" -printf "%f\n" | sort)
  [ ${#SHARDS[@]} -eq 0 ] && die "shard di '$base' non trovati"
  for s in "${SHARDS[@]}"; do MODEL_ARGS+=( -m "$MODELS_DIR/$s" ); done
else
  MODEL_ARGS+=( -m "$MODELS_DIR/$pick" )
fi

echo
echo "  avvio: $SERVER_BIN ${MODEL_ARGS[*]}"
echo "         --host $HOST --port $PORT --ctx-size $CTX --n-gpu-layers $NGL ${DEV_ARGS[*]}"
LOG=/tmp/dual-llm.srv
nohup "$SERVER_BIN" "${MODEL_ARGS[@]}" \
  --host "$HOST" --port "$PORT" \
  --ctx-size "$CTX" --n-gpu-layers "$NGL" \
  --batch-size 512 \
  "${DEV_ARGS[@]}" \
  --alias dual-gpu --metrics > /tmp/dual-llm.log 2>&1 &
SRV=$!
echo "  pid $SRV  (log: /tmp/dual-llm.log)"

echo "  caricamento modello… (può richiedere 1-2 min)"
ready=0
for _ in $(seq 1 240); do
  sleep 1
  if curl -s "http://$HOST:$PORT/health" 2>/dev/null | grep -qi "ok"; then ready=1; break; fi
  grep -qiE "error|failed to load" /tmp/dual-llm.log && break
done
if [ $ready -eq 1 ]; then
  echo
  echo "  ✅ pronto:  http://$HOST:$PORT/v1/chat/completions"
  echo "              (UI: http://$HOST:$PORT/ · stop: kill $SRV)"
else
  echo "  ✗ timeout — ultime righe log:"; tail -12 /tmp/dual-llm.log
fi
EOF
chmod +x "$HOME/bin/dashboard.sh"

# 7e. Aggiunta PATH ed Aliases a ~/.bashrc
if ! grep -q 'export PATH="$HOME/bin:$PATH"' "$HOME/.bashrc"; then
    echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"
fi

if ! grep -q 'vibe-coder()' "$HOME/.bashrc"; then
    cat << 'EOF' >> "$HOME/.bashrc"

# ==============================================================================
# AI Workstation Aliases & Functions
# ==============================================================================
vibe-coder() {
  local SERVER_URL="http://127.0.0.1:8080/health"
  local DUAL_LLM_SCRIPT="$HOME/bin/dual-llm.sh"

  # 1. Controllo se llama-server è già attivo sulla porta 8080
  if ! curl -s -o /dev/null "$SERVER_URL"; then
    echo -e "\n  ℹ llama-server non è attivo su port 8080. Avvio dual-llm.sh..."

    if [ -x "$DUAL_LLM_SCRIPT" ]; then
      "$DUAL_LLM_SCRIPT"

      # Verifica se l'avvio dello script ha avuto successo
      if ! curl -s -o /dev/null "$SERVER_URL"; then
        echo -e "  ✗ Impossibile avviare llama-server. Abortisco Aider."
        return 1
      fi
    else
      echo "  ✗ Script non trovato o non eseguibile in: $DUAL_LLM_SCRIPT"
      return 1
    fi
  else
    echo -e "  ✅ llama-server già attivo ed operativo su http://127.0.0.1:8080"
  fi

  # 2. Avvio di Aider in modalità Vibe Coding Autonoma
  echo -e "\n  🚀 Avvio Aider Vibe-Coder...\n"
  OPENAI_API_BASE="http://127.0.0.1:8080/v1" \
  OPENAI_API_KEY="dummy" \
  aider \
    --model openai/local-model \
    --auto-commits \
    --yes-always "$@" \
    --no-show-model-warnings \
    --message "Rispondi sempre e solo in lingua italiana."
}

vibe-reload() {
  echo "  🔄 Arresto llama-server e cambio modello..."
  pkill -f llama-server
  sleep 1
  vibe-coder "$@"
}
EOF
fi

echo -e "\n=============================================================="
echo "✅ Installazione e configurazione completate con successo!"
echo "=============================================================="
echo "Per rendere attive le modifiche al terminale corrente, esegui:"
echo "   source ~/.bashrc"
