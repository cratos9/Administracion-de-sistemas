#Requires -RunAsAdministrator

$SITE_NAME  = "ServidorFTP"
$CERT_DAYS  = 365

function Set-FTP-SSL {
    Write-Output "Verificando IIS FTP"

    $feature = Get-WindowsFeature -Name Web-Ftp-Server -ErrorAction SilentlyContinue
    if ($null -eq $feature -or -not $feature.Installed) {
        Write-Output "Web-Ftp-Server no esta instalado. Instala el servidor FTP antes de configurar SSL."
        return
    }

    $svc = Get-Service -Name ftpsvc -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Output "El servicio ftpsvc no existe."
        return
    }

    Import-Module WebAdministration -ErrorAction Stop

    $site = Get-Website -Name $SITE_NAME -ErrorAction SilentlyContinue
    if (-not $site) {
        Write-Output "El sitio '$SITE_NAME' no existe en IIS. Configura el servidor FTP antes de aplicar SSL."
        return
    }

    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -match "CN=FTP-SSL" } | Select-Object -First 1
    if ($cert) {
        Write-Output "Certificado FTP-SSL ya existe en el store. Reutilizando. Thumbprint: $($cert.Thumbprint)"
    } else {
        $cert = New-SelfSignedCertificate `
            -DnsName "localhost" `
            -CertStoreLocation "Cert:\LocalMachine\My" `
            -Subject "CN=FTP-SSL" `
            -NotAfter (Get-Date).AddDays($CERT_DAYS) `
            -KeyAlgorithm RSA `
            -KeyLength 2048 `
            -HashAlgorithm SHA256
        Write-Output "Certificado autofirmado generado. Thumbprint: $($cert.Thumbprint)"
    }

    $thumbprint = $cert.Thumbprint

    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.ssl.serverCertHash `
        -Value $thumbprint

    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.ssl.serverCertStoreName `
        -Value "My"

    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.ssl.controlChannelPolicy `
        -Value 1

    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.ssl.dataChannelPolicy `
        -Value 1

    Restart-Service ftpsvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    $status = (Get-Service -Name ftpsvc -ErrorAction SilentlyContinue).Status
    Write-Output "SSL FTP configurado en sitio '$SITE_NAME'. Estado ftpsvc: $status"
    Write-Output "Politica canal control : 1 (SSL requerido para usuarios autenticados)"
    Write-Output "Politica canal datos   : 1 (SSL requerido para usuarios autenticados)"
}

function Show-FTP-SSL-Status {
    Write-Output ""
    Write-Output "Estado del certificado FTP SSL"

    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -match "CN=FTP-SSL" } | Select-Object -First 1
    if ($cert) {
        Write-Output "Thumbprint : $($cert.Thumbprint)"
        Write-Output "Sujeto     : $($cert.Subject)"
        Write-Output "Vence      : $($cert.NotAfter)"
    } else {
        Write-Output "No se encontro certificado FTP-SSL en el store."
    }

    Write-Output ""
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    $site = Get-Website -Name $SITE_NAME -ErrorAction SilentlyContinue
    if ($site) {
        $hash = (Get-ItemProperty "IIS:\Sites\$SITE_NAME" -Name ftpServer.security.ssl.serverCertHash -ErrorAction SilentlyContinue).Value
        $ctrl = (Get-ItemProperty "IIS:\Sites\$SITE_NAME" -Name ftpServer.security.ssl.controlChannelPolicy -ErrorAction SilentlyContinue).Value
        $data = (Get-ItemProperty "IIS:\Sites\$SITE_NAME" -Name ftpServer.security.ssl.dataChannelPolicy -ErrorAction SilentlyContinue).Value
        Write-Output "Sitio               : $SITE_NAME"
        Write-Output "Cert hash en sitio  : $hash"
        Write-Output "Control channel     : $ctrl"
        Write-Output "Data channel        : $data"
    } else {
        Write-Output "Sitio '$SITE_NAME' no encontrado."
    }

    Write-Output ""
    $status = (Get-Service -Name ftpsvc -ErrorAction SilentlyContinue).Status
    Write-Output "Estado ftpsvc: $status"
}

while ($true) {
    Write-Output ""
    Write-Output "Gestor SSL - Servidor FTP (IIS)"
    Write-Output "1) Configurar certificado SSL y activar FTPS"
    Write-Output "2) Ver estado del certificado"
    Write-Output "3) Salir"
    $opcion = Read-Host "Opcion"
    switch ($opcion) {
        "1" { Set-FTP-SSL }
        "2" { Show-FTP-SSL-Status }
        "3" { Write-Output "Saliendo."; exit 0 }
        default { Write-Output "Opcion invalida" }
    }
}