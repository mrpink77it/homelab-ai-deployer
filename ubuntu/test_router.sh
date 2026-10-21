#!/usr/bin/env bash

# Colori ANSI per la TUI
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

GATEWAY_URL="http://127.0.0.1:9000"

show_menu() {
    clear
    echo -e "${CYAN}========================================================${NC}"
    echo -e "${CYAN}          LLM GATEWAY - INTERACTIVE TUI TESTER         ${NC}"
    echo -e "${CYAN}========================================================${NC}"
    echo -e " ${GREEN}1)${NC} Verifica Stato Gateway & Nodi (${CYAN}/status${NC})"
    echo -e " ${GREEN}2)${NC} Test Chat Servizio (AMD Vulkan / Porta 8080)"
    echo -e " ${GREEN}3)${NC} Test Auto-Routing Coding (NVIDIA CUDA / Porta 8888)"
    echo -e " ${GREEN}4)${NC} Invia Prompt Personalizzato (Custom Chat)"
    echo -e " ${GREEN}5)${NC} Visualizza Stato Servizio Systemd"
    echo -e " ${GREEN}6)${NC} Visualizza Log in Tempo Reale (journalctl)"
    echo -e " ${RED}7)${NC} Esci"
    echo -e "${CYAN}========================================================${NC}"
}

while true; do
    show_menu
    read -p "Seleziona un'opzione [1-7]: " choice
    case $choice in
        1)
            echo -e "\n${YELLOW}[*] Interrogazione stato gateway...${NC}"
            if command -v json_pp &> /dev/null; then
                curl -s "${GATEWAY_URL}/status" | json_pp
            else
                curl -s "${GATEWAY_URL}/status"
            fi
            echo -e "\n"
            read -p "Premi INVIO per continuare..."
            ;;
        2)
            echo -e "\n${YELLOW}[*] Invio test di servizio (AMD Vulkan)...${NC}"
            curl -s -X POST "${GATEWAY_URL}/v1/chat/completions" \
              -H "Content-Type: application/json" \
              -d '{
                "task_type": "service",
                "messages": [{"role": "user", "content": "Ciao! Dimmi in due righe chi sei e quale hardware gestisci."}]
              }'
            echo -e "\n"
            read -p "Premi INVIO per continuare..."
            ;;
        3)
            echo -e "\n${YELLOW}[*] Invio test auto-routing coding (NVIDIA CUDA)...${NC}"
            curl -s -X POST "${GATEWAY_URL}/v1/chat/completions" \
              -H "Content-Type: application/json" \
              -d '{
                "messages": [{"role": "user", "content": "Scrivi una funzione Python ottimizzata per il calcolo della sequenza di Fibonacci."}]
              }'
            echo -e "\n"
            read -p "Premi INVIO per continuare..."
            ;;
        4)
            echo -e "\n"
            read -p "Inserisci il tuo prompt: " user_prompt
            read -p "Specifica task_type (lascia vuoto per auto, oppure digita 'service' o 'coding'): " task_type
            
            payload="{\"messages\": [{\"role\": \"user\", \"content\": \"$user_prompt\"}]"
            if [ -n "$task_type" ]; then
                payload="${payload}, \"task_type\": \"$task_type\""
            fi
            payload="${payload}}"

            echo -e "\n${YELLOW}[*] Invio richiesta al gateway...${NC}"
            curl -s -X POST "${GATEWAY_URL}/v1/chat/completions" \
              -H "Content-Type: application/json" \
              -d "$payload"
            echo -e "\n"
            read -p "Premi INVIO per continuare..."
            ;;
        5)
            echo -e "\n${YELLOW}[*] Stato del servizio systemd llm-gateway...${NC}"
            sudo systemctl status llm-gateway --no-pager
            echo -e "\n"
            read -p "Premi INVIO per continuare..."
            ;;
        6)
            echo -e "\n${YELLOW}[*] Apertura log in tempo reale (Premi Ctrl+C per uscire)...${NC}"
            sudo journalctl -u llm-gateway -f
            ;;
        7)
            echo -e "\n${GREEN}Uscita in corso... A presto!${NC}"
            exit 0
            ;;
        *)
            echo -e "\n${RED}Opzione non valida! Seleziona un numero da 1 a 7.${NC}"
            sleep 1
            ;;
    esac
done
