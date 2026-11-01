#!/usr/bin/env bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Errore: Esegui questo script con sudo per visualizzare i dettagli dei processi."
  exit 1
fi

if ! command -v whiptail &> /dev/null; then
    apt-get update && apt-get install -y whiptail
fi

ports_data=()
while read -r line; do
    proto=$(echo "$line" | awk '{print $1}')
    local_ip_port=$(echo "$line" | awk '{print $5}')
    port=$(echo "$local_ip_port" | awk -F':' '{print $NF}')
    
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 6000 ] && [ "$port" -le 10000 ]; then
        process_info=$(echo "$line" | grep -oP 'users:\(\(.*?\)\)' || echo "N/A")
        ports_data+=("$port" "$proto - $process_info")
    fi
done < <(ss -tulpn 2>/dev/null | tail -n +2)

if [ ${#ports_data[@]} -eq 0 ]; then
    whiptail --title "Port Inspector" --msgbox "Nessun servizio attivo trovato tra la porta 6000 e 10000." 10 50
    exit 0
fi

choice=$(whiptail --title "Servizi Attivi (Porte 6000-10000)" \
    --menu "Seleziona una porta per visualizzare i dettagli e gestire il servizio:" 22 78 12 \
    "${ports_data[@]}" 3>&1 1>&2 2>&3)

exitstatus=$?
if [ $exitstatus = 0 ]; then
    clear
    echo "================================================================="
    echo " DETTAGLI SERVIZIO SULLA PORTA: $choice"
    echo "================================================================="
    echo ""
    echo "[*] Informazioni di rete (ss):"
    ss -tulpn | grep -E ":$choice(\s|$)" || true
    echo ""
    echo "[*] Dettagli processo associato:"
    pid=$(ss -tulpn | grep -E ":$choice(\s|$)" | grep -oP 'pid=\K[0-9]+' | head -n 1)
    service_file=""
    service_name=""
    
    if [ -n "$pid" ]; then
        echo "PID: $pid"
        ps -fp "$pid" || true
        echo ""
        echo "Argomenti di esecuzione:"
        cmdline=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' || echo "")
        echo "$cmdline"
        echo ""
        
        echo "[*] Ricerca avanzata file di configurazione Systemd (Sistema e User)..."
        
        # 1. Tentativo systemd di sistema tramite PID
        service_file=$(systemctl show --property=FragmentPath --value --pid="$pid" 2>/dev/null || true)
        
        # 2. Se non trovato, cerchiamo nei file service di sistema e utente per porta o binario
        if [ -z "$service_file" ] || [ "$service_file" = "" ]; then
            bin_name=$(basename "$(echo "$cmdline" | awk '{print $1}')")
            matched_files=$(grep -rlE "($choice|$bin_name)" /etc/systemd/system/ /lib/systemd/system/ /home/*/.config/systemd/user/ /root/.config/systemd/user/ 2>/dev/null || true)
            if [ -n "$matched_files" ]; then
                service_file=$(echo "$matched_files" | head -n 1)
            fi
        fi

        if [ -n "$service_file" ] && [ -f "$service_file" ]; then
            echo "Percorso Systemd Trovato: $service_file"
            echo "-----------------------------------------------------------------"
            cat "$service_file"
            echo "-----------------------------------------------------------------"
            service_name=$(basename "$service_file")
        else
            echo "Nessun file systemd trovato che referenzi la porta $choice o il processo."
        fi
    else
        echo "Nessun PID associato rilevato."
    fi
    echo "================================================================="
    
    # Pausa introdotta subito dopo la visualizzazione del file systemd
    echo ""
    read -p "Premi INVIO per procedere alla gestione dell'arresto..."
    
    # Funzione di arresto interattiva
    if [ -n "$pid" ]; then
        echo ""
        if (whiptail --title "Arresto Servizio" --yesno "Vuoi fermare il servizio sulla porta $choice (PID: $pid)?\nVerrà eseguito systemctl stop o terminato il processo." 10 65); then
            echo "[*] Tentativo di arresto in corso..."
            
            # Arresto tramite systemd se disponibile
            if [ -n "$service_name" ]; then
                echo "Esecuzione di systemctl stop $service_name..."
                systemctl stop "$service_name" || true
            fi
            
            # Controllo e kill forzato del PID se ancora attivo
            if kill -0 "$pid" 2>/dev/null; then
                echo "Il processo è ancora attivo. Invio segnale di terminazione al PID $pid..."
                kill -15 "$pid" 2>/dev/null || true
                sleep 1
                if kill -0 "$pid" 2>/dev/null; then
                    kill -9 "$pid" 2>/dev/null || true
                fi
            fi
            echo "[OK] Operazione di arresto completata."
        else
            echo "[*] Arresto annullato dall'utente."
        fi
    fi
    
    echo ""
    read -p "Premi INVIO per chiudere..."
fi
