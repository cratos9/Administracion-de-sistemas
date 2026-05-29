#!/bin/bash

set -euo pipefail

DOMAIN="PRACTICA.LOCAL"
DC_IP="192.168.60.100"
NM_CONNECTION="netplan-ens33"
AD_USER="Administrator"
LOG_FILE="/var/log/ad-join.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() {
    local TYPE="$1"; shift
    local MSG="$*"
    local TS
    TS=$(date '+%Y-%m-%d %H:%M:%S')
    case "$TYPE" in
        INFO)    echo -e "${CYAN}[$TS] [INFO]    $MSG${NC}" | tee -a "$LOG_FILE" ;;
        SUCCESS) echo -e "${GREEN}[$TS] [OK]     $MSG${NC}" | tee -a "$LOG_FILE" ;;
        WARNING) echo -e "${YELLOW}[$TS] [WARN]   $MSG${NC}" | tee -a "$LOG_FILE" ;;
        ERROR)   echo -e "${RED}[$TS] [ERROR]  $MSG${NC}" | tee -a "$LOG_FILE" ;;
        HEADER)  echo -e "${BOLD}${CYAN}\n══════════════════════════════════════════\n  $MSG\n══════════════════════════════════════════${NC}" | tee -a "$LOG_FILE" ;;
    esac
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR] Este script debe ejecutarse como root: sudo bash $0${NC}"
        exit 1
    fi
}

pause_check() {
    local MSG="$1"
    log INFO "$MSG"
    sleep 2
}

check_root
touch "$LOG_FILE"
log HEADER "UNIÓN DE UBUNTU AL DOMINIO $DOMAIN"
log INFO "Log guardado en: $LOG_FILE"

log HEADER "FASE 1 — Instalación de paquetes necesarios"

PACKAGES=(
    realmd
    sssd
    sssd-tools
    sssd-ad
    libnss-sss
    libpam-sss
    adcli
    samba-common-bin
    krb5-user
    packagekit
    ntp
)

log INFO "Actualizando lista de paquetes..."
apt-get update -qq >> "$LOG_FILE" 2>&1

log INFO "Instalando paquetes de integración con AD..."
DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}" >> "$LOG_FILE" 2>&1

log SUCCESS "Paquetes instalados correctamente."

log HEADER "FASE 2 — Configuración de DNS hacia el Domain Controller"

log INFO "Aplicando DNS $DC_IP a la conexión '$NM_CONNECTION'..."
nmcli con mod "$NM_CONNECTION" ipv4.dns "$DC_IP"
nmcli con mod "$NM_CONNECTION" ipv4.ignore-auto-dns yes

log INFO "Reiniciando la conexión de red..."
nmcli con down "$NM_CONNECTION" >> "$LOG_FILE" 2>&1 || true
nmcli con up   "$NM_CONNECTION" >> "$LOG_FILE" 2>&1

pause_check "Esperando que la interfaz levante..."

DNS_CHECK=$(resolvectl status 2>/dev/null | grep -A8 "ens33" | grep "Current DNS Server" || true)
if echo "$DNS_CHECK" | grep -q "$DC_IP"; then
    log SUCCESS "DNS configurado correctamente: $DC_IP"
else
    log WARNING "No se pudo confirmar el DNS. Verificar manualmente con: resolvectl status"
fi

log HEADER "FASE 3 — Validación de resolución DNS del dominio"

log INFO "Realizando nslookup del dominio $DOMAIN..."
if nslookup "$DOMAIN" >> "$LOG_FILE" 2>&1; then
    log SUCCESS "Resolución DNS de $DOMAIN exitosa."
else
    log ERROR "No se pudo resolver $DOMAIN. Verificar conectividad con el DC ($DC_IP)."
    exit 1
fi

log HEADER "FASE 4 — Descubrimiento del Domain Controller"

log INFO "Ejecutando realm discover $DOMAIN..."
if realm discover "$DOMAIN" 2>&1 | tee -a "$LOG_FILE"; then
    log SUCCESS "Dominio $DOMAIN descubierto correctamente."
else
    log ERROR "No se pudo descubrir el dominio. Verificar conectividad y DNS."
    exit 1
fi

log HEADER "FASE 5 — Sincronización de tiempo con el DC"

log INFO "Configurando NTP hacia el DC ($DC_IP)..."

NTP_CONF="/etc/ntp.conf"
if [[ -f "$NTP_CONF" ]]; then
    cp "$NTP_CONF" "${NTP_CONF}.bak"
    sed -i "/^server /d" "$NTP_CONF"
    echo "server $DC_IP iburst" >> "$NTP_CONF"
    systemctl restart ntp >> "$LOG_FILE" 2>&1 || true
fi

timedatectl set-ntp true >> "$LOG_FILE" 2>&1 || true

sleep 3
NTP_STATUS=$(timedatectl | grep "System clock synchronized" || true)
log INFO "Estado NTP: $NTP_STATUS"
log SUCCESS "Tiempo configurado. Zona horaria actual: $(timedatectl | grep 'Time zone' | awk '{print $3}')"

log HEADER "FASE 6 — Unión al dominio $DOMAIN"
log INFO "Se solicitará la contraseña del usuario AD: $AD_USER"
echo ""

if realm join --user="$AD_USER" "$DOMAIN" 2>&1 | tee -a "$LOG_FILE"; then
    log SUCCESS "¡El equipo se unió exitosamente al dominio $DOMAIN!"
else
    log ERROR "Falló la unión al dominio. Revisar credenciales o conectividad."
    exit 1
fi

log HEADER "FASE 7 — Configuración post-unión (PAM / SSSD)"

log INFO "Habilitando creación automática de directorios home..."
pam-auth-update --enable mkhomedir >> "$LOG_FILE" 2>&1
log SUCCESS "mkhomedir habilitado."

SSSD_CONF="/etc/sssd/sssd.conf"
if [[ -f "$SSSD_CONF" ]]; then
    log INFO "Ajustando configuración de SSSD..."
    if ! grep -q "use_fully_qualified_names" "$SSSD_CONF"; then
        sed -i "/\[domain\/$DOMAIN\]/a use_fully_qualified_names = True\nfallback_homedir = /home/%u@%d" "$SSSD_CONF" 2>/dev/null || true
    fi
    chmod 600 "$SSSD_CONF"
    systemctl restart sssd >> "$LOG_FILE" 2>&1
    log SUCCESS "SSSD reiniciado correctamente."
fi

log HEADER "FASE 8 — Validación de la unión al dominio"

log INFO "Listando realm configurado..."
realm list 2>&1 | tee -a "$LOG_FILE"

echo ""
log INFO "Verificando usuarios del dominio (Linux OU)..."
id "mlopez01@practica.local"  >> "$LOG_FILE" 2>&1 && log SUCCESS "Usuario mlopez01 resuelto correctamente." || log WARNING "mlopez01 no encontrado aún (puede tardar unos segundos)."
id "fsolis01@practica.local"  >> "$LOG_FILE" 2>&1 && log SUCCESS "Usuario fsolis01 resuelto correctamente." || log WARNING "fsolis01 no encontrado aún."

log HEADER "CONFIGURACIÓN COMPLETADA"
echo -e "${BOLD}${GREEN}"
echo "  Dominio      : $DOMAIN"
echo "  DC / DNS     : $DC_IP"
echo "  Estado realm : $(realm list 2>/dev/null | grep 'configured' | awk '{print $2}')"
echo ""
echo "  Usuarios del dominio disponibles para login:"
echo "    mlopez01@PRACTICA.LOCAL   (OU Linux)"
echo "    fsolis01@PRACTICA.LOCAL   (OU Linux)"
echo ""
echo "  Para cambiar de usuario usa:"
echo "    su - mlopez01@PRACTICA.LOCAL"
echo "    su - fsolis01@PRACTICA.LOCAL"
echo -e "${NC}"
log SUCCESS "Script finalizado. Log completo en: $LOG_FILE"
