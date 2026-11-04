#!/bin/bash

PORTS=(8080 8200 8082)
MODEL="Mistral-7B-Instruct-v0.3-Q6_K.gguf"
HOST="127.0.0.1"

echo "=============================================================="
echo "  TEST SUITE MOTORI LLAMA (Hardware, Memoria & Benchmark)"
echo "  Modello target: $MODEL"
echo "=============================================================="

# Rilevamento Hardware Dettagliato di Sistema
echo "[*] HARDWARE DI SISTEMA:"
echo "    - CPU Model    : $(lscpu | grep 'Model name' | awk -F ':' '{print $2}' | xargs)"
echo "    - RAM Totale   : $(free -h | awk '/Mem:/ {print $2}') (Usata: $(free -h | awk '/Mem:/ {print $3}'))"
if command -v nvidia-smi &> /dev/null; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1)
    GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader | head -n 1)
    echo "    - GPU NVIDIA   : $GPU_NAME ($GPU_VRAM VRAM)"
fi
echo "=============================================================="

for PORT in "${PORTS[@]}"; do
    echo -e "\n--------------------------------------------------------------"
    echo ">>> Analisi Motore su porta $PORT"
    echo "--------------------------------------------------------------"

    if ! curl -s -o /dev/null --max-time 3 "http://$HOST:$PORT/health"; then
        echo "  [✗] Server non raggiungibile su http://$HOST:$PORT"
        continue
    fi
    echo "  [✓] Server attivo e raggiungibile."

    PID=$(pgrep -f "port $PORT" | head -n 1)
    if [ -n "$PID" ]; then
        CMDLINE=$(cat /proc/$PID/cmdline | tr '\0' ' ')
        BIN_PATH=$(echo $CMDLINE | awk '{print $1}')
        echo "  [i] PID Processo     : $PID"
        echo "  [i] Binario          : $BIN_PATH"
        
        if [[ "$BIN_PATH" == *"cuda"* ]] || [[ "$CMDLINE" == *"-ngl"* && "$CMDLINE" != *"-ngl 0"* ]]; then
            NGL=$(echo "$CMDLINE" | grep -oP '\-ngl\s+\K\d+' || echo "99")
            echo "  [Hardware / Backend] : GPU NVIDIA CUDA (Offload: $NGL layer)"
        elif [[ "$CMDLINE" == *"-ngl 0"* ]]; then
            THREADS=$(echo "$CMDLINE" | grep -oP '\-t\s+\K\d+' || echo "Auto")
            echo "  [Hardware / Backend] : CPU Pura (-ngl 0, Thread: $THREADS)"
        else
            echo "  [Hardware / Backend] : Configurazione Standard / Vulkan"
        fi
        
        if [[ "$CMDLINE" == *"--cache-type-k"* ]]; then
            echo "  [KV Cache Memoria]   : Quantizzata (Ottimizzata)"
        fi
    fi

    echo "  [*] Invio richiesta di benchmark (256 token)..."
    echo "      (Nota: se il modello non è in RAM, il primo avvio richiederà 10-30s per il caricamento da disco)"

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

    # Timeout esteso a 120 secondi per consentire il caricamento a freddo del GGUF
    RESPONSE=$(curl -s -X POST "http://$HOST:$PORT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        --max-time 120)

    echo "$RESPONSE" | python3 - << 'EOF_PY'
import json, sys

raw = sys.stdin.read()
if not raw.strip():
    print("  [✗] Errore: Timeout o risposta vuota dal server.")
    sys.exit(0)

try:
    data = json.loads(raw)
except Exception as e:
    print(f"  [✗] Errore nel parsing JSON: {e}")
    print(f"      Risposta ricevuta: {raw[:300]}")
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

print("  [✓] Test completato con successo:")
print(f"      - Prompt Processing (PP)    : {pt} tokens in {pp_ms:.2f} ms ({pp_tps:.2f} t/s)")
print(f"      - Text Generation (TG)      : {ct} tokens in {tg_ms:.2f} ms ({tg_tps:.2f} t/s)")
print(f"      - Time to First Token       : {pp_ms:.2f} ms")
EOF_PY

done

echo -e "\n=============================================================="
echo "  FINE TEST SUITE"
echo "=============================================================="
