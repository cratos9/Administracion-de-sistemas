#Requires -RunAsAdministrator

$FTP_ROOT    = "C:\inetpub\ftp"
$SHARED_ROOT = "C:\inetpub\ftp\_shared"
$PUBLIC_ROOT = "C:\inetpub\ftp\LocalUser\Public"
$HOST_ROOT   = "C:\inetpub\ftp\$env:COMPUTERNAME"
$SITE_NAME   = "ServidorFTP"
$SITE_PORT   = 21
$GRUPOS      = @("reprobados", "recursadores")

function Instalar-IIS-FTP {
    echo "=== Instalacion de IIS y FTP ==="
    foreach ($f in @("Web-Server","Web-Ftp-Server","Web-Mgmt-Console","Web-Mgmt-Tools")) {
        if ((Get-WindowsFeature -Name $f).InstallState -eq "Installed") {
            echo "$f ya esta instalado."
        } else {
            Install-WindowsFeature -Name $f | Out-Null
            echo "$f instalado."
        }
    }
    Import-Module WebAdministration -ErrorAction Stop
    echo "Modulo WebAdministration cargado."
}

function Deshabilitar-Complejidad-Password {
    echo "=== Deshabilitando complejidad de contrasenas ==="
    $tmp = "$env:TEMP\secpol.cfg"
    secedit /export /cfg $tmp | Out-Null
    (Get-Content $tmp) -replace "PasswordComplexity = 1","PasswordComplexity = 0" | Set-Content $tmp
    secedit /configure /db "$env:TEMP\secedit.sdb" /cfg $tmp /areas SECURITYPOLICY | Out-Null
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    echo "Complejidad deshabilitada."
}

function Crear-Grupos {
    echo "=== Creacion de grupos ==="
    foreach ($g in ($GRUPOS + "ftpusers")) {
        if (Get-LocalGroup -Name $g -ErrorAction SilentlyContinue) {
            echo "Grupo '$g' ya existe."
        } else {
            New-LocalGroup -Name $g | Out-Null
            echo "Grupo '$g' creado."
        }
    }
}

function Crear-Estructura-Base {
    echo "=== Estructura de directorios base ==="
    $hostRoot = "C:\inetpub\ftp\$env:COMPUTERNAME"

    New-Item $FTP_ROOT                            -ItemType Directory -Force | Out-Null
    New-Item $SHARED_ROOT                         -ItemType Directory -Force | Out-Null
    New-Item "$SHARED_ROOT\general"               -ItemType Directory -Force | Out-Null
    New-Item "$SHARED_ROOT\reprobados"            -ItemType Directory -Force | Out-Null
    New-Item "$SHARED_ROOT\recursadores"          -ItemType Directory -Force | Out-Null
    New-Item "$FTP_ROOT\LocalUser"                -ItemType Directory -Force | Out-Null
    New-Item $PUBLIC_ROOT                         -ItemType Directory -Force | Out-Null
    New-Item $hostRoot                            -ItemType Directory -Force | Out-Null

    # Junction de acceso anonimo
    $jAnon = "$PUBLIC_ROOT\general"
    if (Test-Path $jAnon) { Remove-Item $jAnon -Recurse -Force -ErrorAction SilentlyContinue }
    & cmd /c mklink /J "$jAnon" "$SHARED_ROOT\general" | Out-Null

    # Permisos con icacls directo (sin cmd /c)
    icacls $FTP_ROOT                 /grant "ftpusers:(RX)"               | Out-Null
    icacls $FTP_ROOT                 /grant "IUSR:(OI)(CI)RX"        /T   | Out-Null
    icacls $FTP_ROOT                 /grant "IIS_IUSRS:(OI)(CI)RX"   /T   | Out-Null
    icacls $hostRoot                 /grant "ftpusers:(OI)(CI)RX"    /T   | Out-Null
    icacls $PUBLIC_ROOT              /grant "IUSR:(OI)(CI)RX"        /T   | Out-Null
    icacls "$SHARED_ROOT\general"    /grant "IUSR:(OI)(CI)R"         /T   | Out-Null
    icacls "$SHARED_ROOT\general"    /grant "ftpusers:(OI)(CI)M"     /T   | Out-Null
    icacls "$SHARED_ROOT\reprobados" /grant "reprobados:(OI)(CI)M"   /T   | Out-Null
    icacls "$SHARED_ROOT\recursadores" /grant "recursadores:(OI)(CI)M" /T | Out-Null

    echo "Directorios y permisos NTFS configurados."
}

function Configurar-Sitio-FTP {
    echo "=== Configuracion del sitio FTP en IIS ==="
    Import-Module WebAdministration

    if (Get-Website -Name $SITE_NAME -ErrorAction SilentlyContinue) {
        Remove-Website -Name $SITE_NAME
        echo "Sitio previo eliminado."
    }

    New-WebFtpSite -Name $SITE_NAME -Port $SITE_PORT -PhysicalPath $FTP_ROOT | Out-Null
    echo "Sitio '$SITE_NAME' creado en puerto $SITE_PORT."

    Set-ItemProperty "IIS:\Sites\$SITE_NAME" -Name ftpServer.security.authentication.anonymousAuthentication.enabled -Value $true
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" -Name ftpServer.security.authentication.basicAuthentication.enabled    -Value $true
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" -Name ftpServer.userIsolation.mode                                     -Value 1
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" -Name ftpServer.security.ssl.controlChannelPolicy                      -Value 0
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" -Name ftpServer.security.ssl.dataChannelPolicy                         -Value 0

    # Fijar usuario anonimo a IUSR en applicationHost.config
    $cfg = "C:\Windows\System32\inetsrv\config\applicationHost.config"
    $xml = [xml](Get-Content $cfg)
    $site = $xml.configuration."system.applicationHost".sites.site | Where-Object { $_.name -eq $SITE_NAME }
    $anonAuth = $site.ftpServer.security.authentication.anonymousAuthentication
    if ($anonAuth) {
        $anonAuth.SetAttribute("enabled", "true")
        $anonAuth.SetAttribute("userName", "IUSR")
    }
    $basicAuth = $site.ftpServer.security.authentication.basicAuthentication
    if ($basicAuth) { $basicAuth.SetAttribute("enabled", "true") }
    $xml.Save($cfg)

    # Reglas de autorizacion FTP
    Clear-WebConfiguration "/system.ftpServer/security/authorization" -PSPath "IIS:\" -Location $SITE_NAME -ErrorAction SilentlyContinue
    Add-WebConfiguration "/system.ftpServer/security/authorization" -PSPath "IIS:\" -Location $SITE_NAME `
        -Value @{accessType="Allow"; users="?"; permissions="Read"}
    Add-WebConfiguration "/system.ftpServer/security/authorization" -PSPath "IIS:\" -Location $SITE_NAME `
        -Value @{accessType="Allow"; roles="ftpusers"; permissions="Read,Write"}

    # Puertos pasivos a nivel servidor
    Set-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" `
        -Filter "system.ftpServer/firewallSupport" -Name "lowDataChannelPort"  -Value 40000
    Set-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" `
        -Filter "system.ftpServer/firewallSupport" -Name "highDataChannelPort" -Value 50000

    Restart-Service ftpsvc -Force
    Start-WebSite -Name $SITE_NAME -ErrorAction SilentlyContinue
    echo "Sitio FTP iniciado."
}

function Crear-Home-Usuario {
    param([string]$username, [string]$grupo)

    $hostRoot  = "C:\inetpub\ftp\$env:COMPUTERNAME"
    $userRoot  = "$hostRoot\$username"
    $personal  = "$userRoot\$username"

    New-Item $hostRoot  -ItemType Directory -Force | Out-Null
    New-Item $userRoot  -ItemType Directory -Force | Out-Null
    New-Item $personal  -ItemType Directory -Force | Out-Null

    # Limpiar junctions anteriores de grupos
    foreach ($g in $GRUPOS) {
        $old = "$userRoot\$g"
        if (Test-Path $old) { Remove-Item $old -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $jGen = "$userRoot\general"
    if (Test-Path $jGen) { Remove-Item $jGen -Recurse -Force -ErrorAction SilentlyContinue }

    # Crear junctions
    & cmd /c mklink /J "$userRoot\general" "$SHARED_ROOT\general"   | Out-Null
    & cmd /c mklink /J "$userRoot\$grupo"  "$SHARED_ROOT\$grupo"    | Out-Null

    # Permisos
    icacls $FTP_ROOT               /grant "${username}:(RX)"           | Out-Null
    icacls $hostRoot               /grant "${username}:(OI)(CI)RX" /T  | Out-Null
    icacls $userRoot               /grant "${username}:(OI)(CI)RX" /T  | Out-Null
    icacls $personal               /grant "${username}:(OI)(CI)M"      | Out-Null
    icacls "$SHARED_ROOT\general"  /grant "${username}:(OI)(CI)M"  /T  | Out-Null
    icacls "$SHARED_ROOT\$grupo"   /grant "${username}:(OI)(CI)M"  /T  | Out-Null

    echo "Home creado: $userRoot"
}

function Crear-Usuario-FTP {
    param([string]$username, [string]$password, [string]$grupo)

    echo "Creando usuario: $username (grupo: $grupo)"
    $secPass = ConvertTo-SecureString $password -AsPlainText -Force

    if (Get-LocalUser -Name $username -ErrorAction SilentlyContinue) {
        echo "Usuario '$username' ya existe. Actualizando contrasena."
        Set-LocalUser -Name $username -Password $secPass
    } else {
        New-LocalUser -Name $username -Password $secPass -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
    }

    if (-not (Get-LocalUser -Name $username -ErrorAction SilentlyContinue)) {
        echo "ERROR: No se pudo crear '$username'. Verifique la contrasena."
        return
    }

    Add-LocalGroupMember -Group "ftpusers" -Member $username -ErrorAction SilentlyContinue
    Add-LocalGroupMember -Group "Users"    -Member $username -ErrorAction SilentlyContinue
    foreach ($g in $GRUPOS) {
        Remove-LocalGroupMember -Group $g -Member $username -ErrorAction SilentlyContinue
    }
    Add-LocalGroupMember -Group $grupo -Member $username -ErrorAction SilentlyContinue

    Crear-Home-Usuario -username $username -grupo $grupo
    echo "Usuario '$username' listo."
}

function Cambiar-Grupo-Usuario {
    param([string]$username, [string]$nuevoGrupo)

    echo "=== Cambio de grupo: $username -> $nuevoGrupo ==="

    if (-not (Get-LocalUser -Name $username -ErrorAction SilentlyContinue)) {
        echo "Usuario '$username' no existe."; return
    }
    if ($nuevoGrupo -notin $GRUPOS) {
        echo "Grupo invalido. Use: reprobados | recursadores"; return
    }

    $userRoot = "C:\inetpub\ftp\$env:COMPUTERNAME\$username"

    foreach ($g in $GRUPOS) {
        $dir = "$userRoot\$g"
        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
        Remove-LocalGroupMember -Group $g -Member $username -ErrorAction SilentlyContinue
    }

    Add-LocalGroupMember -Group $nuevoGrupo -Member $username -ErrorAction SilentlyContinue
    & cmd /c mklink /J "$userRoot\$nuevoGrupo" "$SHARED_ROOT\$nuevoGrupo" | Out-Null
    icacls "$SHARED_ROOT\$nuevoGrupo" /grant "${username}:(OI)(CI)M" /T | Out-Null

    echo "Grupo cambiado a '$nuevoGrupo'."
    echo "Nueva estructura:"
    echo "  \general      RW"
    echo "  \$nuevoGrupo  RW"
    echo "  \$username    RW"
}

function Creacion-Masiva-Usuarios {
    echo "=== Creacion masiva de usuarios ==="
    do { $n = Read-Host "Cuantos usuarios desea crear?" } while ($n -notmatch "^[1-9][0-9]*$")

    for ($i = 1; $i -le [int]$n; $i++) {
        echo ""
        echo "--- Usuario $i / $n ---"

        do {
            $username = Read-Host "  Nombre de usuario"
        } while ($username -notmatch "^[a-zA-Z][a-zA-Z0-9_-]{2,29}$")

        do {
            $b1 = Read-Host "  Contrasena"        -AsSecureString
            $b2 = Read-Host "  Confirmar contrasena" -AsSecureString
            $p1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($b1))
            $p2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($b2))
        } while ($p1 -ne $p2 -or [string]::IsNullOrEmpty($p1))

        do {
            $grupo = Read-Host "  Grupo (reprobados/recursadores)"
        } while ($grupo -notin $GRUPOS)

        Crear-Usuario-FTP -username $username -password $p1 -grupo $grupo
    }
}

function Configurar-Firewall {
    echo "=== Configurando Firewall ==="
    New-NetFirewallRule -DisplayName "FTP Puerto 21" -Direction Inbound -Protocol TCP -LocalPort 21 -Action Allow -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName "FTP Pasivo 40000-50000" -Direction Inbound -Protocol TCP -LocalPort 40000-50000 -Action Allow -ErrorAction SilentlyContinue | Out-Null
    echo "Reglas de firewall creadas (21, 40000-50000)."
}

function Mostrar-Resumen {
    $hostRoot = "C:\inetpub\ftp\$env:COMPUTERNAME"
    echo ""
    echo "=== Configuracion completada ==="
    echo "  Raiz FTP    : $FTP_ROOT"
    echo "  Compartidos : $SHARED_ROOT"
    echo "  Host root   : $hostRoot"
    echo "  Sitio IIS   : $SITE_NAME  puerto $SITE_PORT"
    echo ""
    echo "  Anonimo  -> LocalUser\Public\general  (solo lectura)"
    echo "  Auth     -> \$env:COMPUTERNAME\usuario\general"
    echo "  Auth     -> \$env:COMPUTERNAME\usuario\grupo"
    echo "  Auth     -> \$env:COMPUTERNAME\usuario\usuario"
    echo ""
    echo "  Usuarios registrados en ftpusers:"
    Get-LocalGroupMember -Group "ftpusers" -ErrorAction SilentlyContinue | ForEach-Object {
        $uname = $_.Name.Split("\")[-1]
        $grp = $GRUPOS | Where-Object {
            Get-LocalGroupMember -Group $_ -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*$uname" }
        } | Select-Object -First 1
        echo "    $uname  ->  $grp"
    }
    echo ""
}

function Mostrar-Estado {
    echo "=== Estado del servicio FTP ==="
    Get-Service ftpsvc -ErrorAction SilentlyContinue
    echo ""
    Get-Website -Name $SITE_NAME -ErrorAction SilentlyContinue
}

function Menu-Principal {
    echo ""
    echo "======================================"
    echo "  SERVIDOR FTP WINDOWS - IIS FTP"
    echo "  Grupos: reprobados | recursadores"
    echo "======================================"
    echo "  1) Configuracion inicial completa"
    echo "  2) Agregar nuevos usuarios"
    echo "  3) Cambiar grupo de un usuario"
    echo "  4) Reiniciar servicio FTP"
    echo "  5) Ver estado del servicio"
    echo "  6) Salir"
    echo "======================================"
    echo ""
    $op = Read-Host "Opcion [1-6]"

    switch ($op) {
        "1" {
            Instalar-IIS-FTP
            Deshabilitar-Complejidad-Password
            Crear-Grupos
            Crear-Estructura-Base
            Configurar-Sitio-FTP
            Creacion-Masiva-Usuarios
            Configurar-Firewall
            Mostrar-Resumen
        }
        "2" { Creacion-Masiva-Usuarios }
        "3" {
            $u = Read-Host "Usuario a modificar"
            $g = Read-Host "Nuevo grupo (reprobados/recursadores)"
            Cambiar-Grupo-Usuario -username $u -nuevoGrupo $g
        }
        "4" { Restart-Service ftpsvc -Force; echo "Servicio FTP reiniciado." }
        "5" { Mostrar-Estado }
        "6" { echo "Saliendo..."; exit }
        default { echo "Opcion invalida."; Menu-Principal }
    }
}

Clear-Host
Menu-Principal
