#!/bin/bash

# v1.2.0 - Cluster Test
PORTS=(8080 8200 8082)
BACKENDS=("AMD Radeon RX 5700 XT (Vulkan)" "NVIDIA RTX 3060 Ti (CUDA)" "Intel i7-13700F (CPU Pura)")
MODEL="Llama-3.2-3B-Instruct-Q4_K_M.gguf"
HOST="127.0.0.1"

echo "v1.2.0 | Target Model: $MODEL"
echo "=============================================================="

for i in "${!PORTS[@]}"; do
    PORT="${PORTS[$i]}"
    BACKEND_DESC="${BACKENDS[$i]}"
    
    echo -e "\n--------------------------------------------------------------"
    echo ">>> Porta $PORT [$BACKEND_DESC]"
    echo "--------------------------------------------------------------"

    if ! curl -s -o /dev/null --max-time 3 "http://$HOST:$PORT/health"; then
        echo "  [✗] Server non raggiungibile su http://$HOST:$PORT"
        continue
    fi
    echo "  [✓] Server attivo e raggiungibile."

    # Rilevamento hardware preciso basato sul binario/servizio
    PID=$(pgrep -f "port $PORT" | head -n 1)
    if [ -n "$PID" ]; then
        CMDLINE=$(cat /proc/$PID/cmdline | tr '\0' ' ')
        if [[ "$CMDLINE" == *"vulkan"* ]] || [[ "$CMDLINE" == *GGML_VK* ]]; then
            echo "  [Hardware] : AMD Radeon RX 5700 XT (Vulkan)"
        elif [[ "$CMDLINE" == *"cuda"* ]] || [[ "$CMDLINE" == *CUDA_VISIBLE* ]]; then
            echo "  [Hardware] : NVIDIA RTX 3060 Ti (CUDA)"
        else
            echo "  [Hardware] : Intel i7-13700F (CPU Pura)"
        fi
    fi

    PAYLOAD=$(cat <<JSON_EOF
{
  "model": "$MODEL",
  "messages": [
    {"role": "user", "content": "Write a short test sentence."}
  ],
  "max_tokens": 64,
  "temperature": 0.2
}
JSON_EOF
)

    # Catturiamo codice HTTP e risposta grezza per mostrarla a video in caso di errore
    TEMP_FILE=$(mktemp)
    HTTP_CODE=$(curl -s -w "%{http_code}" -o "$TEMP_FILE" -X POST "http://$HOST:$PORT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        --max-time 60)
    
    RAW_RESPONSE=$(cat "$TEMP_FILE")
    rm -f "$TEMP_FILE"

    if [ "$HTTP_CODE" -ne 200 ] || [ -z "$RAW_RESPONSE" ]; then
        echo "  [✗] Errore HTTP Server (Codice: $HTTP_CODE)"
        echo "      LOG RISPOSTA GREZZA:"
        echo "      --------------------------------------------------"
        echo "      $RAW_RESPONSE"
        echo "      --------------------------------------------------"
        continue
    fi

    # Parsing JSON della risposta corretta
    echo "$RAW_RESPONSE" | python3 - << 'EOF_PY'
import json, sys

try:
    data = json.load(sys.stdin)
except Exception as e:
    print(f"  [✗] Errore parsing JSON: {e}")
    sys.exit(0)

if "error" in data:
    print(f"  [✗] Errore API: {data['error']}")
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
print(f"      - Prompt Processing (PP) : {pt} tokens in {pp_ms:.2f} ms ({pp_tps:.2f} t/s)")
print(f"      - Text Generation (TG)   : {ct} tokens in {tg_ms:.2f} ms ({tg_tps:.2f} t/s)")
EOF_PY

done

echo -e "\n=============================================================="
