#!/bin/bash

# Configurazione porte dei motori llama-server attivi
PORTS=(8080 8200 8082)
HOST="127.0.0.1"

echo "=============================================================="
echo "  TEST SUITE MOTORI LLAMA (OpenAI Compatible API - Robusta)"
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

    # 2. Rilevamento dinamico del modello caricato sul server specifico
    MODEL_NAME=$(curl -s "http://$HOST:$PORT/v1/models" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    models = data.get('data', [])
    if models:
        print(models[0].get('id', 'default-model'))
    else:
        print('default-model')
except:
    print('default-model')
")
    echo "  [i] Modello attivo rilevato sul server: $MODEL_NAME"

    # 3. Rilevamento Hardware e PID del processo attivo
    PID=$(pgrep -f "port $PORT" | head -n 1)
    if [ -n "$PID" ]; then
        CMDLINE=$(cat /proc/$PID/cmdline | tr '\0' ' ')
        echo "  [i] Processo PID : $PID"
        echo "  [i] Binario      : $(echo $CMDLINE | awk '{print $1}')"
        
        if [[ "$CMDLINE" == *"/opt/llama-cpp-cuda"* ]] || [[ "$CMDLINE" == *"-ngl 99"* ]]; then
            echo "  [Hardware]       : GPU NVIDIA accelerata (CUDA)"
        elif [[ "$CMDLINE" == *"-ngl 0"* ]]; then
            echo "  [Hardware]       : CPU Pura (Offload disabilitato, -ngl 0)"
        else
            echo "  [Hardware]       : Configurazione Ibrida / Standard"
        fi
    fi

    # 4. Invio richiesta di test tramite OpenAI API (/v1/chat/completions)
    echo "  [*] Invio richiesta di benchmark (256 token)..."

    PAYLOAD=$(cat <<JSON_EOF
{
  "model": "$MODEL_NAME",
  "messages": [
    {"role": "user", "content": "Write a 300-word essay explaining quantum computing to a high school student."}
  ],
  "max_tokens": 256,
  "temperature": 0.2
}
JSON_EOF
)

    # Esegue la chiamata e cattura l'output grezzo per validarlo
    RESPONSE=$(curl -s -X POST "http://$HOST:$PORT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD")

    # Parsing sicuro in Python con controllo risposte vuote o errori
    echo "$RESPONSE" | python3 - << 'EOF_PY'
import json, sys

raw_input_data = sys.stdin.read()
if not raw_input_data.strip():
    print("  [✗] Errore: Risposta vuota ricevuta dal server (timeout o errore interno).")
    sys.exit(0)

try:
    data = json.loads(raw_input_data)
except Exception as e:
    print(f"  [✗] Errore nel parsing della risposta JSON: {e}")
    print(f"      Risposta ricevuta: {raw_input_data[:300]}")
    sys.exit(0)

if "error" in data:
    err_msg = data["error"].get("message", data["error"])
    print(f"  [✗] Errore API: {err_msg}")
    sys.exit(0)

usage = data.get("usage", {})
prompt_tokens = usage.get("prompt_tokens", 0)
completion_tokens = usage.get("completion_tokens", 0)

timings = data.get("timings", {})
pp_ms = timings.get("prompt_ms", 0)
tg_ms = timings.get("predicted_ms", 0)

pp_tps = (prompt_tokens / (pp_ms / 1000.0)) if pp_ms > 0 else 0
tg_tps = (completion_tokens / (tg_ms / 1000.0)) if tg_ms > 0 else 0

print("  [✓] Test API completato con successo:")
print(f"      - Prompt Processing (PP)    : {prompt_tokens} tokens in {pp_ms:.2f} ms ({pp_tps:.2f} t/s)")
print(f"      - Text Generation (TG)      : {completion_tokens} tokens in {tg_ms:.2f} ms ({tg_tps:.2f} t/s)")
print(f"      - Time to First Token       : {pp_ms:.2f} ms")
EOF_PY

done

echo -e "\n=============================================================="
echo "  FINE TEST SUITE"
echo "=============================================================="
