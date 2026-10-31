#!/bin/bash
# port_inspector.sh - Ispeziona porte, visualizza file/giornali e gestisce/ferma/disabilita i servizi systemd.

# Assicuriamoci di essere root
if [ "$EUID" -ne 0 ]; then
  echo "Per favore, esegui questo script come root (sudo)."
  exit 1
fi

BACKTITLE="Homelab AI - Port & Service Inspector"

# Funzione menu principale
main_menu() {
    CHOICE=$(whiptail --title "Port & Service Inspector" --backtitle "$BACKTITLE" --menu \
        "Scegli un'operazione di gestione servizi:" 18 70 4 \
        "1" "📊 Visualizza Servizi, File e Giornale (Log)" \
        "2" "🛑 Ferma Servizi (Selezione Multipla)" \
        "3" "🚫 Disabilita Servizi dall'Avvio (Selezione Multipla)" \
        "4" "🚪 Esci" 3>&1 1>&2 2>&3)
    
    case $CHOICE in
        1) view_services_menu ;;
        2) stop_services_menu ;;
        3) disable_services_menu ;;
        4) clear; exit 0 ;;
        *) clear; exit 0 ;;
    esac
}

# 1. Visualizza servizi, file e giornale
view_services_menu() {
    local services=()
    while read -r srv; do
        services+=("$srv" "Attivo")
    done < <(systemctl list-units --type=service --state=running --no-legend | awk '{print $1}' | sed 's/\.service//')

    if [ ${#services[@]} -eq 0 ]; then
        whiptail --title "Errore" --msgbox "Nessun servizio in esecuzione trovato." 10 50
        main_menu
        return
    fi

    SELECTED_SRV=$(whiptail --title "Seleziona Servizio" --backtitle "$BACKTITLE" --menu \
        "Selezionare un servizio da ispezionare:" 20 70 10 \
        "${services[@]}" 3>&1 1>&2 2>&3)

    [ -z "$SELECTED_SRV" ] && { main_menu; return; }

    ACTION=$(whiptail --title "Azione per $SELECTED_SRV" --backtitle "$BACKTITLE" --menu \
        "Cosa vuoi visualizzare per '$SELECTED_SRV'?" 15 60 3 \
        "1" "📄 Mostra file di configurazione (systemctl cat)" \
        "2" "📜 Mostra giornale / log recenti (journalctl)" \
        "3" "🔙 Torna al menu principale" 3>&1 1>&2 2>&3)

    case $ACTION in
        1)
            clear
            echo "=== File di configurazione per $SELECTED_SRV ==="
            systemctl cat "$SELECTED_SRV"
            echo -e "\n--------------------------------------------------"
            read -p "Premi INVIO per continuare..."
            ;;
        2)
            clear
            echo "=== Ultimi log (giornale) per $SELECTED_SRV ==="
            journalctl -u "$SELECTED_SRV" -n 50 --no-pager
            echo -e "\n--------------------------------------------------"
            read -p "Premi INVIO per continuare..."
            ;;
    esac
    main_menu
}

# 2. Ferma servizi (selezione multipla)
stop_services_menu() {
    local services=()
    while read -r srv; do
        services+=("$srv" "Running" OFF)
    done < <(systemctl list-units --type=service --state=running --no-legend | awk '{print $1}' | sed 's/\.service//')

    if [ ${#services[@]} -eq 0 ]; then
        whiptail --title "Informazione" --msgbox "Nessun servizio attivo da fermare." 10 50
        main_menu
        return
    }

    CHOICES=$(whiptail --title "Ferma Servizi" --backtitle "$BACKTITLE" --checklist \
        "Seleziona i servizi da FERMARE (Usa SPAZIO per selezionare, INVIO per confermare):" 20 75 10 \
        "${services[@]}" 3>&1 1>&2 2>&3)

    [ -z "$CHOICES" ] && { main_menu; return; }

    # Rimuove le virgolette superflue restituite dalla checklist
    CHOICES=$(echo "$CHOICES" | tr -d '"')

    clear
    echo "Arresto dei servizi selezionati in corso..."
    for srv in $CHOICES; do
        echo "Fermo $srv..."
        systemctl stop "$srv.service"
    done
    echo -e "\nOperazione completata con successo."
    read -p "Premi INVIO per tornare al menu..."
    main_menu
}

# 3. Disabilita servizi di avvio (selezione multipla)
disable_services_menu() {
    local services=()
    while read -r srv; do
        services+=("$srv" "Enabled" OFF)
    done < <(systemctl list-unit-files --type=service --state=enabled --no-legend | awk '{print $1}' | sed 's/\.service//')

    if [ ${#services[@]} -eq 0 ]; then
        whiptail --title "Informazione" --msgbox "Nessun servizio abilitato al boot trovato." 10 50
        main_menu
        return
    }

    CHOICES=$(whiptail --title "Disabilita Servizi all'Avvio" --backtitle "$BACKTITLE" --checklist \
        "Seleziona i servizi da DISABILITARE all'avvio (Usa SPAZIO per selezionare, INVIO per confermare):" 20 75 10 \
        "${services[@]}" 3>&1 1>&2 2>&3)

    [ -z "$CHOICES" ] && { main_menu; return; }

    CHOICES=$(echo "$CHOICES" | tr -d '"')

    clear
    echo "Disabilitazione dei servizi dall'avvio in corso..."
    for srv in $CHOICES; do
        echo "Disabilito $srv..."
        systemctl disable "$srv.service"
    done
    echo -e "\nOperazione completata con successo."
    read -p "Premi INVIO per tornare al menu..."
    main_menu
}

# Avvio del loop del menu principale
while true; do
    main_menu
done
