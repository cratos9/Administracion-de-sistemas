#!/bin/bash

APACHE_SSL_PORT=8443
TOMCAT_SSL_PORT=8444
NGINX_SSL_PORT=8445
TOMCAT_DIR="/opt/tomcat"
SSL_DIR="/etc/ssl/servidores"
CERT_DAYS=365
CHOSEN_PORT_RESULT=""

check_root() {
if [ "$(id -u)" -ne 0 ]; then
echo "Ejecuta este script como root o con sudo."
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
read -rp "Puerto SSL para ${SERVICE_NAME} [default: ${DEFAULT_PORT}]: " PORT
PORT=${PORT:-$DEFAULT_PORT}

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
echo "Puerto invalido. Ingresa un numero entre 1 y 65535."
continue
fi

if port_in_use "$PORT"; then
echo "El puerto ${PORT} ya esta en uso."
read -rp "Deseas elegir otro puerto? (s/n): " RETRY
if [[ "$RETRY" =~ ^[Ss]$ ]]; then
continue
else
echo "Puerto ${PORT} conservado."
break
fi
else
echo "Puerto ${PORT} disponible."
break
fi
done

CHOSEN_PORT_RESULT="$PORT"
}

generar_cert() {
local SERVICIO=$1
local CERT_PATH="${SSL_DIR}/${SERVICIO}"
mkdir -p "$CERT_PATH"

if [ -f "${CERT_PATH}/cert.pem" ] && [ -f "${CERT_PATH}/key.pem" ]; then
echo "Certificado para ${SERVICIO} ya existe. Reutilizando."
return
fi

openssl req -x509 -nodes -newkey rsa:2048 \
-keyout "${CERT_PATH}/key.pem" \
-out "${CERT_PATH}/cert.pem" \
-days "$CERT_DAYS" \
-subj "/C=MX/ST=Estado/L=Ciudad/O=Servidor/CN=${SERVICIO}" 2>/dev/null

echo "Certificado autofirmado generado para ${SERVICIO}."
}

ssl_apache() {
if ! systemctl is-active --quiet apache2; then
echo "Apache no esta corriendo. Instala y levanta Apache antes de configurar SSL."
return 1
fi

ask_port "Apache SSL" "$APACHE_SSL_PORT"
APACHE_SSL_PORT="$CHOSEN_PORT_RESULT"

generar_cert "apache"

a2enmod ssl 2>/dev/null
a2enmod headers 2>/dev/null

CERT_PATH="${SSL_DIR}/apache"

cat > /etc/apache2/sites-available/ssl-default.conf <<EOF
<VirtualHost *:${APACHE_SSL_PORT}>
ServerName localhost
SSLEngine on
SSLCertificateFile ${CERT_PATH}/cert.pem
SSLCertificateKeyFile ${CERT_PATH}/key.pem
DocumentRoot /var/www/html
<Directory /var/www/html>
Options Indexes FollowSymLinks
AllowOverride None
Require all granted
</Directory>
</VirtualHost>
EOF

if ! grep -q "^Listen ${APACHE_SSL_PORT}" /etc/apache2/ports.conf; then
echo "Listen ${APACHE_SSL_PORT}" >> /etc/apache2/ports.conf
fi

a2ensite ssl-default.conf 2>/dev/null

apache2ctl configtest 2>&1 | grep -v "^Syntax OK" || true
if apache2ctl configtest 2>&1 | grep -q "Syntax OK"; then
systemctl restart apache2
sleep 2
if systemctl is-active --quiet apache2; then
echo "Apache SSL configurado en puerto ${APACHE_SSL_PORT}."
else
echo "Apache no pudo reiniciar. Revisa: journalctl -xeu apache2.service"
fi
else
echo "Error en configuracion de Apache. Revisa /etc/apache2/sites-available/ssl-default.conf"
fi
}

ssl_tomcat() {
if [ ! -d "$TOMCAT_DIR" ]; then
echo "Tomcat no esta instalado en ${TOMCAT_DIR}."
return 1
fi

ask_port "Tomcat SSL" "$TOMCAT_SSL_PORT"
TOMCAT_SSL_PORT="$CHOSEN_PORT_RESULT"

KEYSTORE_PATH="${SSL_DIR}/tomcat/keystore.jks"
mkdir -p "${SSL_DIR}/tomcat"

if [ -f "$KEYSTORE_PATH" ]; then
echo "Keystore de Tomcat ya existe. Reutilizando."
else
JAVA_BIN=$(readlink -f $(which java))
JAVA_HOME_PATH=$(dirname $(dirname "$JAVA_BIN"))
KEYTOOL="${JAVA_HOME_PATH}/bin/keytool"

"$KEYTOOL" -genkeypair \
-alias tomcat \
-keyalg RSA \
-keysize 2048 \
-validity "$CERT_DAYS" \
-keystore "$KEYSTORE_PATH" \
-storepass changeit \
-keypass changeit \
-dname "CN=localhost, OU=Servidor, O=Servidor, L=Ciudad, ST=Estado, C=MX" 2>/dev/null

echo "Keystore JKS generado para Tomcat."
fi

SERVER_XML="${TOMCAT_DIR}/conf/server.xml"

if grep -q "SSLEnabled=\"true\"" "$SERVER_XML"; then
echo "Conector HTTPS ya existe en server.xml. Actualizando puerto."
sed -i "s/port=\"[0-9]*\" protocol=\"org.apache.coyote.http11.Http11NioProtocol\" SSLEnabled=\"true\"/port=\"${TOMCAT_SSL_PORT}\" protocol=\"org.apache.coyote.http11.Http11NioProtocol\" SSLEnabled=\"true\"/" "$SERVER_XML"
else
sed -i "/<\/Service>/i\\
    <Connector port=\"${TOMCAT_SSL_PORT}\" protocol=\"org.apache.coyote.http11.Http11NioProtocol\"\\
               SSLEnabled=\"true\" maxThreads=\"150\" scheme=\"https\" secure=\"true\"\\
               keystoreFile=\"${KEYSTORE_PATH}\" keystorePass=\"changeit\"\\
               clientAuth=\"false\" sslProtocol=\"TLS\" />" "$SERVER_XML"
fi

chown tomcat:tomcat "$KEYSTORE_PATH"

systemctl restart tomcat
sleep 3

if systemctl is-active --quiet tomcat; then
echo "Tomcat SSL configurado en puerto ${TOMCAT_SSL_PORT}."
else
echo "Tomcat no pudo reiniciar. Revisa: journalctl -xeu tomcat.service"
fi
}

ssl_nginx() {
if ! systemctl is-active --quiet nginx; then
echo "Nginx no esta corriendo. Instala y levanta Nginx antes de configurar SSL."
return 1
fi

ask_port "Nginx SSL" "$NGINX_SSL_PORT"
NGINX_SSL_PORT="$CHOSEN_PORT_RESULT"

generar_cert "nginx"

CERT_PATH="${SSL_DIR}/nginx"

cat > /etc/nginx/sites-available/ssl-default <<EOF
server {
    listen ${NGINX_SSL_PORT} ssl;
    server_name localhost;

    ssl_certificate     ${CERT_PATH}/cert.pem;
    ssl_certificate_key ${CERT_PATH}/key.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    root /var/www/html;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

ln -sf /etc/nginx/sites-available/ssl-default /etc/nginx/sites-enabled/ssl-default

nginx -t 2>&1 | grep -v "^nginx:" || true
if nginx -t 2>&1 | grep -q "successful"; then
systemctl restart nginx
sleep 2
if systemctl is-active --quiet nginx; then
echo "Nginx SSL configurado en puerto ${NGINX_SSL_PORT}."
else
echo "Nginx no pudo reiniciar. Revisa: journalctl -xeu nginx.service"
fi
else
echo "Error en configuracion de Nginx. Revisa /etc/nginx/sites-available/ssl-default"
fi
}

menu_estado_ssl() {
echo ""
echo "--- Estado SSL ---"
for ENTRY in "Apache:${APACHE_SSL_PORT}" "Tomcat:${TOMCAT_SSL_PORT}" "Nginx:${NGINX_SSL_PORT}"; do
NAME="${ENTRY%%:*}"
PORT="${ENTRY##*:}"
CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 3 https://localhost:${PORT}/ 2>/dev/null)
echo "${NAME} SSL (puerto ${PORT}): HTTPS ${CODE}"
done

echo ""
echo "--- Certificados ---"
for SERVICIO in apache nginx; do
CERT="${SSL_DIR}/${SERVICIO}/cert.pem"
if [ -f "$CERT" ]; then
EXPIRY=$(openssl x509 -noout -enddate -in "$CERT" 2>/dev/null | cut -d= -f2)
echo "${SERVICIO}: vence ${EXPIRY}"
else
echo "${SERVICIO}: sin certificado"
fi
done

TOMCAT_KS="${SSL_DIR}/tomcat/keystore.jks"
if [ -f "$TOMCAT_KS" ]; then
JAVA_BIN=$(readlink -f $(which java))
JAVA_HOME_PATH=$(dirname $(dirname "$JAVA_BIN"))
KEYTOOL="${JAVA_HOME_PATH}/bin/keytool"
EXPIRY=$("$KEYTOOL" -list -v -keystore "$TOMCAT_KS" -storepass changeit 2>/dev/null | grep "Valid from" | head -1)
echo "tomcat: ${EXPIRY}"
else
echo "tomcat: sin keystore"
fi
}

menu_instalar_ssl() {
echo ""
echo "Selecciona el servicio a configurar SSL:"
echo "1) Apache"
echo "2) Tomcat"
echo "3) Nginx"
echo "4) Todos"
read -rp "Opcion: " OPCION

apt-get install -y openssl 2>/dev/null
mkdir -p "$SSL_DIR"

case $OPCION in
1) ssl_apache ;;
2) ssl_tomcat ;;
3) ssl_nginx ;;
4)
ssl_apache
ssl_tomcat
ssl_nginx
;;
*) echo "Opcion invalida." ;;
esac
}

main_menu() {
check_root

while true; do
echo ""
echo "Gestor SSL - Servidores HTTP"
echo "1) Configurar SSL"
echo "2) Ver estado SSL"
echo "3) Salir"
read -rp "Opcion: " OPCION

case $OPCION in
1) menu_instalar_ssl ;;
2) menu_estado_ssl ;;
3) echo "Saliendo."; exit 0 ;;
*) echo "Opcion invalida." ;;
esac
done
}

main_menu