#!/bin/bash

# Configurazione porte e modello
PORTS=(8080 8200 8082)
MODEL="Mistral-7B-Instruct-v0.3-Q6_K.gguf"
HOST="127.0.0.1"

echo "=============================================================="
echo "  TEST  LLAMA "
echo "  Modello target: $MODEL"
echo "=============================================================="

# --- Rilevamento Hardware Globale ---
echo "[*] ANALISI HARDWARE DI SISTEMA:"
echo "    - CPU Cores    : $(nproc) thread disponibili"
echo "    - RAM di Sistema: $(free -h | awk '/Mem:/ {print $3 " usati / " $2 " totali"}')"
if command -v nvidia-smi &> /dev/null; then
    GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits | head -n 1)
    echo "    - GPU NVIDIA   : $GPU_INFO"
fi
echo "=============================================================="

for PORT in "${PORTS[@]}"; do
    echo -e "\n--------------------------------------------------------------"
    echo ">>> Analisi Motore su porta $PORT"
    echo "--------------------------------------------------------------"

    # 1. Verifica raggiungibilità endpoint health
    if ! curl -s -o /dev/null --max-time 3 "http://$HOST:$PORT/health"; then
        echo "  [✗] Server non raggiungibile su http://$HOST:$PORT"
        continue
    fi
    echo "  [✓] Server attivo e raggiungibile."

    # 2. Rilevamento Hardware, PID e Librerie dal processo attivo
    PID=$(pgrep -f "port $PORT" | head -n 1)
    if [ -n "$PID" ]; then
        CMDLINE=$(cat /proc/$PID/cmdline | tr '\0' ' ')
        BIN_PATH=$(echo $CMDLINE | awk '{print $1}')
        
        echo "  [i] Processo PID     : $PID"
        echo "  [i] Binario eseguibile: $BIN_PATH"
        
        # Identificazione precisa del backend hardware
        if [[ "$BIN_PATH" == *"cuda"* ]] || [[ "$CMDLINE" == *"-ngl 99"* ]] || [[ "$CMDLINE" == *"-ngl"* && "$CMDLINE" != *"-ngl 0"* ]]; then
            NGL=$(echo "$CMDLINE" | grep -oP '\-ngl\s+\K\d+' || echo "99")
            echo "  [Hardware / Backend] : GPU NVIDIA accelerata (CUDA) [Layer Offload: $NGL]"
        elif [[ "$CMDLINE" == *"-ngl 0"* ]]; then
            THREADS=$(echo "$CMDLINE" | grep -oP '\-t\s+\K\d+' || echo "Auto")
            echo "  [Hardware / Backend] : CPU Pura [Offload disabilitato: -ngl 0, Thread: $THREADS]"
        else
            echo "  [Hardware / Backend] : Configurazione Standard / Ibrida"
        fi
        
        # Rilevamento ottimizzazione cache KV
        if [[ "$CMDLINE" == *"--cache-type-k"* ]]; then
            CACHE_K=$(echo "$CMDLINE" | grep -oP '\-\-cache-type-k\s+\K\S+' || echo "q4_0")
            CACHE_V=$(echo "$CMDLINE" | grep -oP '\-\-cache-type-v\s+\K\S+' || echo "q4_0")
            echo "  [Cache KV Memoria]   : Ottimizzata (K=$CACHE_K, V=$CACHE_V)"
        fi
    fi

    # 3. Invio richiesta di test OpenAI specificando il modello corretto
    echo "  [*] Invio richiesta di benchmark (256 token) con $MODEL..."

    PAYLOAD=$(cat <<JSON_EOF
{
  "model": "$MODEL",
  "messages": [
    {"role": "user", "content": "Write a 300-word essay explaining quantum computing to a high school student."}
  ],
  "max_tokens": 256,
  "temperature": 0.2
}
JSON_EOF
)

    RESPONSE=$(curl -s -X POST "http://$HOST:$PORT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD")

    # 4. Parsing della risposta con Python
    echo "$RESPONSE" | python3 - << 'EOF_PY'
import json, sys

raw = sys.stdin.read()
if not raw.strip():
    print("  [✗] Errore: Risposta vuota dal server (il modello potrebbe essere in fase di caricamento dal disco).")
    sys.exit(0)

try:
    data = json.loads(raw)
except Exception as e:
    print(f"  [✗] Errore nel parsing JSON: {e}")
    print(f"      Risposta grezza: {raw[:300]}")
    sys.exit(0)

if "error" in data:
    err = data["error"]
    msg = err.get("message", err) if isinstance(err, dict) else err
    print(f"  [✗] Errore API: {msg}")
    sys.exit(0)

usage = data.get("usage", {})
pt = usage.get("prompt_tokens", 0)
ct = usage.get("completion_tokens", 0)

timings = data.get("timings", {})
pp_ms = timings.get("prompt_ms", 0)
tg_ms = timings.get("predicted_ms", 0)

pp_tps = (pt / (pp_ms / 1000.0)) if pp_ms > 0 else 0
tg_tps = (ct / (tg_ms / 1000.0)) if tg_ms > 0 else 0

print("  [✓] Test di generazione completato con successo:")
print(f"      - Prompt Processing (PP)    : {pt} tokens in {pp_ms:.2f} ms ({pp_tps:.2f} t/s)")
print(f"      - Text Generation (TG)      : {ct} tokens in {tg_ms:.2f} ms ({tg_tps:.2f} t/s)")
print(f"      - Time to First Token       : {pp_ms:.2f} ms")
EOF_PY

done

echo -e "\n=============================================================="
echo "  FINE TEST SUITE"
echo "=============================================================="
