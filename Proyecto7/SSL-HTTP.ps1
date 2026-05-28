#Requires -RunAsAdministrator

$SSL_PORT        = 443
$APACHE_SSL_PORT = 8443
$TOMCAT_SSL_PORT = 8444
$CERT_DAYS       = 365
$APACHE_DIR      = "C:\Users\Administrador\AppData\Roaming\Apache24"
$TOMCAT_DIR      = "C:\Tomcat"

function Test-PortInUse {
    param([int]$Port)
    $result = netstat -ano | Select-String ":$Port\s"
    return ($null -ne $result)
}

function Read-Port {
    param([string]$ServiceName, [int]$DefaultPort)
    $selected = $DefaultPort
    while ($true) {
        $input = Read-Host "Puerto SSL para $ServiceName [default: $DefaultPort]"
        if ([string]::IsNullOrWhiteSpace($input)) { $input = "$DefaultPort" }
        if ($input -notmatch '^\d+$' -or [int]$input -lt 1 -or [int]$input -gt 65535) {
            Write-Host "Puerto invalido. Ingresa un numero entre 1 y 65535."
            continue
        }
        $selected = [int]$input
        if (Test-PortInUse $selected) {
            Write-Host "El puerto $selected ya esta en uso."
            $retry = Read-Host "Deseas elegir otro puerto? (s/n)"
            if ($retry -match '^[Ss]$') { continue }
            else { Write-Host "Puerto $selected conservado."; break }
        } else {
            Write-Host "Puerto $selected disponible."
            break
        }
    }
    return $selected
}

function Find-JavaHome {
    $jh = [System.Environment]::GetEnvironmentVariable("JAVA_HOME", "Machine")
    if ($jh -and (Test-Path "$jh\bin\java.exe")) { return $jh }

    $bases = @(
        "C:\Program Files\Eclipse Adoptium",
        "C:\Program Files\Microsoft",
        "C:\Program Files\Java"
    )
    foreach ($base in $bases) {
        if (-not (Test-Path $base)) { continue }
        $found = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
                 Where-Object { Test-Path "$($_.FullName)\bin\java.exe" } |
                 Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Find-Keytool {
    $jh = Find-JavaHome
    if ($jh -and (Test-Path "$jh\bin\keytool.exe")) { return "$jh\bin\keytool.exe" }
    $kt = Get-Command keytool -ErrorAction SilentlyContinue
    if ($kt) { return $kt.Source }
    return $null
}

function Set-JavaEnv {
    $jh = Find-JavaHome
    if (-not $jh) {
        Write-Host "No se encontro Java. Instala Java y vuelve a intentarlo."
        return $false
    }
    $env:JAVA_HOME     = $jh
    $env:JRE_HOME      = $jh
    $env:CATALINA_HOME = $TOMCAT_DIR
    if ($env:PATH -notlike "*$jh\bin*") {
        $env:PATH = "$env:PATH;$jh\bin"
    }
    [System.Environment]::SetEnvironmentVariable("JAVA_HOME", $jh, "Machine")
    $syspath = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
    if ($syspath -notlike "*$jh\bin*") {
        [System.Environment]::SetEnvironmentVariable("PATH", "$syspath;$jh\bin", "Machine")
    }
    return $true
}

function Test-TomcatRunning {
    $procs = Get-Process -Name "java" -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        $cmdline = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue).CommandLine
        if ($cmdline -like "*catalina*" -or $cmdline -like "*tomcat*") { return $true }
    }
    $t = Get-Process -Name "tomcat*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($t) { return $true }
    return $false
}

function Stop-Tomcat {
    Set-JavaEnv | Out-Null
    $shutdownBat = "$TOMCAT_DIR\bin\shutdown.bat"
    if (Test-Path $shutdownBat) {
        Start-Process -FilePath "cmd.exe" `
            -ArgumentList "/c `"$shutdownBat`"" `
            -WorkingDirectory "$TOMCAT_DIR\bin" `
            -Wait -WindowStyle Hidden
        Start-Sleep -Seconds 4
    }
    Get-Process -Name "java" -ErrorAction SilentlyContinue | ForEach-Object {
        $cmdline = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine
        if ($cmdline -like "*catalina*" -or $cmdline -like "*tomcat*") {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

function Start-Tomcat {
    if (-not (Set-JavaEnv)) { return }
    $startupBat = "$TOMCAT_DIR\bin\startup.bat"
    Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c `"$startupBat`"" `
        -WorkingDirectory "$TOMCAT_DIR\bin" `
        -WindowStyle Hidden
    Start-Sleep -Seconds 6
}

function Set-IIS-SSL {
    $feature = Get-WindowsFeature -Name Web-Server -ErrorAction SilentlyContinue
    if ($null -eq $feature -or -not $feature.Installed) {
        Write-Host "IIS no esta instalado."
        return
    }

    $svc = Get-Service -Name W3SVC -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne "Running") {
        Write-Host "El servicio W3SVC no esta corriendo. Inicialo primero."
        return
    }

    $port = [int](Read-Port "IIS SSL" $SSL_PORT)

    Import-Module WebAdministration -ErrorAction Stop

    $cert = Get-ChildItem Cert:\LocalMachine\My |
            Where-Object { $_.Subject -eq "CN=IIS-SSL" } |
            Select-Object -First 1

    if ($cert) {
        Write-Host "Certificado CN=IIS-SSL ya existe. Reutilizando. Thumbprint: $($cert.Thumbprint)"
    } else {
        $cert = New-SelfSignedCertificate `
            -DnsName "localhost" `
            -CertStoreLocation "Cert:\LocalMachine\My" `
            -Subject "CN=IIS-SSL" `
            -NotAfter (Get-Date).AddDays($CERT_DAYS) `
            -KeyAlgorithm RSA `
            -KeyLength 2048 `
            -HashAlgorithm SHA256
        Write-Host "Certificado generado. Thumbprint: $($cert.Thumbprint)"
    }

    $existingBindings = Get-WebBinding -Name "Default Web Site" -Protocol "https" -ErrorAction SilentlyContinue
    foreach ($b in $existingBindings) { $b.Delete() }
    if ($existingBindings) { Write-Host "Bindings HTTPS anteriores eliminados." }

    New-WebBinding -Name "Default Web Site" -Protocol "https" -Port $port -IPAddress "*" -SslFlags 0

    $binding = Get-WebBinding -Name "Default Web Site" -Protocol "https" -Port $port -ErrorAction SilentlyContinue
    if (-not $binding) {
        Write-Host "Error: no se pudo crear el binding HTTPS en puerto $port."
        return
    }

    $binding.AddSslCertificate($cert.Thumbprint, "My")
    Write-Host "Certificado asignado al binding HTTPS puerto $port."

    Restart-Service W3SVC -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    $status = (Get-Service -Name W3SVC -ErrorAction SilentlyContinue).Status
    Write-Host "IIS SSL configurado en puerto $port. Estado W3SVC: $status"
}

function Show-IIS-SSL-Status {
    Write-Host ""
    Write-Host "Estado IIS SSL"

    Import-Module WebAdministration -ErrorAction SilentlyContinue
    $bindings = Get-WebBinding -Name "Default Web Site" -Protocol "https" -ErrorAction SilentlyContinue
    if ($bindings) {
        foreach ($b in $bindings) { Write-Host "Binding: $($b.bindingInformation)" }
    } else {
        Write-Host "No hay bindings HTTPS en Default Web Site."
    }

    Write-Host ""
    Write-Host "Certificados CN=IIS-SSL en store:"
    Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.Subject -eq "CN=IIS-SSL" } |
        ForEach-Object { Write-Host "Thumbprint: $($_.Thumbprint) | Vence: $($_.NotAfter)" }

    Write-Host ""
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    try {
        $r = Invoke-WebRequest -Uri "https://localhost:$SSL_PORT/" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        Write-Host "IIS HTTPS (puerto $SSL_PORT): HTTP $($r.StatusCode)"
    } catch {
        Write-Host "IIS HTTPS (puerto $SSL_PORT): sin respuesta"
    }
}

function Set-Apache-SSL {
    if (-not (Test-Path "$APACHE_DIR\bin\httpd.exe")) {
        Write-Host "Apache no encontrado en $APACHE_DIR. Instala Apache primero."
        return
    }

    $svc = Get-Service -Name "Apache24" -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne "Running") {
        Write-Host "El servicio Apache24 no esta corriendo. Inicialo primero."
        return
    }

    $port = [int](Read-Port "Apache SSL" $APACHE_SSL_PORT)

    $opensslExe = "$APACHE_DIR\bin\openssl.exe"
    if (-not (Test-Path $opensslExe)) {
        Write-Host "openssl.exe no encontrado en $APACHE_DIR\bin\."
        return
    }

    $certDir  = "$APACHE_DIR\conf\ssl"
    $certFile = "$certDir\server.crt"
    $keyFile  = "$certDir\server.key"

    New-Item -ItemType Directory -Path $certDir -Force | Out-Null

    if ((Test-Path $certFile) -and (Test-Path $keyFile)) {
        Write-Host "Certificado Apache ya existe. Reutilizando."
    } else {
        & $opensslExe req -x509 -nodes -newkey rsa:2048 `
            -keyout $keyFile `
            -out $certFile `
            -days $CERT_DAYS `
            -subj "/C=MX/ST=Estado/L=Ciudad/O=ServidorHTTP/CN=localhost" 2>$null

        if (-not (Test-Path $certFile)) {
            Write-Host "Error al generar el certificado."
            return
        }
        Write-Host "Certificado autofirmado generado en $certDir."
    }

    $confPath     = "$APACHE_DIR\conf\httpd.conf"
    $vhostFile    = "$APACHE_DIR\conf\extra\httpd-ssl-custom.conf"
    $certSlash    = $certFile -replace "\\", "/"
    $keySlash     = $keyFile  -replace "\\", "/"
    $docRootSlash = ("$APACHE_DIR\htdocs") -replace "\\", "/"

    $conf = Get-Content $confPath -Raw

    if ($conf -match "#\s*LoadModule ssl_module") {
        $conf = $conf -replace "#\s*LoadModule ssl_module", "LoadModule ssl_module"
    } elseif ($conf -notmatch "LoadModule ssl_module") {
        $conf += "`nLoadModule ssl_module modules/mod_ssl.so"
    }

    if ($conf -match "#\s*LoadModule socache_shmcb_module") {
        $conf = $conf -replace "#\s*LoadModule socache_shmcb_module", "LoadModule socache_shmcb_module"
    } elseif ($conf -notmatch "LoadModule socache_shmcb_module") {
        $conf += "`nLoadModule socache_shmcb_module modules/mod_socache_shmcb.so"
    }

    if ($conf -notmatch "Listen $port") {
        $conf += "`nListen $port"
    }

    if ($conf -notmatch "httpd-ssl-custom\.conf") {
        $conf += "`nInclude conf/extra/httpd-ssl-custom.conf"
    }

    Set-Content -Path $confPath -Value $conf -Encoding Ascii

    $vhostBlock = @"
<VirtualHost *:$port>
    ServerName localhost:$port
    SSLEngine on
    SSLCertificateFile "$certSlash"
    SSLCertificateKeyFile "$keySlash"
    DocumentRoot "$docRootSlash"
    <Directory "$docRootSlash">
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>
"@
    Set-Content -Path $vhostFile -Value $vhostBlock -Encoding Ascii

    $test = & "$APACHE_DIR\bin\httpd.exe" -t 2>&1
    if ($test -match "Syntax OK") {
        Write-Host "Configuracion de Apache valida."
        Restart-Service Apache24 -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        $status = (Get-Service -Name "Apache24" -ErrorAction SilentlyContinue).Status
        Write-Host "Apache SSL configurado en puerto $port. Estado Apache24: $status"
    } else {
        Write-Host "Error en la configuracion de Apache:"
        Write-Host $test
    }
}

function Show-Apache-SSL-Status {
    Write-Host ""
    Write-Host "Estado Apache SSL"

    if (-not (Test-Path "$APACHE_DIR\bin\httpd.exe")) {
        Write-Host "Apache no encontrado en $APACHE_DIR."
        return
    }

    $certFile = "$APACHE_DIR\conf\ssl\server.crt"
    if (Test-Path $certFile) {
        $opensslExe = "$APACHE_DIR\bin\openssl.exe"
        if (Test-Path $opensslExe) {
            $subject = & $opensslExe x509 -noout -subject -in $certFile 2>$null
            $expiry  = & $opensslExe x509 -noout -enddate -in $certFile 2>$null
            Write-Host $subject
            Write-Host $expiry
        } else {
            Write-Host "Certificado encontrado: $certFile"
        }
    } else {
        Write-Host "No hay certificado en $APACHE_DIR\conf\ssl\"
    }

    Write-Host ""
    $svc = Get-Service -Name "Apache24" -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "Servicio Apache24: $($svc.Status)"
    } else {
        Write-Host "Servicio Apache24 no encontrado."
    }

    Write-Host ""
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    try {
        $r = Invoke-WebRequest -Uri "https://localhost:$APACHE_SSL_PORT/" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        Write-Host "Apache HTTPS (puerto $APACHE_SSL_PORT): HTTP $($r.StatusCode)"
    } catch {
        Write-Host "Apache HTTPS (puerto $APACHE_SSL_PORT): sin respuesta"
    }
}

function Set-Tomcat-SSL {
    if (-not (Test-Path "$TOMCAT_DIR\bin\startup.bat")) {
        Write-Host "Tomcat no encontrado en $TOMCAT_DIR. Instala Tomcat primero."
        return
    }

    if (-not (Test-TomcatRunning)) {
        Write-Host "Tomcat no esta corriendo. Inicialo primero con startup.bat."
        return
    }

    $port = [int](Read-Port "Tomcat SSL" $TOMCAT_SSL_PORT)

    $keytool = Find-Keytool
    if (-not $keytool) {
        Write-Host "keytool.exe no encontrado. Asegurate de que Java este instalado."
        return
    }

    $keystoreDir  = "$TOMCAT_DIR\conf\ssl"
    $keystorePath = "$keystoreDir\keystore.jks"

    New-Item -ItemType Directory -Path $keystoreDir -Force | Out-Null

    if (Test-Path $keystorePath) {
        Write-Host "Keystore de Tomcat ya existe. Reutilizando."
    } else {
        & $keytool -genkeypair `
            -alias tomcat `
            -keyalg RSA `
            -keysize 2048 `
            -validity $CERT_DAYS `
            -keystore $keystorePath `
            -storepass changeit `
            -keypass changeit `
            -dname "CN=localhost, OU=Servidor, O=Servidor, L=Ciudad, ST=Estado, C=MX" 2>$null

        if (-not (Test-Path $keystorePath)) {
            Write-Host "Error al generar el keystore JKS."
            return
        }
        Write-Host "Keystore JKS generado en $keystorePath."
    }

    $serverXml     = "$TOMCAT_DIR\conf\server.xml"
    $keystoreSlash = $keystorePath -replace "\\", "/"

    [xml]$xml = Get-Content $serverXml -Encoding UTF8

    $existingConnector = $xml.Server.Service.Connector |
                         Where-Object { $_.SSLEnabled -eq "true" } |
                         Select-Object -First 1

    if ($existingConnector) {
        Write-Host "Conector HTTPS ya existe en server.xml. Eliminando para reemplazar."
        $existingConnector.ParentNode.RemoveChild($existingConnector) | Out-Null
    }

    $service = $xml.Server.Service | Select-Object -First 1

    $newConn = $xml.CreateElement("Connector")
    $newConn.SetAttribute("port",       "$port")
    $newConn.SetAttribute("protocol",   "org.apache.coyote.http11.Http11NioProtocol")
    $newConn.SetAttribute("SSLEnabled", "true")
    $newConn.SetAttribute("maxThreads", "150")
    $newConn.SetAttribute("scheme",     "https")
    $newConn.SetAttribute("secure",     "true")

    $sslHostConfig = $xml.CreateElement("SSLHostConfig")

    $certificate = $xml.CreateElement("Certificate")
    $certificate.SetAttribute("certificateKeystoreFile",     "$keystoreSlash")
    $certificate.SetAttribute("certificateKeystorePassword", "changeit")
    $certificate.SetAttribute("type",                        "RSA")

    $sslHostConfig.AppendChild($certificate) | Out-Null
    $newConn.AppendChild($sslHostConfig)     | Out-Null
    $service.AppendChild($newConn)           | Out-Null

    $xml.Save($serverXml)
    Write-Host "server.xml actualizado."

    Write-Host "Reiniciando Tomcat..."
    Stop-Tomcat
    Start-Tomcat

    if (Test-TomcatRunning) {
        Write-Host "Tomcat SSL configurado en puerto $port. Tomcat: corriendo."
    } else {
        Write-Host "Tomcat no pudo reiniciar. Revisa $TOMCAT_DIR\logs\"
    }
}

function Show-Tomcat-SSL-Status {
    Write-Host ""
    Write-Host "Estado Tomcat SSL"

    if (-not (Test-Path "$TOMCAT_DIR\bin\startup.bat")) {
        Write-Host "Tomcat no encontrado en $TOMCAT_DIR."
        return
    }

    $keystorePath = "$TOMCAT_DIR\conf\ssl\keystore.jks"
    if (Test-Path $keystorePath) {
        $keytool = Find-Keytool
        if ($keytool) {
            $info = & $keytool -list -v -keystore $keystorePath -storepass changeit 2>$null |
                    Select-String "Valid from|Owner"
            foreach ($line in $info) { Write-Host $line }
        } else {
            Write-Host "Keystore encontrado: $keystorePath"
        }
    } else {
        Write-Host "No hay keystore en $TOMCAT_DIR\conf\ssl\"
    }

    Write-Host ""
    if (Test-TomcatRunning) {
        Write-Host "Tomcat: corriendo"
    } else {
        Write-Host "Tomcat: detenido"
    }

    Write-Host ""
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    try {
        $r = Invoke-WebRequest -Uri "https://localhost:$TOMCAT_SSL_PORT/" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        Write-Host "Tomcat HTTPS (puerto $TOMCAT_SSL_PORT): HTTP $($r.StatusCode)"
    } catch {
        Write-Host "Tomcat HTTPS (puerto $TOMCAT_SSL_PORT): sin respuesta"
    }
}

function menu_instalar_ssl {
    Write-Host ""
    Write-Host "Selecciona el servicio a configurar SSL:"
    Write-Host "1) IIS"
    Write-Host "2) Apache"
    Write-Host "3) Tomcat"
    Write-Host "4) Todos"
    $opcion = Read-Host "Opcion"
    switch ($opcion) {
        "1" { Set-IIS-SSL }
        "2" { Set-Apache-SSL }
        "3" { Set-Tomcat-SSL }
        "4" {
            Set-IIS-SSL
            Set-Apache-SSL
            Set-Tomcat-SSL
        }
        default { Write-Host "Opcion invalida." }
    }
}

function menu_estado_ssl {
    Write-Host ""
    Write-Host "Selecciona el servicio a consultar:"
    Write-Host "1) IIS"
    Write-Host "2) Apache"
    Write-Host "3) Tomcat"
    Write-Host "4) Todos"
    $opcion = Read-Host "Opcion"
    switch ($opcion) {
        "1" { Show-IIS-SSL-Status }
        "2" { Show-Apache-SSL-Status }
        "3" { Show-Tomcat-SSL-Status }
        "4" {
            Show-IIS-SSL-Status
            Show-Apache-SSL-Status
            Show-Tomcat-SSL-Status
        }
        default { Write-Host "Opcion invalida." }
    }
}

while ($true) {
    Write-Host ""
    Write-Host "Gestor SSL - Servidores HTTP"
    Write-Host "1) Configurar SSL"
    Write-Host "2) Ver estado SSL"
    Write-Host "3) Salir"
    $opcion = Read-Host "Opcion"
    switch ($opcion) {
        "1" { menu_instalar_ssl }
        "2" { menu_estado_ssl }
        "3" { Write-Host "Saliendo."; exit 0 }
        default { Write-Host "Opcion invalida." }
    }
}