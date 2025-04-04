#!/bin/bash
# Ubuntu Full Disk Encryption - Automatisches Installationsskript
# Dieses Skript automatisiert die Installation von Ubuntu mit vollständiger Festplattenverschlüsselung
# Version: 0.1
# Datum: $(date +%Y-%m-%d)
# Autor: Smali Tobules mit Hilfe von Claude.ai

###################
# Konfiguration   #
###################
SCRIPT_VERSION="0.1"
DEFAULT_HOSTNAME="ubuntu-server"
DEFAULT_USERNAME="admin"
DEFAULT_ROOT_SIZE="100"
DEFAULT_DATA_SIZE="0"  # 0 bedeutet restlicher Platz
DEFAULT_SSH_PORT="22"
CONFIG_FILE="ubuntu-fde.conf"
LOG_FILE="ubuntu-fde.log"
LUKS_BOOT_NAME="BOOT"
LUKS_ROOT_NAME="ROOT"

###################
# Farben und Log  #
###################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logdatei einrichten im aktuellen Verzeichnis
LOG_FILE="$(pwd)/UbuntuFDE_$(date +%Y%m%d_%H%M%S).log"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

# Alle Ausgaben in die Logdatei umleiten und gleichzeitig im Terminal anzeigen
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Installation startet am $(date) ===" | tee -a "$LOG_FILE"
echo "=== Alle Ausgaben werden in $LOG_FILE protokolliert ===" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Hilfsfunktionen für Logging
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARNUNG]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[FEHLER]${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

log_progress() {
    echo -e "${BLUE}[FORTSCHRITT]${NC} $1" | tee -a "$LOG_FILE"
}

# Fortschrittsbalken
show_progress() {
    local percent=$1
    local width=50
    local num_bars=$((percent * width / 100))
    local progress="["
    
    for ((i=0; i<num_bars; i++)); do
        progress+="█"
    done
    
    for ((i=num_bars; i<width; i++)); do
        progress+=" "
    done
    
    progress+="] ${percent}%"
    
    echo -ne "\r${BLUE}${progress}${NC}"
}

# Bestätigung vom Benutzer einholen
confirm() {
    echo -e "${YELLOW}[WARNUNG]${NC} $1"
    read -p "Bist du sicher? (j/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Jj]$ ]]; then
        return 0  # Erfolg zurückgeben (true in Bash)
    else
        return 1  # Fehler zurückgeben (false in Bash)
    fi
}

###################
# Systemcheck     #
###################
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "Dieses Skript muss als Root ausgeführt werden."
    fi
}

check_dependencies() {
    log_info "Prüfe Abhängigkeiten..."
    
    local deps=("sgdisk" "cryptsetup" "debootstrap" "lvm2" "curl" "wget")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_info "Aktualisiere Paketquellen..."
        apt-get update
        log_info "Installiere fehlende Abhängigkeiten: ${missing_deps[*]}..."
        apt-get install -y "${missing_deps[@]}"
    fi
}

check_system() {
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        log_info "Erkanntes System: $PRETTY_NAME"
    else
        log_warn "Konnte Betriebssystem nicht erkennen"
    fi
}

setup_ssh_access() {
    # Lösche bestehende .bash_profile
    rm -f /root/.bash_profile
    
    # Einfaches 6-stelliges Passwort
    SSH_PASSWORD=$(tr -dc '0-9' < /dev/urandom | head -c 6)
    
    # Root-Passwort setzen
    echo "root:${SSH_PASSWORD}" | chpasswd
    
    # SSH-Server einrichten - Kein erneutes apt-get update
    apt-get install -y screen openssh-server
    
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
    sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
    systemctl restart ssh

    # Speichere bisherige Einstellungen für SSH-Start
    echo "INSTALL_MODE=2" > /tmp/install_config
    echo "SAVE_CONFIG=${SAVE_CONFIG}" >> /tmp/install_config
    echo "CONFIG_OPTION=${CONFIG_OPTION}" >> /tmp/install_config
    echo "SKIP_INITIAL_QUESTIONS=true" >> /tmp/install_config
    
    # Skript kopieren - SICHERSTELLEN, DASS ES MIT VOLLEM PFAD KOPIERT WIRD
    SCRIPT_PATH=$(readlink -f "$0")
    cp "$SCRIPT_PATH" /root/install_script.sh
    chmod +x /root/install_script.sh
    
    # SSH-Login mit automatischer Verbindung zur Installation
    cat > /root/.bash_profile <<EOF
if [ -n "\$SSH_CONNECTION" ]; then
    if [ -f "/root/install_script.sh" ]; then
        echo "Verbinde mit der Installation..."
        /root/install_script.sh ssh_connect
    else
        echo "FEHLER: Installationsskript nicht gefunden!"
        echo "Pfad: /root/install_script.sh"
        ls -la /root/
    fi
fi
EOF
    
    # SSH-Zugangsdaten anzeigen
    echo -e "\n${CYAN}===== SSH-ZUGANG AKTIV =====${NC}"
    echo -e "SSH-Server wurde aktiviert. Verbinde dich mit:"
    echo -e "${YELLOW}IP-Adressen:${NC}"
    ip -4 addr show scope global | grep inet | awk '{print "  " $2}' | cut -d/ -f1
    echo -e "${YELLOW}Benutzername:${NC} root"
    echo -e "${YELLOW}Passwort:${NC} ${SSH_PASSWORD}"
    echo -e "${CYAN}============================${NC}"
    echo
    
    # Marker für laufende Installation
    touch /tmp/installation_running
    
    # Blockiere die lokale Installation
    echo -e "\n${CYAN}Die Installation wird jetzt über SSH fortgesetzt.${NC}"
    echo -e "Dieser lokale Prozess wird blockiert, bis die Installation abgeschlossen ist."
    echo -e "(Drücke CTRL+C um abzubrechen)"
    echo
    
    # Erstelle einen einzigartigen Namen für unseren Semaphor
    SEM_NAME="/tmp/install_done_$(date +%s)"
    touch /tmp/sem_name
    echo "$SEM_NAME" > /tmp/sem_name
    
    # Warten bis die Installation beendet ist
    while true; do
        if [ -f "$SEM_NAME" ]; then
            echo "Installation abgeschlossen."
            rm -f "$SEM_NAME"
            break
        fi
        sleep 5
    done
    
    # Beenden nach Abschluss
    exit 0
}

# Netzwerk konfigurieren
check_network_connectivity() {
    log_info "Prüfe Netzwerkverbindung..."
    
    # Erst prüfen, ob wir bereits eine Verbindung haben
    if ping -c 1 -W 2 archive.ubuntu.com &> /dev/null; then
        log_info "Bestehende Netzwerkverbindung erkannt. Fahre fort..."
        NETWORK_CONFIG="dhcp"  # Annahme: Wenn es funktioniert, ist es wahrscheinlich DHCP
        return 0
        
        # Wenn Netplan-Konfiguration existiert, behalten
        if [ -d /etc/netplan ] && [ "$(find /etc/netplan -name "*.yaml" | wc -l)" -gt 0 ]; then
            log_info "Bestehende Netplan-Konfiguration gefunden, wird beibehalten."
        fi
    fi
    
    # Falls Installer noch läuft, versuche diesen zu beenden
    if pgrep subiquity > /dev/null; then
        log_info "Beende laufenden Ubuntu-Installer..."
        pkill -9 subiquity || true
    fi
    
#    # Netplan-Konfigurationen entfernen, falls vorhanden
#    if [ -d /etc/netplan ]; then
#        log_info "Lösche bestehende Netplan-Konfigurationen..."
#        rm -f /etc/netplan/*.yaml
#    fi
    
    # Versuche DHCP
    log_info "Versuche Netzwerkverbindung über DHCP herzustellen..."
    if command -v dhclient &> /dev/null; then
        dhclient -v || true
    elif command -v dhcpclient &> /dev/null; then
        dhcpclient -v || true
    fi
    
    # Prüfe erneut nach Verbindung
    if ping -c 1 -W 2 archive.ubuntu.com &> /dev/null; then
        log_info "Netzwerkverbindung über DHCP hergestellt."
        NETWORK_CONFIG="dhcp"
        return 0
    else
        log_warn "Keine Netzwerkverbindung über DHCP gefunden."
        
        # # Netzwerkoptionen anbieten
        # while true; do
        #     echo -e "\n${CYAN}Netzwerkkonfiguration:${NC}"
        #     echo "1) Erneut mit DHCP versuchen"
        #     echo "2) Statische IP-Adresse konfigurieren"
        #     echo "3) Ohne Netzwerk fortfahren (nicht empfohlen)"
        #     read -p "Wähle eine Option [2]: " NETWORK_CHOICE
        #     NETWORK_CHOICE=${NETWORK_CHOICE:-2}
        #     
        #     if [ "$NETWORK_CHOICE" = "1" ]; then
        #         log_info "Versuche DHCP erneut..."
        #         if command -v dhclient &> /dev/null; then
        #             dhclient -v || true
        #         elif command -v dhcpclient &> /dev/null; then
        #             dhcpclient -v || true
        #         fi
        #         
        #         if ping -c 1 -W 2 archive.ubuntu.com &> /dev/null; then
        #             log_info "Netzwerkverbindung OK."
        #             NETWORK_CONFIG="dhcp"
        #             return 0
        #         else
        #             log_warn "DHCP fehlgeschlagen."
        #             # Erneut zur Auswahl zurückkehren
        #         fi
        #     elif [ "$NETWORK_CHOICE" = "2" ]; then
        #         if configure_static_ip; then
        #             return 0
        #         fi
        #         # Bei Fehlschlag zur Auswahl zurückkehren
        #     else
        #         log_warn "Installation ohne Netzwerk wird fortgesetzt. Einige Funktionen werden nicht verfügbar sein."
        #         NETWORK_CONFIG="none"
        #         return 1
        #     fi
        # done
    fi
}

configure_static_ip() {
    # Netzwerkinterface ermitteln
    echo -e "\n${CYAN}Verfügbare Netzwerkinterfaces:${NC}"
    ip -o link show | grep -v "lo" | awk -F': ' '{print $2}'
    
    read -p "Netzwerkinterface (z.B. eth0, enp0s3): " NET_INTERFACE
    read -p "IP-Adresse (z.B. 192.168.1.100): " NET_IP
    read -p "Netzmaske (z.B. 24 für /24): " NET_MASK
    read -p "Gateway (z.B. 192.168.1.1): " NET_GATEWAY
    read -p "DNS-Server (z.B. 8.8.8.8): " NET_DNS
    
    log_info "Konfiguriere statische IP-Adresse..."
    ip addr add ${NET_IP}/${NET_MASK} dev ${NET_INTERFACE} || true
    ip link set ${NET_INTERFACE} up || true
    ip route add default via ${NET_GATEWAY} || true
    echo "nameserver ${NET_DNS}" > /etc/resolv.conf
    
    if ping -c 1 -W 2 archive.ubuntu.com &> /dev/null; then
        log_info "Netzwerkverbindung OK."
        NETWORK_CONFIG="static"
        STATIC_IP_CONFIG="interface=${NET_INTERFACE},address=${NET_IP}/${NET_MASK},gateway=${NET_GATEWAY},dns=${NET_DNS}"
        return 0
    else
        log_warn "Netzwerkverbindung konnte nicht hergestellt werden. Überprüfe deine Einstellungen."
        return 1
    fi
}

###################
# Konfiguration   #
###################
load_config() {
    local config_path=$1
    
    if [ -f "$config_path" ]; then
        log_info "Lade Konfiguration aus $config_path..."
        source "$config_path"
        return 0
    else
        return 1
    fi
}

save_config() {
    local config_path=$1
    
    log_info "Speichere Konfiguration in $config_path..."
    cat > "$config_path" << EOF
# Ubuntu FDE Konfiguration
# Erstellt am $(date)
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
DEV="$DEV"
ROOT_SIZE="$ROOT_SIZE"
DATA_SIZE="$DATA_SIZE"
SWAP_SIZE="$SWAP_SIZE"
LUKS_PASSWORD="$LUKS_PASSWORD"
USER_PASSWORD="$USER_PASSWORD"
INSTALL_MODE="$INSTALL_MODE"
KERNEL_TYPE="$KERNEL_TYPE"
ENABLE_SECURE_BOOT="$ENABLE_SECURE_BOOT"
ADDITIONAL_PACKAGES="$ADDITIONAL_PACKAGES"
UBUNTU_CODENAME="$UBUNTU_CODENAME"
UPDATE_OPTION="$UPDATE_OPTION"
INSTALL_DESKTOP="$INSTALL_DESKTOP"
DESKTOP_ENV="$DESKTOP_ENV"
DESKTOP_SCOPE="$DESKTOP_SCOPE"
LOCALE="$LOCALE"
KEYBOARD_LAYOUT="$KEYBOARD_LAYOUT"
TIMEZONE="$TIMEZONE"
NETWORK_CONFIG="$NETWORK_CONFIG"
STATIC_IP_CONFIG="$STATIC_IP_CONFIG"
EOF
    chmod 600 "$config_path"
    log_info "Konfiguration gespeichert."
}

calculate_available_space() {
    local dev=$1
    local efi_size=256  # MB
    local boot_size=1536  # MB
    local grub_size=2  # MB
    local total_size_mb
    
    # Konvertiere Gesamtgröße in MB
    if [[ "$(lsblk -d -n -o SIZE "$dev" | tr -d ' ')" =~ ([0-9.]+)([GT]) ]]; then
        if [ "${BASH_REMATCH[2]}" = "T" ]; then
            total_size_mb=$(echo "${BASH_REMATCH[1]} * 1024 * 1024" | bc | cut -d. -f1)
        else  # G
            total_size_mb=$(echo "${BASH_REMATCH[1]} * 1024" | bc | cut -d. -f1)
        fi
    else
        # Fallback - nehme an, es ist in MB
        total_size_mb=$(lsblk -d -n -o SIZE "$dev" --bytes | awk '{print $1 / 1024 / 1024}' | cut -d. -f1)
    fi
    
    # Berechne verfügbaren Speicher (nach Abzug von EFI, boot, grub)
    local reserved_mb=$((efi_size + boot_size + grub_size))
    local available_mb=$((total_size_mb - reserved_mb))
    local available_gb=$((available_mb / 1024))
    
    echo "$available_gb"
}

gather_disk_input() {
    # Feststellungen verfügbarer Laufwerke
    available_devices=()
    echo -e "\n${CYAN}Verfügbare Laufwerke:${NC}"
    echo -e "${YELLOW}NR   GERÄT                GRÖSSE      MODELL${NC}"
    echo -e "-------------------------------------------------------"
    i=0
    while read device size model; do
        # Überspringe Überschriften oder leere Zeilen
        if [[ "$device" == "NAME" || -z "$device" ]]; then
            continue
        fi
        available_devices+=("$device")
        ((i++))
        printf "%-4s %-20s %-12s %s\n" "[$i]" "$device" "$size" "$model"
    done < <(lsblk -d -p -o NAME,SIZE,MODEL | grep -v loop)
    echo -e "-------------------------------------------------------"

    # Wenn keine Geräte gefunden wurden
    if [ ${#available_devices[@]} -eq 0 ]; then
        log_error "Keine Laufwerke gefunden!"
    fi

    # Standardwert ist das erste Gerät
    DEFAULT_DEV="1"
    DEFAULT_DEV_PATH="${available_devices[0]}"

    # Laufwerksauswahl
    read -p "Wähle ein Laufwerk (Nummer oder vollständiger Pfad) [1]: " DEVICE_CHOICE
    DEVICE_CHOICE=${DEVICE_CHOICE:-1}

    # Verarbeite die Auswahl
    if [[ "$DEVICE_CHOICE" =~ ^[0-9]+$ ]] && [ "$DEVICE_CHOICE" -ge 1 ] && [ "$DEVICE_CHOICE" -le "${#available_devices[@]}" ]; then
        # Nutzer hat Nummer ausgewählt
        DEV="${available_devices[$((DEVICE_CHOICE-1))]}"
    else
        # Nutzer hat möglicherweise einen Pfad eingegeben
        if [ -b "$DEVICE_CHOICE" ]; then
            DEV="$DEVICE_CHOICE"
        else
            # Ungültige Eingabe - verwende erstes Gerät als Fallback
            DEV="${available_devices[0]}"
            log_info "Ungültige Eingabe. Verwende Standardgerät: $DEV"
        fi
    fi

    # Berechne verfügbaren Speicherplatz
    AVAILABLE_GB=$(calculate_available_space "$DEV")

    # Zeige Gesamtspeicher und verfügbaren Speicher
    TOTAL_SIZE=$(lsblk -d -n -o SIZE "$DEV" | tr -d ' ')
    echo -e "\n${CYAN}Laufwerk: $DEV${NC}"
    echo -e "Gesamtspeicher: $TOTAL_SIZE"
    echo -e "Verfügbarer Speicher für LVM (nach Abzug der Systempartitionen): ${AVAILABLE_GB} GB"

    # LVM-Größenkonfiguration - erst Swap, dann Root, dann Data
    echo -e "\n${CYAN}LVM-Konfiguration:${NC}"

    # Swap-Konfiguration
    RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    RAM_MB=$((RAM_KB / 1024))
    RAM_GB=$((RAM_MB / 1024))
    DEFAULT_SWAP=$((RAM_GB * 2))
    
    read -p "Größe für swap-LV (GB) [$DEFAULT_SWAP]: " SWAP_SIZE
    SWAP_SIZE=${SWAP_SIZE:-$DEFAULT_SWAP}

    # Berechne verbleibenden Speicher nach Swap
    REMAINING_GB=$((AVAILABLE_GB - SWAP_SIZE))
    echo -e "Verbleibender Speicher: ${REMAINING_GB} GB"

    # Root-Konfiguration
    read -p "Größe für root-LV (GB) [$DEFAULT_ROOT_SIZE]: " ROOT_SIZE
    ROOT_SIZE=${ROOT_SIZE:-$DEFAULT_ROOT_SIZE}

    # Berechne verbleibenden Speicher nach Root
    REMAINING_GB=$((REMAINING_GB - ROOT_SIZE))
    echo -e "Verbleibender Speicher: ${REMAINING_GB} GB"

    # Data-Konfiguration
    echo -e "Größe für data-LV (GB) [Restlicher Speicher (${REMAINING_GB} GB)]: "
    read DATA_SIZE_INPUT

    if [ -z "$DATA_SIZE_INPUT" ] || [ "$DATA_SIZE_INPUT" = "0" ]; then
        DATA_SIZE="0"  # 0 bedeutet restlicher Platz
        echo -e "data-LV verwendet den restlichen Speicher: ${REMAINING_GB} GB"
    else
        DATA_SIZE=$DATA_SIZE_INPUT
        REMAINING_GB=$((REMAINING_GB - DATA_SIZE))
        echo -e "Verbleibender ungenutzter Speicher: ${REMAINING_GB} GB"
    fi
}

gather_user_input() {
    echo -e "${CYAN}===== INSTALLATIONSKONFIGURATION =====${NC}"
    
    # Wenn von SSH fortgesetzt, überspringe die ersten Fragen
    if [ "${SKIP_INITIAL_QUESTIONS}" = "true" ]; then
        log_info "Setze mit Desktop-Installation fort..."
    else
        # Frage nach Konfigurationsdatei oder Speicherung
        echo -e "\n${CYAN}Konfigurationsverwaltung:${NC}"
        echo "1) Neue Konfiguration erstellen"
        echo "2) Bestehende Konfigurationsdatei laden"
        read -p "Wähle eine Option [1]: " CONFIG_OPTION
        CONFIG_OPTION=${CONFIG_OPTION:-1}
        
        if [ "$CONFIG_OPTION" = "2" ]; then
            read -p "Pfad zur Konfigurationsdatei: " config_path
            if load_config "$config_path"; then
                log_info "Konfiguration erfolgreich geladen."
                
                # Frage, ob am Ende trotzdem gespeichert werden soll
                read -p "Möchtest du die Konfiguration nach möglichen Änderungen erneut speichern? (j/n) [j]: " -r
                SAVE_CONFIG=${REPLY:-j}
                
                # Wenn Remote-Installation in der Konfiguration ist, direkt SSH einrichten
                if [ "${INSTALL_MODE:-1}" = "2" ]; then
                    setup_ssh_access
                fi
                
                return
            else
                log_warn "Konfigurationsdatei nicht gefunden. Fahre mit manueller Konfiguration fort."
            fi
        fi
        
        # Frage, ob die Konfiguration gespeichert werden soll
        read -p "Möchtest du die Konfiguration für spätere Verwendung speichern? (j/n) [n]: " -r
        SAVE_CONFIG=${REPLY:-n}
        
        # Installationsmodus
        echo -e "\n${CYAN}Installationsmodus:${NC}"
        echo "1) Lokale Installation (Kein SSH-Zugriff verfügbar)"
        echo "2) Remote-Installation (SSH-Server wird eingerichtet)"
        read -p "Wähle den Installationsmodus [1]: " INSTALL_MODE_CHOICE
        INSTALL_MODE=${INSTALL_MODE_CHOICE:-1}
        
        # Wenn Remote-Installation gewählt wurde, direkt SSH einrichten
        if [ "$INSTALL_MODE" = "2" ]; then
            setup_ssh_access
        fi
    fi

    # Desktop-Installation
    echo -e "\n${CYAN}Desktop-Installation:${NC}"
    echo "1) Ja, Desktop-Umgebung installieren"
    echo "2) Nein, nur Server-Installation"
    read -p "Desktop installieren? [1]: " DESKTOP_CHOICE
    INSTALL_DESKTOP=$([[ ${DESKTOP_CHOICE:-1} == "1" ]] && echo "1" || echo "0")
    
    # Desktopumgebung auswählen wenn Desktop gewünscht
    if [ "$INSTALL_DESKTOP" = "1" ]; then
        echo -e "\n${CYAN}Desktop-Umgebung:${NC}"
        echo "1) GNOME (Standard Ubuntu Desktop)"
        echo "2) KDE Plasma (leichtgewichtiger, Windows-ähnlich)"
        echo "3) Xfce (sehr leichtgewichtig)"
        read -p "Wähle eine Desktop-Umgebung [1]: " DE_CHOICE
        DESKTOP_ENV=${DE_CHOICE:-1}
        
        echo -e "\n${CYAN}Umfang der Desktop-Installation:${NC}"
        echo "1) Minimal (nur Basisfunktionalität)"
        echo "2) Standard (empfohlen, alle wichtigen Anwendungen)"
        read -p "Wähle den Installationsumfang [1]: " DE_SCOPE
        DESKTOP_SCOPE=${DE_SCOPE:-1}
    fi
    
    # Systemparameter
    RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    RAM_MB=$((RAM_KB / 1024))
    RAM_GB=$((RAM_MB / 1024))
    DEFAULT_SWAP=$((RAM_GB * 2))

    # Benutzeroberflächen-Sprache
    echo -e "\n${CYAN}Sprache der Benutzeroberfläche:${NC}"
    echo "1) Deutsch"
    echo "2) English"
    echo "3) Français"
    echo "4) Italiano" 
    echo "5) Русский"
    echo "6) Español"
    echo "7) Andere/Other"
    read -p "Wähle die Sprache für die Benutzeroberfläche [1]: " UI_LANG_CHOICE

    case ${UI_LANG_CHOICE:-1} in
        1) UI_LANGUAGE="de_DE" ;;
        2) UI_LANGUAGE="en_US" ;;
        3) UI_LANGUAGE="fr_FR" ;;
        4) UI_LANGUAGE="it_IT" ;;
        5) UI_LANGUAGE="ru_RU" ;;
        6) UI_LANGUAGE="es_ES" ;;
        7) read -p "Gib den Sprachcode ein (z.B. nl_NL): " UI_LANGUAGE ;;
        *) UI_LANGUAGE="de_DE" ;;
    esac
    
    # Zeitzone
    echo -e "\n${CYAN}Zeitzone:${NC}"
    echo "1) Europe/Berlin"
    echo "2) Europe/Moscow"
    echo "3) America/New_York"
    echo "4) America/Los_Angeles"
    echo "5) Asia/Tokyo"
    echo "6) Australia/Sydney"
    echo "7) Africa/Johannesburg"
    echo "8) Benutzerdefiniert"
    read -p "Wähle eine Zeitzone [1]: " TIMEZONE_CHOICE

    case ${TIMEZONE_CHOICE:-1} in
        1) TIMEZONE="Europe/Berlin" ;;
        2) TIMEZONE="Europe/Moscow" ;;
        3) TIMEZONE="America/New_York" ;;
        4) TIMEZONE="America/Los_Angeles" ;;
        5) TIMEZONE="Asia/Tokyo" ;;
        6) TIMEZONE="Australia/Sydney" ;;
        7) TIMEZONE="Africa/Johannesburg" ;;
        8) read -p "Gib deine Zeitzone ein (z.B. Asia/Singapore): " TIMEZONE ;;
        *) TIMEZONE="Europe/Berlin" ;;
    esac

    # Sprache und Tastatur
    echo -e "\n${CYAN}Sprache und Tastatur:${NC}"
    echo "1) Deutsch (Deutschland) - de_DE.UTF-8"
    echo "2) Deutsch (Schweiz) - de_CH.UTF-8"
    echo "3) Englisch (USA) - en_US.UTF-8"
    echo "4) Französisch - fr_FR.UTF-8"
    echo "5) Italienisch - it_IT.UTF-8"
    echo "6) Benutzerdefiniert"
    read -p "Wähle eine Option [1]: " LOCALE_CHOICE

    case ${LOCALE_CHOICE:-1} in
        1) LOCALE="de_DE.UTF-8"; KEYBOARD_LAYOUT="de" ;;
        2) LOCALE="de_CH.UTF-8"; KEYBOARD_LAYOUT="ch" ;;
        3) LOCALE="en_US.UTF-8"; KEYBOARD_LAYOUT="us" ;;
        4) LOCALE="fr_FR.UTF-8"; KEYBOARD_LAYOUT="fr" ;;
        5) LOCALE="it_IT.UTF-8"; KEYBOARD_LAYOUT="it" ;;
        6) 
            read -p "Gib deine Locale ein (z.B. es_ES.UTF-8): " LOCALE
            read -p "Gib dein Tastaturlayout ein (z.B. es): " KEYBOARD_LAYOUT
            ;;
        *) LOCALE="de_DE.UTF-8"; KEYBOARD_LAYOUT="de" ;;
    esac
    
    # Hostname und Benutzername
    echo -e "\n${CYAN}Systemkonfiguration:${NC}"
    read -p "Hostname [$DEFAULT_HOSTNAME]: " HOSTNAME
    HOSTNAME=${HOSTNAME:-$DEFAULT_HOSTNAME}

    read -p "Benutzername [$DEFAULT_USERNAME]: " USERNAME
    USERNAME=${USERNAME:-$DEFAULT_USERNAME}

    # Benutzerpasswort mit Validierung
    while true; do
        read -s -p "Benutzerpasswort: " USER_PASSWORD
        echo
        
        # Prüfe ob Passwort leer ist
        if [ -z "$USER_PASSWORD" ]; then
            echo -e "${YELLOW}[WARNUNG]${NC} Das Passwort darf nicht leer sein. Bitte erneut versuchen."
            continue
        fi
        
        read -s -p "Benutzerpasswort (Bestätigung): " USER_PASSWORD_CONFIRM
        echo
        
        # Prüfe ob Passwörter übereinstimmen
        if [ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]; then
            echo -e "${YELLOW}[WARNUNG]${NC} Passwörter stimmen nicht überein. Bitte erneut versuchen."
            continue
        fi
        
        break
    done

    # LUKS-Passwort mit Validierung
    while true; do
        read -s -p "LUKS-Verschlüsselungs-Passwort: " LUKS_PASSWORD
        echo
        
        # Prüfe ob Passwort leer ist
        if [ -z "$LUKS_PASSWORD" ]; then
            echo -e "${YELLOW}[WARNUNG]${NC} Das LUKS-Passwort darf nicht leer sein. Bitte erneut versuchen."
            continue
        fi
        
        read -s -p "LUKS-Verschlüsselungs-Passwort (Bestätigung): " LUKS_PASSWORD_CONFIRM
        echo
        
        # Prüfe ob Passwörter übereinstimmen
        if [ "$LUKS_PASSWORD" != "$LUKS_PASSWORD_CONFIRM" ]; then
            echo -e "${YELLOW}[WARNUNG]${NC} LUKS-Passwörter stimmen nicht überein. Bitte erneut versuchen."
            continue
        fi
        
        break
    done

    # Festplattenauswahl
    gather_disk_input

    # Warnung vor der Partitionierung
    if ! confirm "ALLE DATEN AUF $DEV WERDEN GELÖSCHT!"; then
        log_warn "Partitionierung abgebrochen. Beginne erneut mit der Auswahl der Festplatte..."
        unset DEV SWAP_SIZE ROOT_SIZE DATA_SIZE
        gather_disk_input
        # Erneute Bestätigung, bis der Benutzer ja sagt
        while ! confirm "ALLE DATEN AUF $DEV WERDEN GELÖSCHT!"; do
            log_warn "Partitionierung abgebrochen. Beginne erneut mit der Auswahl der Festplatte..."
            unset DEV SWAP_SIZE ROOT_SIZE DATA_SIZE
            gather_disk_input
        done
    fi

    echo -e "\n${GREEN}[INFO]${NC} Partitionierung bestätigt. Die Festplatte wird nach Abschluss aller Konfigurationsfragen partitioniert."
    DISK_CONFIRMED=true
    export DISK_CONFIRMED
    
    # Kernel-Auswahl
    echo -e "\n${CYAN}Kernel-Auswahl:${NC}"
    echo "1) Standard-Kernel (Ubuntu Stock)"
    echo "2) Liquorix-Kernel (Optimiert für Desktop-Nutzung / Nicht kompatibel mit VM's)"
    echo "3) Low-Latency-Kernel (Optimiert für Echtzeitanwendungen)"
    read -p "Wähle den Kernel-Typ [1]: " KERNEL_CHOICE
    case ${KERNEL_CHOICE:-1} in
        1) KERNEL_TYPE="standard" ;;
        2) KERNEL_TYPE="liquorix" ;;
        3) KERNEL_TYPE="lowlatency" ;;
        *) KERNEL_TYPE="standard" ;;
    esac
    
    # Secure Boot
    echo -e "\n${CYAN}Secure Boot:${NC}"
    read -p "Secure Boot aktivieren? (j/n) [n]: " -r
    ENABLE_SECURE_BOOT=${REPLY:-n}
    
    # Installationsoptionen für Ubuntu
    echo -e "\n${CYAN}Ubuntu-Installation:${NC}"
    echo "1) Standard-Installation (neueste stabile Version)"
    echo "2) Spezifische Ubuntu-Version installieren"
    echo "3) Netzwerkinstallation (minimal)"
    read -p "Wähle eine Option [1]: " UBUNTU_INSTALL_OPTION
    UBUNTU_INSTALL_OPTION=${UBUNTU_INSTALL_OPTION:-1}
    
    # Ubuntu-Version ermitteln
    if [ "$UBUNTU_INSTALL_OPTION" = "1" ]; then
        # Automatisch neueste Version ermitteln
        UBUNTU_VERSION=$(curl -s https://changelogs.ubuntu.com/meta-release | grep "^Dist: " | tail -1 | cut -d' ' -f2)
        UBUNTU_CODENAME=$(curl -s https://changelogs.ubuntu.com/meta-release | grep "^Codename: " | tail -1 | cut -d' ' -f2)
        
        # Falls automatische Erkennung fehlschlägt
        if [ -z "$UBUNTU_VERSION" ]; then
            UBUNTU_CODENAME="oracular"  # Ubuntu 24.10 (Oracular Oriole)
        fi
    elif [ "$UBUNTU_INSTALL_OPTION" = "2" ]; then
        echo -e "\nVerfügbare Ubuntu-Versionen:"
        echo "1) 24.10 (Oracular Oriole) - aktuell"
        echo "2) 24.04 LTS (Noble Numbat) - langzeitunterstützt"
        echo "3) 23.10 (Mantic Minotaur)"
        echo "4) 22.04 LTS (Jammy Jellyfish) - langzeitunterstützt"
        read -p "Wähle eine Version [1]: " UBUNTU_VERSION_OPTION
        
        case ${UBUNTU_VERSION_OPTION:-1} in
            1) UBUNTU_CODENAME="oracular" ;;
            2) UBUNTU_CODENAME="noble" ;;
            3) UBUNTU_CODENAME="mantic" ;;
            4) UBUNTU_CODENAME="jammy" ;;
            *) UBUNTU_CODENAME="oracular" ;;
        esac
    else
        # Minimale Installation
        UBUNTU_CODENAME="oracular"
    fi
    
    # Aktualisierungseinstellungen
    echo -e "\n${CYAN}Aktualisierungseinstellungen:${NC}"
    echo "1) Alle Updates automatisch installieren"
    echo "2) Nur Sicherheitsupdates automatisch installieren"
    echo "3) Keine automatischen Updates"
    read -p "Wähle eine Option [1]: " UPDATE_OPTION
    UPDATE_OPTION=${UPDATE_OPTION:-1}
    
    # Zusätzliche Pakete
    echo -e "\n${CYAN}Zusätzliche Pakete:${NC}"
    read -p "Möchtest du zusätzliche Pakete installieren? (j/n) [n]: " -r
    if [[ ${REPLY:-n} =~ ^[Jj]$ ]]; then
        read -p "Gib zusätzliche Pakete an (durch Leerzeichen getrennt): " ADDITIONAL_PACKAGES
    fi
}

###################
# Partitionierung #
###################
prepare_disk() {
    log_progress "Beginne mit der Partitionierung..."
    show_progress 10

    # Bestätigung nur einholen, wenn sie nicht bereits erfolgt ist
    if [ "${DISK_CONFIRMED:-false}" != "true" ]; then
        if ! confirm "ALLE DATEN AUF $DEV WERDEN GELÖSCHT!"; then
            log_warn "Partitionierung abgebrochen. Beginne erneut mit der Auswahl der Festplatte..."
            unset DEV SWAP_SIZE ROOT_SIZE DATA_SIZE
            gather_disk_input
            prepare_disk
            return
        fi
    else
        log_info "Festplattenauswahl bestätigt, führe Partitionierung durch..."
    fi 
    
    # Grundlegende Variablen einrichten
    DM="${DEV##*/}"
    if [[ "$DEV" =~ "nvme" ]]; then
        DEVP="${DEV}p"
        DM="${DM}p"
    else
        DEVP="${DEV}"
    fi
    
    # Export für spätere Verwendung
    export DEV DEVP DM
    
    # Partitionierung
    log_info "Partitioniere $DEV..."
    sgdisk --zap-all "$DEV"
    sgdisk --new=1:0:+1536M "$DEV"   # /boot verdoppelt (1536MB statt 768MB)
    sgdisk --new=2:0:+2M "$DEV"      # GRUB
    sgdisk --new=3:0:+256M "$DEV"    # EFI-SP verdoppelt (256MB statt 128MB)
    sgdisk --new=5:0:0 "$DEV"        # rootfs
    sgdisk --typecode=1:8301 --typecode=2:ef02 --typecode=3:ef00 --typecode=5:8301 "$DEV"
    sgdisk --change-name=1:/boot --change-name=2:GRUB --change-name=3:EFI-SP --change-name=5:rootfs "$DEV"
    sgdisk --hybrid 1:2:3 "$DEV"
    sgdisk --print "$DEV"
    
    log_info "Partitionierung abgeschlossen"
    show_progress 20
}

setup_encryption() {
    log_progress "Richte Verschlüsselung ein..."
    
    log_info "Erstelle LUKS-Verschlüsselung für Boot-Partition..."
    # LUKS1 für /boot mit dem eingegebenen Passwort
    echo -n "$LUKS_PASSWORD" | cryptsetup luksFormat --type=luks1 --batch-mode "${DEVP}1" -
    
    log_info "Erstelle LUKS-Verschlüsselung für Root-Partition..."
    # LUKS2 für das Root-System
    echo -n "$LUKS_PASSWORD" | cryptsetup luksFormat --batch-mode "${DEVP}5" -
    
    # Öffne die verschlüsselten Geräte
    log_info "Öffne die verschlüsselten Partitionen..."
    echo -n "$LUKS_PASSWORD" | cryptsetup open "${DEVP}1" "${LUKS_BOOT_NAME}" -
    echo -n "$LUKS_PASSWORD" | cryptsetup open "${DEVP}5" "${LUKS_ROOT_NAME}" -
    
    # Dateisysteme erstellen
    log_info "Formatiere Dateisysteme..."
    mkfs.ext4 -L boot /dev/mapper/${LUKS_BOOT_NAME}
    mkfs.vfat -F 16 -n EFI-SP "${DEVP}3"
    
    show_progress 30
}

setup_lvm() {
    log_progress "Richte LVM ein..."
    
    log_info "Erstelle LVM-Struktur..."
    export VGNAME="vg"
    
    pvcreate /dev/mapper/${LUKS_ROOT_NAME}
    vgcreate "${VGNAME}" /dev/mapper/${LUKS_ROOT_NAME}
    
    # Erstelle LVs mit den angegebenen Größen
    lvcreate -L ${SWAP_SIZE}G -n swap "${VGNAME}"  # "swap" statt "swap_1"
    lvcreate -L ${ROOT_SIZE}G -n root "${VGNAME}"
    
    # Wenn DATA_SIZE 0 ist, verwende den restlichen Platz
    if [ "$DATA_SIZE" = "0" ]; then
        lvcreate -l 100%FREE -n data "${VGNAME}"
    else
        lvcreate -L ${DATA_SIZE}G -n data "${VGNAME}"
    fi
    
    log_info "Formatiere LVM-Volumes..."
    mkfs.ext4 -L root /dev/mapper/${VGNAME}-root
    mkfs.ext4 -L data /dev/mapper/${VGNAME}-data
    mkswap -L swap /dev/mapper/${VGNAME}-swap
    
    show_progress 40
}

###################
# Basissystem     #
###################
mount_filesystems() {
    log_progress "Hänge Dateisysteme ein..."
    
    # Mount-Punkte erstellen
    mkdir -p /mnt/ubuntu
    mount /dev/mapper/${VGNAME}-root /mnt/ubuntu
    mkdir -p /mnt/ubuntu/boot
    mount /dev/mapper/${LUKS_BOOT_NAME} /mnt/ubuntu/boot
    mkdir -p /mnt/ubuntu/boot/efi
    mount ${DEVP}3 /mnt/ubuntu/boot/efi
    mkdir -p /mnt/ubuntu/data
    mount /dev/mapper/${VGNAME}-data /mnt/ubuntu/data
    
    show_progress 45
}

install_base_system() {
    log_progress "Installiere Basissystem..."
    
    # Prüfe Netzwerkverbindung
    check_network_connectivity

    # GPG-Schlüssel für lokalen Mirror importieren
    mkdir -p /mnt/ubuntu/etc/apt/trusted.gpg.d/
    curl -fsSL http://192.168.56.120/repo-key.gpg | gpg --dearmor -o /mnt/ubuntu/etc/apt/trusted.gpg.d/local-mirror.gpg
    
    # Ubuntu-Basissystem mit debootstrap installieren
    log_info "Installiere Ubuntu $UBUNTU_CODENAME Basissystem (dies kann einige Minuten dauern)..."
    
    # Bei Netzwerkinstallation nur Minimal-System installieren
    echo "Installiere Ubuntu $UBUNTU_CODENAME mit debootstrap..."

    # Zu inkludierende Pakete definieren
    PACKAGES=(
        curl gnupg ca-certificates sudo locales cryptsetup lvm2 nano wget
        apt-transport-https console-setup bash-completion systemd-resolved
        initramfs-tools cryptsetup-initramfs grub-efi-amd64 grub-efi-amd64-signed
        efibootmgr 
    )

    # Pakete zu kommagetrennter Liste zusammenfügen
    PACKAGELIST=$(IFS=,; echo "${PACKAGES[*]}")

    if [ "$UBUNTU_INSTALL_OPTION" = "3" ]; then
        debootstrap \
            --include="$PACKAGELIST" \
            --variant=minbase \
            --components=main,restricted,universe,multiverse \
            --arch=amd64 \
            oracular \
            /mnt/ubuntu \
            http://192.168.56.120/ubuntu
        if [ $? -ne 0 ]; then
            log_error "debootstrap fehlgeschlagen für oracular"
        fi
    else
        debootstrap \
            --include="$PACKAGELIST" \
            --components=main,restricted,universe,multiverse \
            --arch=amd64 \
            oracular \
            /mnt/ubuntu \
            http://192.168.56.120/ubuntu
        if [ $? -ne 0 ]; then
            log_error "debootstrap fehlgeschlagen für oracular"
        fi
    fi
    
    # Basisverzeichnisse für chroot
    for dir in /dev /dev/pts /proc /sys /run; do
        mkdir -p "/mnt/ubuntu$dir"
        mount -B $dir /mnt/ubuntu$dir
    done
    
    show_progress 60
}

download_thorium() {
    if [ "$INSTALL_DESKTOP" = "1" ]; then
        log_info "Downloade Thorium Browser für chroot-Installation..."
        
        # CPU-Erweiterungen prüfen
        if grep -q " avx2 " /proc/cpuinfo; then
            CPU_EXT="AVX2"
        elif grep -q " avx " /proc/cpuinfo; then
            CPU_EXT="AVX"
        elif grep -q " sse4_1 " /proc/cpuinfo; then
            CPU_EXT="SSE4"
        else
            CPU_EXT="SSE3"
        fi
        log_info "CPU-Erweiterung erkannt: ${CPU_EXT}"
        
        # Thorium-Version und direkter Download
        THORIUM_VERSION="130.0.6723.174"
        THORIUM_URL="https://github.com/Alex313031/thorium/releases/download/M${THORIUM_VERSION}/thorium-browser_${THORIUM_VERSION}_${CPU_EXT}.deb"
        log_info "Download-URL: ${THORIUM_URL}"
        
        # Download direkt ins chroot-Verzeichnis
        if wget --tries=3 --timeout=15 -O /mnt/ubuntu/tmp/thorium.deb "${THORIUM_URL}"; then
            log_info "Download erfolgreich - Thorium wird später in chroot installiert"
            chmod 644 /mnt/ubuntu/tmp/thorium.deb
        else
            log_error "Download fehlgeschlagen!"
        fi
    fi
}

prepare_chroot() {
    log_progress "Bereite chroot-Umgebung vor..."
    
# Aktuelle UUIDs für die Konfigurationsdateien ermitteln
LUKS_BOOT_UUID=$(blkid -s UUID -o value ${DEVP}1)
LUKS_ROOT_UUID=$(blkid -s UUID -o value ${DEVP}5)
EFI_UUID=$(blkid -s UUID -o value ${DEVP}3)

# Erst LUKS-Container öffnen
echo -n "$LUKS_PASSWORD" | cryptsetup open "${DEVP}1" LUKS_BOOT -
echo -n "$LUKS_PASSWORD" | cryptsetup open "${DEVP}5" "${DM}5_crypt" -

# Dann die UUIDs der entschlüsselten Geräte ermitteln
BOOT_UUID=$(blkid -s UUID -o value /dev/mapper/LUKS_BOOT)
ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/${VGNAME}-root)
DATA_UUID=$(blkid -s UUID -o value /dev/mapper/${VGNAME}-data)
SWAP_UUID=$(blkid -s UUID -o value /dev/mapper/${VGNAME}-swap)

# fstab mit den RICHTIGEN UUIDs erstellen
cat > /mnt/ubuntu/etc/fstab <<EOF
# /etc/fstab
# <file system>                                          <mount point>   <type>   <options>       <dump>  <pass>
# / - Root-Partition
UUID=${ROOT_UUID} /               ext4    defaults        0       1

# /boot - Boot-Partition (LUKS verschlüsselt)
UUID=${BOOT_UUID} /boot           ext4    defaults        0       2

# /boot/efi - EFI-Partition (nicht verschlüsselt)
UUID=${EFI_UUID} /boot/efi       vfat    umask=0077      0       1

# /data - Daten-Partition
UUID=${DATA_UUID} /data           ext4    defaults        0       2

# Swap-Partition
UUID=${SWAP_UUID} none            swap    sw              0       0
EOF

# crypttab erstellen
cat > /mnt/ubuntu/etc/crypttab <<EOF
${LUKS_BOOT_NAME} UUID=${LUKS_BOOT_UUID} /etc/luks/boot_os.keyfile luks,discard
${LUKS_ROOT_NAME} UUID=${LUKS_ROOT_UUID} /etc/luks/boot_os.keyfile luks,discard
EOF

# Überprüfe die Konfiguration und erstelle systemd-Einheiten für boot
mkdir -p /mnt/ubuntu/etc/systemd/system/
cat > /mnt/ubuntu/etc/systemd/system/boot.mount <<EOF
[Unit]
Description=Boot Partition
Before=local-fs.target
After=cryptsetup.target

[Mount]
What=/dev/mapper/${LUKS_BOOT_NAME}
Where=/boot
Type=ext4
Options=defaults

[Install]
WantedBy=local-fs.target
EOF

# Aktiviere die boot.mount-Einheit
mkdir -p /mnt/ubuntu/etc/systemd/system/local-fs.target.wants/
ln -sf /etc/systemd/system/boot.mount /mnt/ubuntu/etc/systemd/system/local-fs.target.wants/boot.mount

# System-Setup in chroot
log_progress "Konfiguriere System in chroot-Umgebung..."
cat > /mnt/ubuntu/setup.sh <<MAINEOF
#!/bin/bash
set -e

#set -x  # Detailliertes Debug-Logging aktivieren
#exec > >(tee -a /var/log/setup-debug.log) 2>&1

export DEBIAN_FRONTEND=noninteractive

# Zeitzone setzen
if [ -n "${TIMEZONE}" ]; then
    ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
else
    ln -sf /usr/share/zoneinfo/Europe/Zurich /etc/localtime
fi

# GPG-Schlüssel für lokales Repository importieren
if [ ! -f "/etc/apt/trusted.gpg.d/local-mirror.gpg" ]; then
    curl -fsSL http://192.168.56.120/repo-key.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/local-mirror.gpg
fi

# Paketquellen und Repositories einrichten

    # Ubuntu Paketquellen
cat > /etc/apt/sources.list <<-SOURCES
#deb http://192.168.56.120/ubuntu/ oracular main restricted universe multiverse
#deb http://192.168.56.120/ubuntu/ oracular-updates main restricted universe multiverse
#deb http://192.168.56.120/ubuntu/ oracular-security main restricted universe multiverse
#deb http://192.168.56.120/ubuntu/ oracular-backports main restricted universe multiverse

deb https://archive.ubuntu.com/ubuntu/ oracular main restricted universe multiverse
deb https://archive.ubuntu.com/ubuntu/ oracular-updates main restricted  universe multiverse
deb https://archive.ubuntu.com/ubuntu/ oracular-security main restricted universe multiverse
deb https://archive.ubuntu.com/ubuntu/ oracular-backports main restricted universe multiverse
SOURCES

    # Liquorix-Kernel Repository (nur falls ausgewählt)
    if [ "${KERNEL_TYPE}" = "liquorix" ]; then
        echo "Füge Liquorix-Kernel-Repository hinzu..."
        echo "deb http://liquorix.net/debian stable main" > /etc/apt/sources.list.d/liquorix.list
        mkdir -p /etc/apt/keyrings
        curl -s 'https://liquorix.net/linux-liquorix-keyring.gpg' | gpg --dearmor -o /etc/apt/keyrings/liquorix-keyring.gpg
        echo "deb [signed-by=/etc/apt/keyrings/liquorix-keyring.gpg] https://liquorix.net/debian stable main" | tee /etc/apt/sources.list.d/liquorix.list
    fi

    # Hier Platz für zukünftige Paketquellen
    # BEISPIEL: Multimedia-Codecs
    # if [ "${INSTALL_MULTIMEDIA}" = "1" ]; then
    #     echo "Füge Multimedia-Repository hinzu..."
    #     echo "deb http://example.org/multimedia stable main" > /etc/apt/sources.list.d/multimedia.list
    # fi



# Automatische Updates konfigurieren
cat > /etc/apt/apt.conf.d/20auto-upgrades <<AUTOUPDATE
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "${UPDATE_OPTION}";
AUTOUPDATE

# Systemaktualisierung durchführen
echo "Aktualisiere Paketquellen und System..."
apt-get update
apt-get dist-upgrade -y

# Notwendige Pakete installieren 
echo "Installiere Basis-Pakete..."
KERNEL_PACKAGES=""
if [ "${KERNEL_TYPE}" = "standard" ]; then
    KERNEL_PACKAGES="linux-image-generic linux-headers-generic"
elif [ "${KERNEL_TYPE}" = "lowlatency" ]; then
    KERNEL_PACKAGES="linux-image-lowlatency linux-headers-lowlatency"
elif [ "${KERNEL_TYPE}" = "liquorix" ]; then
    KERNEL_PACKAGES="linux-image-liquorix-amd64 linux-headers-liquorix-amd64"    
fi

# Grundlegende Programme und Kernel installieren
apt-get install -y --no-install-recommends \
    \${KERNEL_PACKAGES} \
    shim-signed \
    zram-tools \
    coreutils \
    timeshift \
    bleachbit \
    stacer \
    fastfetch \
    gparted \
    vlc \
    deluge \
    ufw \
    nala \
    jq

# Thorium Browser installieren
if [ "${INSTALL_DESKTOP}" = "1" ] && [ -f /tmp/thorium.deb ]; then
    echo "Thorium-Browser-Paket gefunden, installiere..."
    
    # Installation ohne Download oder CPU-Erkennung
    if dpkg -i /tmp/thorium.deb || apt-get -f install -y; then
        echo "Thorium wurde erfolgreich installiert."
    else
        echo "Thorium-Installation fehlgeschlagen, fahre mit restlicher Installation fort."
    fi
    
    # Aufräumen
    rm -f /tmp/thorium.deb
fi

# Spracheinstellungen
locale-gen ${LOCALE} en_US.UTF-8
update-locale LANG=${LOCALE} LC_CTYPE=${LOCALE}

# Tastaturlayout
if [ -n "${KEYBOARD_LAYOUT}" ]; then
    echo "Setting keyboard layout to ${KEYBOARD_LAYOUT}"
    cat > /etc/default/keyboard <<KEYBOARD
XKBMODEL="pc105"
XKBLAYOUT="${KEYBOARD_LAYOUT}"
XKBVARIANT=""
XKBOPTIONS=""
KEYBOARD
    setupcon
fi

# Hostname setzen
echo "${HOSTNAME}" > /etc/hostname
echo "127.0.1.1 ${HOSTNAME}" >> /etc/hosts

# Netzwerk konfigurieren (systemd-networkd)
mkdir -p /etc/systemd/network

if [ "${NETWORK_CONFIG}" = "static" ]; then
    # Statische IP-Konfiguration anwenden
    echo "Konfiguriere statische IP-Adresse für systemd-networkd..."
    
    # STATIC_IP_CONFIG parsen (Format: interface=eth0,address=192.168.1.100/24,gateway=192.168.1.1,dns=8.8.8.8)
    NET_INTERFACE=\$(echo "${STATIC_IP_CONFIG}" | sed -n 's/.*interface=\([^,]*\).*/\1/p')
    NET_IP=\$(echo "${STATIC_IP_CONFIG}" | sed -n 's/.*address=\([^,]*\).*/\1/p')
    NET_GATEWAY=\$(echo "${STATIC_IP_CONFIG}" | sed -n 's/.*gateway=\([^,]*\).*/\1/p')
    NET_DNS=\$(echo "${STATIC_IP_CONFIG}" | sed -n 's/.*dns=\([^,]*\).*/\1/p')
    
    # Statisches Netzwerk konfigurieren
    cat > /etc/systemd/network/99-static.network <<EON
[Match]
Name=\${NET_INTERFACE}

[Network]
Address=\${NET_IP}
Gateway=\${NET_GATEWAY}
DNS=\${NET_DNS}
EON
else
    # DHCP-Konfiguration
    cat > /etc/systemd/network/99-dhcp.network <<EON
[Match]
Name=en*

[Network]
DHCP=yes
EON
fi

systemctl enable systemd-networkd
systemctl enable systemd-resolved

# GRUB Verzeichnisse vorbereiten
mkdir -p /etc/default/
mkdir -p /etc/default/grub.d/

# GRUB-Konfiguration erstellen
cat > /etc/default/grub <<GRUBCFG
# Autogenerierte GRUB-Konfiguration
GRUB_DEFAULT=0
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=1
GRUB_DISTRIBUTOR="$(. /etc/os-release && echo "$NAME")"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash nomodeset loglevel=3 rd.systemd.show_status=auto rd.udev.log_level=3"
GRUB_CMDLINE_LINUX=""
GRUB_ENABLE_CRYPTODISK=y
GRUB_GFXMODE=1024x768
GRUBCFG

# GRUB Konfigurationsdatei-Rechte setzen
chmod 644 /etc/default/grub

# GRUB Hauptkonfiguration aktualisieren
sed -i 's/GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub

# Initramfs aktualisieren und GRUB installieren
update-initramfs -u -k all
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck
update-grub

# Schlüsseldatei für automatische Entschlüsselung
echo "KEYFILE_PATTERN=/etc/luks/*.keyfile" >> /etc/cryptsetup-initramfs/conf-hook
echo "CRYPTSETUP=y" >> /etc/cryptsetup-initramfs/conf-hook
echo "UMASK=0077" >> /etc/initramfs-tools/initramfs.conf

mkdir -p /etc/luks
dd if=/dev/urandom of=/etc/luks/boot_os.keyfile bs=4096 count=1
chmod -R u=rx,go-rwx /etc/luks
chmod u=r,go-rwx /etc/luks/boot_os.keyfile

# Schlüsseldatei zu LUKS-Volumes hinzufügen
echo -n "${LUKS_PASSWORD}" | cryptsetup luksAddKey ${DEVP}1 /etc/luks/boot_os.keyfile -
echo -n "${LUKS_PASSWORD}" | cryptsetup luksAddKey ${DEVP}5 /etc/luks/boot_os.keyfile -

# Crypttab aktualisieren
echo "${LUKS_BOOT_NAME} UUID=\$(blkid -s UUID -o value ${DEVP}1) /etc/luks/boot_os.keyfile luks,discard" > /etc/crypttab
echo "${LUKS_ROOT_NAME} UUID=\$(blkid -s UUID -o value ${DEVP}5) /etc/luks/boot_os.keyfile luks,discard" >> /etc/crypttab

# zram für Swap konfigurieren
cat > /etc/default/zramswap <<EOZ
# Konfiguration für zramswap
PERCENT=200
ALLOCATION=lz4
EOZ

# Benutzer anlegen
useradd -m -s /bin/bash -G sudo ${USERNAME}
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

# SSH-Server installieren (aber nicht aktivieren)
apt-get install -y openssh-server
# SSH-Server deaktivieren
systemctl disable ssh

# Firewall konfigurieren
apt-get install -y ufw
# GUI nur installieren wenn Desktop
if [ "${INSTALL_DESKTOP}" = "1" ]; then
    apt-get install -y gufw
fi
ufw default deny incoming
ufw default allow outgoing
ufw enable

# Desktop-Umgebung installieren
echo "INSTALL_DESKTOP=${INSTALL_DESKTOP}, DESKTOP_ENV=${DESKTOP_ENV}, DESKTOP_SCOPE=${DESKTOP_SCOPE}" >> /var/log/install.log
if [ "${INSTALL_DESKTOP}" = "1" ]; then
    case "${DESKTOP_ENV}" in
        # GNOME Desktop
        1)
            echo "Installiere GNOME-Desktop-Umgebung..."
            if [ "${DESKTOP_SCOPE}" = "1" ]; then
                # Standard-Installation
                apt-get install -y --no-install-recommends \
                    gnome-session \
                    gnome-shell \
                    gdm3 \
                    gnome-terminal \
                    gnome-text-editor \
                    gnome-tweaks \
                    nautilus \
                    nautilus-hide \
                    ubuntu-gnome-wallpapers \
                    virtualbox-guest-additions-iso \
                    virtualbox-guest-utils \
                    virtualbox-guest-x11
                echo "DEBUG: Desktop-Installation abgeschlossen, exit code: $?" >> /var/log/install-debug.log
            else
                # Minimale Installation
                apt-get install -y --no-install-recommends \
                    gnome-session \
                    gnome-shell \
                    gdm3 \
                    gnome-terminal \
                    gnome-text-editor \
                    gnome-tweaks \
                    nautilus \
                    nautilus-hide \
                    ubuntu-gnome-wallpapers \
                    virtualbox-guest-additions-iso \
                    virtualbox-guest-utils \
                    virtualbox-guest-x11
                echo "DEBUG: Desktop-Installation abgeschlossen, exit code: $?" >> /var/log/install-debug.log
            fi
            ;;
            
        # KDE Plasma Desktop (momentan nur Platzhalter)
        2)
            echo "KDE Plasma wird derzeit noch nicht unterstützt. Installiere GNOME stattdessen..."
            if [ "${DESKTOP_SCOPE}" = "1" ]; then
                apt-get install -y --no-install-recommends \
                    virtualbox-guest-additions-iso \
                    virtualbox-guest-utils \
                    virtualbox-guest-x11
                echo "DEBUG: Desktop-Installation abgeschlossen, exit code: $?" >> /var/log/install-debug.log
            else
                apt-get install -y --no-install-recommends \
                    virtualbox-guest-additions-iso \
                    virtualbox-guest-utils \
                    virtualbox-guest-x11                
                echo "DEBUG: Desktop-Installation abgeschlossen, exit code: $?" >> /var/log/install-debug.log
            fi
            ;;
            
        # Xfce Desktop (momentan nur Platzhalter)
        3)
            echo "Xfce wird derzeit noch nicht unterstützt. Installiere GNOME stattdessen..."
            if [ "${DESKTOP_SCOPE}" = "1" ]; then
                apt-get install -y --no-install-recommends \
                    virtualbox-guest-additions-iso \
                    virtualbox-guest-utils \
                    virtualbox-guest-x11
                echo "DEBUG: Desktop-Installation abgeschlossen, exit code: $?" >> /var/log/install-debug.log
            else
                apt-get install -y --no-install-recommends \
                    virtualbox-guest-additions-iso \
                    virtualbox-guest-utils \
                    virtualbox-guest-x11
                echo "DEBUG: Desktop-Installation abgeschlossen, exit code: $?" >> /var/log/install-debug.log
            fi
            ;;
            
        # Fallback
        *)
            echo "Unbekannte Desktop-Umgebung. Installiere GNOME..."
            # Fallback-Paketliste (GNOME)
            apt-get install -y --no-install-recommends \
                gnome-session \
                gnome-shell \
                gdm3 \
                gnome-terminal \
                gnome-text-editor \
                gnome-tweaks \
                nautilus \
                nautilus-hide \
                ubuntu-gnome-wallpapers \
                virtualbox-guest-additions-iso \
                virtualbox-guest-utils \
                virtualbox-guest-x11
            echo "DEBUG: Desktop-Installation abgeschlossen, exit code: $?" >> /var/log/install-debug.log
            ;;
    esac
fi

# Desktop-Sprachpakete installieren
if [ "${INSTALL_DESKTOP}" = "1" ]; then
    echo "Installiere Sprachpakete für ${UI_LANGUAGE}..."
    
    # Gemeinsame Sprachpakete für alle Desktop-Umgebungen
    apt-get install -y language-pack-${UI_LANGUAGE%_*} language-selector-common
    
    # Desktop-spezifische Sprachpakete
    case "${DESKTOP_ENV}" in
        # GNOME Desktop
        1)
            apt-get install -y language-pack-gnome-${UI_LANGUAGE%_*} language-selector-gnome
            ;;
        # KDE Plasma Desktop
        2)
            apt-get install -y language-pack-kde-${UI_LANGUAGE%_*} kde-l10n-${UI_LANGUAGE%_*} || true
            ;;
        # Xfce Desktop
        3)
            apt-get install -y language-pack-${UI_LANGUAGE%_*}-base xfce4-session-l10n || true
            ;;
    esac
    
    # Default-Sprache für das System setzen
    cat > /etc/default/locale <<LOCALE
LANG=${LOCALE}
LC_MESSAGES=${UI_LANGUAGE}.UTF-8
LOCALE

    # AccountsService-Konfiguration für GDM/Anmeldebildschirm
    if [ -d "/var/lib/AccountsService/users" ]; then
        mkdir -p /var/lib/AccountsService/users/
        for user in /home/*; do
            username=$(basename "$user")
            if [ -d "$user" ] && [ "$username" != "lost+found" ]; then
                echo "[User]" > "/var/lib/AccountsService/users/$username"
                echo "Language=${UI_LANGUAGE}.UTF-8" >> "/var/lib/AccountsService/users/$username"
                echo "XSession=ubuntu" >> "/var/lib/AccountsService/users/$username"
            fi
        done
    fi
fi


# Spezifische Anpassungen für den Desktop

# GNOME Shell Erweiterungen installieren
if [ "${INSTALL_DESKTOP}" = "1" ]; then
    # GNOME Shell Erweiterungen installieren
    echo "Installiere GNOME Shell Erweiterungen..."
    apt-get install -y gnome-shell-extensions chrome-gnome-shell
fi   
    

# Aufräumen
echo "Bereinige temporäre Dateien..."
apt-get clean
apt-get autoremove -y
rm -f /setup.sh
MAINEOF

# Setze Variablen für das Chroot-Skript
sed -i "s/\${HOSTNAME}/$HOSTNAME/g" /mnt/ubuntu/setup.sh
sed -i "s/\${USERNAME}/$USERNAME/g" /mnt/ubuntu/setup.sh
sed -i "s/\${USER_PASSWORD}/$USER_PASSWORD/g" /mnt/ubuntu/setup.sh
sed -i "s/\${LUKS_PASSWORD}/$LUKS_PASSWORD/g" /mnt/ubuntu/setup.sh
sed -i "s|\${DEVP}|$DEVP|g" /mnt/ubuntu/setup.sh
sed -i "s|\${DM}|$DM|g" /mnt/ubuntu/setup.sh
sed -i "s/\${KERNEL_TYPE}/$KERNEL_TYPE/g" /mnt/ubuntu/setup.sh
sed -i "s/\${INSTALL_MODE}/$INSTALL_MODE/g" /mnt/ubuntu/setup.sh
sed -i "s/\${ADDITIONAL_PACKAGES}/$ADDITIONAL_PACKAGES/g" /mnt/ubuntu/setup.sh
sed -i "s/\${UBUNTU_CODENAME}/$UBUNTU_CODENAME/g" /mnt/ubuntu/setup.sh
sed -i "s/\${UPDATE_OPTION}/$UPDATE_OPTION/g" /mnt/ubuntu/setup.sh
sed -i "s/\${INSTALL_DESKTOP}/$INSTALL_DESKTOP/g" /mnt/ubuntu/setup.sh
sed -i "s/\${DESKTOP_ENV}/$DESKTOP_ENV/g" /mnt/ubuntu/setup.sh
sed -i "s/\${DESKTOP_SCOPE}/$DESKTOP_SCOPE/g" /mnt/ubuntu/setup.sh
sed -i "s/\${UI_LANGUAGE}/$UI_LANGUAGE/g" /mnt/ubuntu/setup.sh
sed -i "s/\${LOCALE}/$LOCALE/g" /mnt/ubuntu/setup.sh
sed -i "s/\${KEYBOARD_LAYOUT}/$KEYBOARD_LAYOUT/g" /mnt/ubuntu/setup.sh
sed -i "s/\${TIMEZONE}/$TIMEZONE/g" /mnt/ubuntu/setup.sh
sed -i "s/\${NETWORK_CONFIG}/$NETWORK_CONFIG/g" /mnt/ubuntu/setup.sh
sed -i "s|\${STATIC_IP_CONFIG}|$STATIC_IP_CONFIG|g" /mnt/ubuntu/setup.sh
sed -i "s/\${LUKS_BOOT_NAME}/$LUKS_BOOT_NAME/g" /mnt/ubuntu/setup.sh
sed -i "s/\${LUKS_ROOT_NAME}/$LUKS_ROOT_NAME/g" /mnt/ubuntu/setup.sh

# Ausführbar machen
chmod +x /mnt/ubuntu/setup.sh

show_progress 70
}

execute_chroot() {
log_progress "Führe Installation in chroot-Umgebung durch..."

# chroot ausführen
log_info "Ausführen von setup.sh in chroot..."
chroot /mnt/ubuntu /setup.sh

log_info "Installation in chroot abgeschlossen."
show_progress 90
}

###################
# Abschluss       #
###################
finalize_installation() {
    log_progress "Schließe Installation ab..."
    
    # Speichere Konfiguration, wenn gewünscht
    if [[ $SAVE_CONFIG =~ ^[Jj]$ ]]; then
        read -p "Pfad zum Speichern der Konfiguration [$CONFIG_FILE]: " config_save_path
        save_config "${config_save_path:-$CONFIG_FILE}"
    fi
    
    # Aufräumen
    log_info "Bereinige und beende Installation..."
    umount -R /mnt/ubuntu
    
    log_info "Installation abgeschlossen!"
    log_info "System kann jetzt neu gestartet werden."
    log_info "Hostname: $HOSTNAME"
    log_info "Benutzer: $USERNAME"
    
    show_progress 100
    echo
    
    # Bash-Profile entfernen (Aufräumen)
    rm -f /root/.bash_profile
    log_info "Temporäre SSH-Konfiguration entfernt."

    # Neustart-Abfrage
    read -p "Jetzt neustarten? (j/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Jj]$ ]]; then
        log_info "System wird neu gestartet..."
        reboot
    fi

    # Signal für lokalen Prozess, dass wir fertig sind
    for sem in /tmp/install_done_*; do
        touch "$sem" 2>/dev/null || true
    done
}

###################
# Hauptfunktion   #
###################
main() {
    # Prüfe auf SSH-Verbindung
    if [ "$1" = "ssh_connect" ]; then
        clear
        echo -e "${CYAN}============================================================${NC}"
        echo -e "${CYAN}   UbuntuFDE - Automatisches Installationsskript            ${NC}"
        echo -e "${CYAN}   Version: ${SCRIPT_VERSION}                               ${NC}"
        echo -e "${CYAN}============================================================${NC}"
        echo -e "${GREEN}[INFO]${NC} Neustart der Installation via SSH."
        
        # Lade gespeicherte Einstellungen
        if [ -f /tmp/install_config ]; then
            source /tmp/install_config
        fi
    else
        # Normale Initialisierung
        clear
        echo -e "${CYAN}============================================================${NC}"
        echo -e "${CYAN}   UbuntuFDE - Automatisches Installationsskript            ${NC}"
        echo -e "${CYAN}   Version: ${SCRIPT_VERSION}                               ${NC}"
        echo -e "${CYAN}============================================================${NC}"
        echo
        
        # Logdatei initialisieren
        echo "Ubuntu FDE Installation - $(date)" > "$LOG_FILE"
        
        # Systemcheck
        check_root
        check_system
        check_dependencies
    fi
    
    # Installation
    echo
    echo -e "${CYAN}Starte Installationsprozess...${NC}"
    echo
    
    # Benutzerkonfiguration
    gather_user_input
    
    # Installation durchführen
    prepare_disk
    setup_encryption
    setup_lvm
    mount_filesystems
    install_base_system
    download_thorium
    prepare_chroot
    execute_chroot
    finalize_installation
}

# Skript starten
main "$@"
