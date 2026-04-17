#!/bin/bash

APACHE_PORT=8080
TOMCAT_PORT=8081
NGINX_PORT=8082

TOMCAT_VERSION="10.1.24"
TOMCAT_DIR="/opt/tomcat"
CHOSEN_PORT_RESULT=""

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Ejecuta como sudo"
        exit 1
    fi
}

port_in_use() {
    ss -tlnp | grep -q ":$1 "
}

ask_port() {
    local SERVICE_NAME=$1
    local DEFAULT_PORT=$2
    local PORT

    while true; do
        read -rp "Puerto para ${SERVICE_NAME} [default: ${DEFAULT_PORT}]: " PORT
        PORT=${PORT:-$DEFAULT_PORT}

        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
            echo "Puerto invalido, ingresa un numero entre 1 y 65535"
            continue
        fi

        if port_in_use "$PORT"; then
            echo "El puerto ${PORT} ya esta en uso"
            read -rp "Deseas elegir otro puerto? (s/n): " RETRY
            if [[ "$RETRY" =~ ^[Ss]$ ]]; then
                continue
            else
                echo "Puerto ${PORT} conservado"
                break
            fi
        else
            echo "Puerto ${PORT} disponible"
            break
        fi
    done

    CHOSEN_PORT_RESULT="$PORT"
}

install_apache() {
    if systemctl is-active --quiet apache2; then
        echo "Apache ya estaba instalado y corriendo"
        read -rp "Deseas reinstalarlo? (s/n): " REINSTALL
        if [[ ! "$REINSTALL" =~ ^[Ss]$ ]]; then
            return
        fi
        systemctl stop apache2
    fi

    ask_port "Apache" "$APACHE_PORT"
    APACHE_PORT="$CHOSEN_PORT_RESULT"

    apt-get install -y apache2

    sed -i "s/^Listen [0-9]*/Listen ${APACHE_PORT}/" /etc/apache2/ports.conf

    if [ -f /etc/apache2/sites-enabled/000-default.conf ]; then
        sed -i "s/<VirtualHost \*:[0-9]*>/<VirtualHost *:${APACHE_PORT}>/" /etc/apache2/sites-enabled/000-default.conf
    fi

    systemctl enable apache2
    systemctl restart apache2
    sleep 2

    if systemctl is-active --quiet apache2; then
        echo "Apache instalado y corriendo en puerto ${APACHE_PORT}"
    else
        echo "Apache no pudo iniciar"
    fi
}

install_tomcat() {
    if systemctl is-active --quiet tomcat; then
        echo "Tomcat ya estaba instalado y corriendo"
        read -rp "Deseas reinstalarlo? (s/n): " REINSTALL
        if [[ ! "$REINSTALL" =~ ^[Ss]$ ]]; then
            return
        fi
        systemctl stop tomcat
    fi

    ask_port "Tomcat" "$TOMCAT_PORT"
    TOMCAT_PORT="$CHOSEN_PORT_RESULT"

    apt-get install -y default-jdk wget

    JAVA_BIN=$(readlink -f $(which java))
    JAVA_HOME_PATH=$(dirname $(dirname "$JAVA_BIN"))
    echo "JAVA_HOME detectado: ${JAVA_HOME_PATH}"

    if [ -d "${TOMCAT_DIR}" ]; then
        echo "Limpiando instalacion de Tomcat"
        rm -rf "${TOMCAT_DIR}"
    fi

    if [ -f /etc/systemd/system/tomcat.service ]; then
        systemctl stop tomcat 2>/dev/null
        rm -f /etc/systemd/system/tomcat.service
        systemctl daemon-reload
    fi

    useradd -m -U -d ${TOMCAT_DIR} -s /bin/false tomcat 2>/dev/null || true

    echo "Descargando Tomcat"
    wget -q "https://archive.apache.org/dist/tomcat/tomcat-10/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz" -O /tmp/tomcat.tar.gz

    if [ ! -f /tmp/tomcat.tar.gz ] || [ ! -s /tmp/tomcat.tar.gz ]; then
        echo "Error: la descarga de Tomcat fallo"
        return 1
    fi

    tar -xzf /tmp/tomcat.tar.gz -C /opt/
    EXTRACTED_DIR=$(ls /opt/ | grep "apache-tomcat" | head -1)

    if [ -z "$EXTRACTED_DIR" ]; then
        echo "Error: La extraccion fallo"
        return 1
    fi

    echo "Carpeta extraida: ${EXTRACTED_DIR}"
    mv /opt/${EXTRACTED_DIR} ${TOMCAT_DIR}

    if [ ! -f "${TOMCAT_DIR}/bin/startup.sh" ]; then
        echo "Error: startup.sh no se ha encontrado"
	ls -la ${TOMCAT_DIR}/bin 2>/dev/null || echo "El directorio bin no existe"
	return 1
    fi

    echo "startup.sh encontrado correctamente"

    chown -R tomcat:tomcat ${TOMCAT_DIR}
    chmod +x ${TOMCAT_DIR}/bin/*.sh

    sed -i "s/Connector port=\"[0-9]*\"/Connector port=\"${TOMCAT_PORT}\"/" ${TOMCAT_DIR}/conf/server.xml

    cat > /etc/systemd/system/tomcat.service <<EOF
[Unit]
Description=Apache Tomcat
After=network.target

[Service]
Type=forking
User=tomcat
Group=tomcat
Environment="JAVA_HOME=${JAVA_HOME_PATH}"
Environment="CATALINA_HOME=${TOMCAT_DIR}"
Environment="CATALINA_PID=${TOMCAT_DIR}/temp/tomcat.pid"
ExecStart=${TOMCAT_DIR}/bin/startup.sh
ExecStop=${TOMCAT_DIR}/bin/shutdown.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tomcat
    systemctl start tomcat
    sleep 6

    if systemctl is-active --quiet tomcat; then
        echo "Tomcat instalado y corriendo en puerto ${TOMCAT_PORT}"
    else
        echo "Tomcat no pudo iniciar"
    fi
}

install_nginx() {
    if systemctl is-active --quiet nginx; then
        echo "Nginx ya estaba instalado y corriendo"
        read -rp "Deseas reinstalarlo? (s/n): " REINSTALL
        if [[ ! "$REINSTALL" =~ ^[Ss]$ ]]; then
            return
        fi
        systemctl stop nginx
    fi

    ask_port "Nginx" "$NGINX_PORT"
    NGINX_PORT="$CHOSEN_PORT_RESULT"

    apt-get install -y nginx

    cat > /etc/nginx/sites-available/default <<EOF
server {
    listen ${NGINX_PORT};
    server_name localhost;

    root /var/www/html;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    systemctl enable nginx
    systemctl restart nginx
    sleep 2

    if systemctl is-active --quiet nginx; then
        echo "Nginx instalado y corriendo en puerto ${NGINX_PORT}."
    else
        echo "Nginx no pudo iniciar"
    fi
}

menu_instalar() {
    echo ""
    echo "Selecciona los servicios a instalar:"
    echo "1) Apache"
    echo "2) Tomcat"
    echo "3) Nginx"
    echo "4) Todos"
    echo "5) Volver"
    read -rp "Opcion: " OPT

    apt-get update -y

    case $OPT in
        1) install_apache ;;
        2) install_tomcat ;;
        3) install_nginx ;;
        4)
            install_apache
            install_tomcat
            install_nginx
            ;;
        5) return ;;
        *) echo "Opcion invalida" ;;
    esac
}

get_service_name() {
    echo ""
    echo "Selecciona el servicio:"
    echo "1) Apache"
    echo "2) Tomcat"
    echo "3) Nginx"
    echo "4) Todos"
    read -rp "Opcion: " OPT

    case $OPT in
        1) SELECTED_SERVICE="apache2" ;;
        2) SELECTED_SERVICE="tomcat" ;;
        3) SELECTED_SERVICE="nginx" ;;
        4) SELECTED_SERVICE="all" ;;
        *) SELECTED_SERVICE="invalid" ;;
    esac
}

menu_detener() {
    get_service_name

    if [ "$SELECTED_SERVICE" = "invalid" ]; then
        echo "Opcion invalida"
        return
    fi

    if [ "$SELECTED_SERVICE" = "all" ]; then
        for S in apache2 tomcat nginx; do
            systemctl stop "$S" 2>/dev/null && echo "$S detenido" || echo "$S no estaba activo o no esta instalado"
        done
    else
        systemctl stop "$SELECTED_SERVICE" 2>/dev/null && echo "$SELECTED_SERVICE detenido" || echo "$SELECTED_SERVICE no estaba activo o no esta instalado"
    fi
}

menu_reiniciar() {
    get_service_name

    if [ "$SELECTED_SERVICE" = "invalid" ]; then
        echo "Opcion invalida"
        return
    fi

    if [ "$SELECTED_SERVICE" = "all" ]; then
        for S in apache2 tomcat nginx; do
            systemctl restart "$S" 2>/dev/null && echo "$S reiniciado" || echo "$S no pudo reiniciarse o no esta instalado"
        done
    else
        systemctl restart "$SELECTED_SERVICE" 2>/dev/null && echo "$SELECTED_SERVICE reiniciado" || echo "$SELECTED_SERVICE no pudo reiniciarse o no esta instalado"
    fi
}

menu_estado() {
    echo ""
    echo "Estado de servicios:"
    for SERVICE in apache2 tomcat nginx; do
        STATUS=$(systemctl is-active "$SERVICE" 2>/dev/null)
        echo "${SERVICE}: ${STATUS}"
    done

    echo ""
    echo "Puertos en uso:"
    ss -tlnp | grep -E "${APACHE_PORT}|${TOMCAT_PORT}|${NGINX_PORT}" | sort -u

    echo ""
    echo "Prueba HTTP:"
    for ENTRY in "Apache:${APACHE_PORT}" "Tomcat:${TOMCAT_PORT}" "Nginx:${NGINX_PORT}"; do
        NAME="${ENTRY%%:*}"
        PORT="${ENTRY##*:}"
        CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://localhost:${PORT}/ 2>/dev/null)
        echo "${NAME} (puerto ${PORT}): HTTP ${CODE}"
    done
}

main_menu() {
    check_root

    while true; do
        echo ""
        echo "Servicios HTTP"
        echo "1) Instalar servicios"
        echo "2) Detener servicios"
        echo "3) Reiniciar servicios"
        echo "4) Ver estado y puertos"
        echo "5) Salir"
        read -rp "Opcion: " OPCION

        case $OPCION in
            1) menu_instalar ;;
            2) menu_detener ;;
            3) menu_reiniciar ;;
            4) menu_estado ;;
            5) echo "Saliendo"; exit 0 ;;
            *) echo "Opcion invalida" ;;
        esac
    done
}

main_menu
