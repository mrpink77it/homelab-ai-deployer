#!/usr/bin/env bash
set -euo pipefail

API_URL="${1:-http://127.0.0.1:8080}"
API_KEY="${2:-}"

echo "--- Test velocità su: $API_URL ---"

if [ -n "$API_KEY" ] && [ "$API_KEY" != "EMPTY" ]; then
    models_json=$(curl -s -H "Authorization: Bearer $API_KEY" "$API_URL/v1/models" || echo "ERRORE")
else
    models_json=$(curl -s "$API_URL/v1/models" || echo "ERRORE")
fi

if [ "$models_json" = "ERRORE" ] || echo "$models_json" | jq -e '.error' >/dev/null 2>&1; then
    echo "Errore nel contattare $API_URL/v1/models"
    exit 1
fi

mapfile -t models < <(echo "$models_json" | jq -r '.data[].id')

if [ ${#models[@]} -eq 0 ]; then
    echo "Nessun modello disponibile trovato."
    exit 1
fi

echo ""
PS3="Seleziona il modello per il benchmark: "
select MODEL_NAME in "${models[@]}" "Annulla"; do
    if [ "$MODEL_NAME" = "Annulla" ] || [ -z "${MODEL_NAME:-}" ]; then
        echo "Operazione annullata."
        exit 0
    fi
    break
done

echo "Modello selezionato: $MODEL_NAME"
echo "Esecuzione benchmark in corso..."

start_time=$(python3 -c 'import time; print(time.time())')

if [ -n "$API_KEY" ] && [ "$API_KEY" != "EMPTY" ]; then
    response=$(curl -s -X POST "$API_URL/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $API_KEY" \
      -d "{
        \"model\": \"$MODEL_NAME\",
        \"messages\": [{\"role\": \"user\", \"content\": \"Spiega la fisica quantistica in modo dettagliato in circa 150 parole.\"}],
        \"temperature\": 0.7,
        \"max_tokens\": 200
      }")
else
    response=$(curl -s -X POST "$API_URL/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d "{
        \"model\": \"$MODEL_NAME\",
        \"messages\": [{\"role\": \"user\", \"content\": \"Spiega la fisica quantistica in modo dettagliato in circa 150 parole.\"}],
        \"temperature\": 0.7,
        \"max_tokens\": 200
      }")
fi

end_time=$(python3 -c 'import time; print(time.time())')

if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
    echo "Errore dal server:"
    echo "$response" | jq .
    exit 1
fi

elapsed=$(python3 -c "print(f'{$end_time - $start_time:.4f}')")
completion_tokens=$(echo "$response" | jq -r '.usage.completion_tokens // .timings.predicted_n // 0')
prompt_tokens=$(echo "$response" | jq -r '.usage.prompt_tokens // .timings.prompt_n // 0')

gen_tps=$(echo "$response" | jq -r '.timings.predicted_per_second // empty')
prompt_tps=$(echo "$response" | jq -r '.timings.prompt_per_second // empty')

echo ""
echo "--- RISULTATI BENCHMARK ---"
echo "Modello utilizzato: $MODEL_NAME"
echo "Prompt tokens: $prompt_tokens"
echo "Token generati: $completion_tokens"
echo "Tempo totale (End-to-End): ${elapsed}s"

if [ -n "$gen_tps" ] && [ "$gen_tps" != "null" ]; then
    echo "Prompt Processing (Nativo): ${prompt_tps} token/sec"
    echo "Generazione / Decoding (Nativo): ${gen_tps} token/sec"
elif [ "$completion_tokens" -gt 0 ]; then
    tps=$(python3 -c "print(f'{$completion_tokens / float($elapsed):.2f}')")
    echo "Velocità effettiva (End-to-End): $tps token/sec"
else
    echo "Risposta ricevuta:"
    echo "$response" | jq '.choices[0].message.content'
fi
