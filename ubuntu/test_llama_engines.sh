#!/bin/bash

# Configurazione porte e modello
PORTS=(8080 8200 8082)
MODEL="Mistral-7B-Instruct-v0.3-Q6_K.gguf"
HOST="127.0.0.1"

echo "=============================================================="
echo "  TEST SUITE MOTORI LLAMA (OpenAI Compatible API)"
echo "  Modello target: $MODEL"
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

    # 2. Rilevamento Hardware e Librerie tramite il processo attivo
    PID=$(pgrep -f "port $PORT" | head -n 1)
    if [ -n "$PID" ]; then
        CMDLINE=$(cat /proc/$PID/cmdline | tr '\0' ' ')
        echo "  [i] Processo PID : $PID"
        echo "  [i] Binario      : $(echo $CMDLINE | awk '{print $1}')"
        
        # Identificazione backend dal percorso o dai parametri
        if [[ "$CMDLINE" == *"/opt/llama-cpp-cuda"* ]] || [[ "$CMDLINE" == *"-ngl 99"* ]]; then
            echo "  [Hardware]       : GPU NVIDIA accelerata (CUDA / -ngl attivo)"
        elif [[ "$CMDLINE" == *"-ngl 0"* ]]; then
            echo "  [Hardware]       : CPU Pura (Offload disabilitato, -ngl 0, Thread dedicati)"
        else
            echo "  [Hardware]       : Configurazione Ibrida / Standard"
        fi
        
        # Mostra parametri chiave della cache KV se presenti
        if [[ "$CMDLINE" == *"--cache-type-k"* ]]; then
            echo "  [Cache Quant]    : KV Cache ottimizzata (es. q4_0)"
        fi
    fi

    # 3. Invio richiesta di test tramite OpenAI API (/v1/chat/completions)
    echo "  [*] Invio richiesta di benchmark (256 token)..."

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

    # Esegue la chiamata misurando il tempo totale con curl e inviando l'output in pipe a Python
    curl -s -X POST "http://$HOST:$PORT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" | python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
    
    # Controllo errori restituiti dall API
    if "error" in data:
        print(f"  [✗] Errore API: {data[\"error\"].get(\"message\", data[\"error\"])}")
        sys.exit(0)

    usage = data.get("usage", {})
    prompt_tokens = usage.get("prompt_tokens", 0)
    completion_tokens = usage.get("completion_tokens", 0)
    total_tokens = usage.get("total_tokens", 0)
    
    # Estrazione dei timings nativi restituiti da llama-server nellestensione OpenAI
    timings = data.get("timings", {})
    pp_ms = timings.get("prompt_ms", 0)
    tg_ms = timings.get("predicted_ms", 0)
    
    pp_tps = (prompt_tokens / (pp_ms / 1000.0)) if pp_ms > 0 else 0
    tg_tps = (completion_tokens / (tg_ms / 1000.0)) if tg_ms > 0 else 0
    
    print("  [✓] Test API completato con successo:")
    print(f"      - Prompt Processing (PP)    : {prompt_tokens} tokens in {pp_ms:.2f} ms ({pp_tps:.2f} t/s)")
    print(f"      - Text Generation (TG)      : {completion_tokens} tokens in {tg_ms:.2f} ms ({tg_tps:.2f} t/s)")
    print(f"      - Time to First Token       : {pp_ms:.2f} ms")
except Exception as e:
    print(f"  [✗] Errore nel parsing della risposta JSON: {e}")
'
done

echo -e "\n=============================================================="
echo "  FINE TEST SUITE"
echo "=============================================================="
