#!/usr/bin/env bash

GATEWAY_URL="http://127.0.0.1:9000"
AMD_PID=2207
NVIDIA_PID=2499

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_live() {
    echo -e "   [$(date +%T)] $1"
}

clear
echo -e "${CYAN}========================================================${NC}"
echo -e "${CYAN}   DUAL GPU ROUTER - COLLAUDO LIVE CON LOG IN TEMPO REALE ${NC}"
echo -e "${CYAN}========================================================${NC}\n"

# 1. Test Routing Normale & Metriche
echo -e "${YELLOW}[*] Test 1: Verifica stato iniziale e metriche...${NC}"
log_live "Invio richiesta GET a ${GATEWAY_URL}/api/metrics..."
METRICS_RESP=$(curl -s "${GATEWAY_URL}/api/metrics")
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${GATEWAY_URL}/api/metrics")

log_live "Codice HTTP ricevuto: $HTTP_CODE"
log_live "Anteprima metriche nodi attivi:"
echo "$METRICS_RESP" | grep -E "status|vram_used_mb|active_model" | head -n 10 | sed 's/^/      /'

if [ "$HTTP_CODE" -eq 200 ]; then
    echo -e "${GREEN}[PASS] API Metrics risponde correttamente.${NC}\n"
    REPORT_NORMAL="SUCCESSO"
else
    echo -e "${RED}[FAIL] Gateway non raggiungibile (HTTP $HTTP_CODE).${NC}\n"
    REPORT_NORMAL="FALLITO"
fi

# 2. Test Rate Limiting (Flood test in parallelo con visualizzazione live)
echo -e "${YELLOW}[*] Test 2: Verifica Rate Limiting (Invio rapido di 65 richieste in parallelo)...${NC}"
TMP_DIR=$(mktemp -d)
log_live "Avvio invio massivo di 65 richieste concorrenti in background..."

for i in {1..65}; do
    (
      RESP=$(curl -s -w "\n%{http_code}" -X POST "${GATEWAY_URL}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d '{"messages": [{"role": "user", "content": "Test flood live"}]}')
      CODE=$(echo "$RESP" | tail -n1)
      echo "$CODE" > "$TMP_DIR/req_$i.txt"
    ) &
done
wait

SUCCESS_COUNT=0
LIMITED_COUNT=0
OTHER_COUNT=0

for i in {1..65}; do
    if [ -f "$TMP_DIR/req_$i.txt" ]; then
        CODE=$(cat "$TMP_DIR/req_$i.txt")
        if [ "$CODE" -eq 200 ]; then
            ((SUCCESS_COUNT++))
        elif [ "$CODE" -eq 429 ]; then
            ((LIMITED_COUNT++))
        else
            ((OTHER_COUNT++))
        fi
    fi
done
rm -rf "$TMP_DIR"

log_live "Risultati aggregati flood test:"
log_live " -> Richieste OK (200): $SUCCESS_COUNT"
log_live " -> Richieste Bloccate Rate Limit (429): $LIMITED_COUNT"
if [ "$OTHER_COUNT" -gt 0 ]; then
    log_live " -> Altri codici anomali: $OTHER_COUNT"
fi

if [ "$LIMITED_COUNT" -gt 0 ]; then
    echo -e "${GREEN}[PASS] Rate Limiting attivo e funzionante.${NC}\n"
    REPORT_RATELIMIT="SUCCESSO ($LIMITED_COUNT bloccate)"
else
    echo -e "${RED}[WARN] Nessun blocco 429 rilevato.${NC}\n"
    REPORT_RATELIMIT="FALLITO"
fi

# 3. Test Fallback AMD -> NVIDIA
echo -e "${YELLOW}[*] Test 3: Fallback AMD (Sospensione processo AMD PID ${AMD_PID} -> dirottamento su NVIDIA)...${NC}"
log_live "Invio segnale STOP al processo AMD (PID ${AMD_PID})..."
kill -STOP "$AMD_PID"
sleep 1

log_live "Invio richiesta di servizio (task_type: service) in corso..."
RESP_AMD_FILE=$(mktemp)
FB_AMD_CODE=$(curl -s -w "\n%{http_code}" -o "$RESP_AMD_FILE" -X POST "${GATEWAY_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"task_type": "service", "messages": [{"role": "user", "content": "Test fallback live AMD"}]}')

HTTP_STATUS_AMD=$(echo "$FB_AMD_CODE" | tail -n1)
log_live "Ripristino processo AMD (segnale CONT)..."
kill -CONT "$AMD_PID"

log_live "Codice HTTP risposta fallback AMD: $HTTP_STATUS_AMD"
log_live "Contenuto risposta ricevuta dal gateway:"
head -n 3 "$RESP_AMD_FILE" | sed 's/^/      /'
rm -f "$RESP_AMD_FILE"

if [ "$HTTP_STATUS_AMD" -eq 200 ]; then
    echo -e "${GREEN}[PASS] Fallback da AMD a NVIDIA riuscito.${NC}\n"
    REPORT_FB_AMD="SUCCESSO"
else
    echo -e "${RED}[FAIL] Fallback AMD fallito (HTTP $HTTP_STATUS_AMD).${NC}\n"
    REPORT_FB_AMD="FALLITO"
fi

log_live "Attesa scadenza cooldown Circuit Breaker (32s) per riallineamento stato nodi..."
sleep 32

# 4. Test Fallback NVIDIA -> AMD
echo -e "${YELLOW}[*] Test 4: Fallback NVIDIA (Sospensione processo NVIDIA PID ${NVIDIA_PID} -> dirottamento su AMD)...${NC}"
log_live "Invio segnale STOP al processo NVIDIA (PID ${NVIDIA_PID})..."
kill -STOP "$NVIDIA_PID"
sleep 1

log_live "Invio richiesta di coding (task_type: coding) in corso..."
RESP_NV_FILE=$(mktemp)
FB_NV_CODE=$(curl -s -w "\n%{http_code}" -o "$RESP_NV_FILE" -X POST "${GATEWAY_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"task_type": "coding", "messages": [{"role": "user", "content": "def test_live(): pass"}]}')

HTTP_STATUS_NV=$(echo "$FB_NV_CODE" | tail -n1)
log_live "Ripristino processo NVIDIA (segnale CONT)..."
kill -CONT "$NVIDIA_PID"

log_live "Codice HTTP risposta fallback NVIDIA: $HTTP_STATUS_NV"
log_live "Contenuto risposta ricevuta dal gateway:"
head -n 3 "$RESP_NV_FILE" | sed 's/^/      /'
rm -f "$RESP_NV_FILE"

if [ "$HTTP_STATUS_NV" -eq 200 ]; then
    echo -e "${GREEN}[PASS] Fallback da NVIDIA ad AMD riuscito.${NC}\n"
    REPORT_FB_NV="SUCCESSO"
else
    echo -e "${RED}[FAIL] Fallback NVIDIA fallito (HTTP $HTTP_STATUS_NV).${NC}\n"
    REPORT_FB_NV="FALLITO"
fi

# REPORT FINALE A VIDEO
echo -e "${CYAN}========================================================${NC}"
echo -e "${CYAN}                 REPORT FINALE DI COLLAUDO              ${NC}"
echo -e "${CYAN}========================================================${NC}"
printf "%-32s | %-20s\n" "TEST FUNZIONALE" "ESITO"
echo "--------------------------------------------------------"
printf "%-32s | %-20s\n" "Routing & API Metrics" "$REPORT_NORMAL"
printf "%-32s | %-20s\n" "Rate Limiting (Flood Protection)" "$REPORT_RATELIMIT"
printf "%-32s | %-20s\n" "Fallback AMD -> NVIDIA" "$REPORT_FB_AMD"
printf "%-32s | %-20s\n" "Fallback NVIDIA -> AMD" "$REPORT_FB_NV"
echo -e "${CYAN}========================================================${NC}"
