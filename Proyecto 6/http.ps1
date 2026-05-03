if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output "Ejecuta como administrador"
    exit 1
}

$global:IIS_PORT     = 80
$global:APACHE_PORT  = 8080
$global:TOMCAT_PORT  = 8081
$global:CHOSEN_PORT_RESULT = 0

$global:APACHE_DIR = "C:\Apache24"
$global:TOMCAT_DIR = "C:\Tomcat"
$global:JAVA_DIR   = "C:\Java"

$global:TOMCAT_ZIP_URL = "https://archive.apache.org/dist/tomcat/tomcat-10/v10.1.24/bin/apache-tomcat-10.1.24-windows-x64.zip"
$global:JAVA_ZIP_URL   = "https://aka.ms/download-jdk/microsoft-jdk-21-windows-x64.zip"

function Test-PortInUse {
    param([int]$Port)
    $result = netstat -ano | Select-String ":$Port\s"
    return ($null -ne $result)
}

function Get-ValidPort {
    param([string]$ServiceName, [int]$DefaultPort)
    while ($true) {
        $userInput = Read-Host "Puerto para $ServiceName [default: $DefaultPort]"
        if ([string]::IsNullOrWhiteSpace($userInput)) { $userInput = "$DefaultPort" }
        if ($userInput -notmatch '^\d+$' -or [int]$userInput -lt 1 -or [int]$userInput -gt 65535) {
            Write-Output "Puerto invalido. Ingresa un numero entre 1 y 65535."
            continue
        }
        $port = [int]$userInput
        if (Test-PortInUse $port) {
            Write-Output "El puerto $port ya esta en uso."
            $retry = Read-Host "Deseas elegir otro puerto? (s/n)"
            if ($retry -match '^[Ss]$') { continue }
            else {
                Write-Output "Puerto $port conservado."
                $global:CHOSEN_PORT_RESULT = $port
                return
            }
        }
        Write-Output "Puerto $port disponible."
        $global:CHOSEN_PORT_RESULT = $port
        return
    }
}

function Install-Chocolatey {
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Output "Chocolatey ya esta instalado."
        return $true
    }
    Write-Output "Instalando Chocolatey..."
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Output "Chocolatey instalado correctamente."
            return $true
        } else {
            Write-Output "Error: Chocolatey no encontrado tras instalacion."
            return $false
        }
    } catch {
        Write-Output "Error instalando Chocolatey: $_"
        return $false
    }
}

function Install-Java {
    if (Get-Command java -ErrorAction SilentlyContinue) {
        Write-Output "Java ya esta disponible en PATH."
        $javaHome = Split-Path (Split-Path (Get-Command java).Source)
        [System.Environment]::SetEnvironmentVariable("JAVA_HOME", $javaHome, "Machine")
        $env:JAVA_HOME = $javaHome
        return $javaHome
    }
    $existingJH = [System.Environment]::GetEnvironmentVariable("JAVA_HOME","Machine")
    if ($existingJH -and (Test-Path "$existingJH\bin\java.exe")) {
        Write-Output "Java encontrado via JAVA_HOME: $existingJH"
        $env:JAVA_HOME = $existingJH
        $env:Path += ";$existingJH\bin"
        return $existingJH
    }
    Write-Output "Instalando Java 21 via Chocolatey..."
    if (-not (Install-Chocolatey)) { return $null }
    choco install microsoft-openjdk21 --yes --no-progress --force
    if ($LASTEXITCODE -ne 0) {
        Write-Output "Fallo microsoft-openjdk21. Intentando temurin21..."
        choco install temurin21 --yes --no-progress --force
    }
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    if (Get-Command java -ErrorAction SilentlyContinue) {
        $javaHome = Split-Path (Split-Path (Get-Command java).Source)
        [System.Environment]::SetEnvironmentVariable("JAVA_HOME", $javaHome, "Machine")
        $env:JAVA_HOME = $javaHome
        Write-Output "Java instalado correctamente. JAVA_HOME=$javaHome"
        return $javaHome
    }
    $fallbackPaths = @(
        "C:\Program Files\Microsoft\jdk-21*",
        "C:\Program Files\Eclipse Adoptium\jdk-21*",
        "C:\Program Files\Java\jdk-21*"
    )
    foreach ($pattern in $fallbackPaths) {
        $found = Get-ChildItem $pattern -ErrorAction SilentlyContinue |
                 Where-Object { Test-Path "$($_.FullName)\bin\java.exe" } |
                 Select-Object -First 1
        if ($found) {
            $javaHome = $found.FullName
            [System.Environment]::SetEnvironmentVariable("JAVA_HOME", $javaHome, "Machine")
            $env:JAVA_HOME = $javaHome
            $env:Path += ";$javaHome\bin"
            Write-Output "Java encontrado en: $javaHome"
            return $javaHome
        }
    }
    Write-Output "Error: Java no pudo ser instalado o encontrado."
    return $null
}

function Install-IIS {
    Write-Output ""
    $feature = Get-WindowsFeature -Name Web-Server -ErrorAction SilentlyContinue
    if ($null -eq $feature) {
        Write-Output "ADVERTENCIA: Get-WindowsFeature no disponible. Saltando instalacion de IIS."
        return
    }
    if ($feature.Installed) {
        Write-Output "IIS ya esta instalado."
        $reinstall = Read-Host "Deseas reconfigurar el puerto? (s/n)"
        if ($reinstall -notmatch '^[Ss]$') { return }
    } else {
        Write-Output "Instalando IIS..."
        Install-WindowsFeature -Name Web-Server,Web-Common-Http,Web-Default-Doc,Web-Static-Content -IncludeManagementTools
    }
    Get-ValidPort "IIS" $global:IIS_PORT
    $global:IIS_PORT = [int]$global:CHOSEN_PORT_RESULT
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    $binding = Get-WebBinding -Name "Default Web Site" -Protocol "http" -ErrorAction SilentlyContinue
    if ($binding) { Remove-WebBinding -Name "Default Web Site" -Protocol "http" }
    New-WebBinding -Name "Default Web Site" -Protocol "http" -Port $global:IIS_PORT -IPAddress "*"
    Start-Service W3SVC -ErrorAction SilentlyContinue
    Set-Service W3SVC -StartupType Automatic -ErrorAction SilentlyContinue
    $status = (Get-Service -Name W3SVC -ErrorAction SilentlyContinue).Status
    Write-Output "IIS configurado en puerto $($global:IIS_PORT). Estado: $status"
}

function Install-ApacheWindows {
    Write-Output ""
    if (Test-Path "$global:APACHE_DIR\bin\httpd.exe") {
        Write-Output "Apache ya esta instalado en $global:APACHE_DIR."
        $reinstall = Read-Host "Deseas reinstalarlo? (s/n)"
        if ($reinstall -notmatch '^[Ss]$') { return }
        & "$global:APACHE_DIR\bin\httpd.exe" -k stop 2>$null
        & "$global:APACHE_DIR\bin\httpd.exe" -k uninstall 2>$null
        Remove-Item -Recurse -Force $global:APACHE_DIR
    }
    Get-ValidPort "Apache" $global:APACHE_PORT
    $global:APACHE_PORT = [int]$global:CHOSEN_PORT_RESULT
    if (-not (Install-Chocolatey)) {
        Write-Output "Error: No se pudo instalar Chocolatey. Abortando instalacion de Apache."
        return
    }
    Write-Output "Instalando Apache via Chocolatey..."
    choco install apache-httpd --yes --no-progress --force
    if ($LASTEXITCODE -ne 0) {
        Write-Output "Error: choco install apache-httpd fallo (exit code $LASTEXITCODE)."
        return
    }
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    if (!(Test-Path "$global:APACHE_DIR\bin\httpd.exe")) {
        $searchRoots = @("C:\tools","C:\ProgramData\chocolatey\lib","C:\Apache24","$env:ProgramFiles\Apache*","C:\Users\$env:USERNAME\AppData\Roaming")
        $found = $null
        foreach ($root in $searchRoots) {
            $found = Get-ChildItem $root -Recurse -Filter "httpd.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { break }
        }
        if ($found) {
            $global:APACHE_DIR = Split-Path $found.DirectoryName
            Write-Output "Apache encontrado en: $global:APACHE_DIR"
        } else {
            Write-Output "Error: httpd.exe no encontrado tras instalacion. Abortando."
            return
        }
    }
    $conf = "$global:APACHE_DIR\conf\httpd.conf"
    if (!(Test-Path $conf)) {
        Write-Output "Error: httpd.conf no encontrado en $global:APACHE_DIR."
        return
    }
    $lines = Get-Content $conf
    $lines = $lines | ForEach-Object {
        if ($_ -match '^Listen \d+')        { "Listen $($global:APACHE_PORT)" }
        elseif ($_ -match '^#?ServerName ') { "ServerName localhost:$($global:APACHE_PORT)" }
        else { $_ }
    }
    Set-Content $conf $lines
    $existingSvc = Get-Service -Name "Apache*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existingSvc) {
        Stop-Service $existingSvc.Name -ErrorAction SilentlyContinue
        & "$global:APACHE_DIR\bin\httpd.exe" -k uninstall -n $existingSvc.Name 2>$null
    }
    & "$global:APACHE_DIR\bin\httpd.exe" -k install -n "Apache24"
    Start-Service Apache24 -ErrorAction SilentlyContinue
    Set-Service Apache24 -StartupType Automatic -ErrorAction SilentlyContinue
    $status = (Get-Service -Name Apache24 -ErrorAction SilentlyContinue).Status
    Write-Output "Apache instalado en puerto $($global:APACHE_PORT). Estado: $status"
}

function Install-TomcatWindows {
    Write-Output ""
    if (Test-Path "$global:TOMCAT_DIR\bin\startup.bat") {
        Write-Output "Tomcat ya esta instalado en $global:TOMCAT_DIR."
        $reinstall = Read-Host "Deseas reinstalarlo? (s/n)"
        if ($reinstall -notmatch '^[Ss]$') { return }
        $env:JAVA_HOME     = [System.Environment]::GetEnvironmentVariable("JAVA_HOME","Machine")
        $env:JRE_HOME      = $env:JAVA_HOME
        $env:CATALINA_HOME = $global:TOMCAT_DIR
        Stop-Service Tomcat10 -ErrorAction SilentlyContinue
        $prevLoc = Get-Location
        Set-Location "$global:TOMCAT_DIR\bin"
        & ".\tomcat10.exe" //DS//Tomcat10 2>$null
        Start-Sleep -Seconds 2
        Set-Location $prevLoc
        Remove-Item -Recurse -Force $global:TOMCAT_DIR
    }

    Get-ValidPort "Tomcat" $global:TOMCAT_PORT
    $global:TOMCAT_PORT = [int]$global:CHOSEN_PORT_RESULT

    $JAVA_HOME_PATH = Install-Java
    if (-not $JAVA_HOME_PATH) {
        Write-Output "Error: Java no disponible. Abortando instalacion de Tomcat."
        return
    }

    $env:JAVA_HOME     = $JAVA_HOME_PATH
    $env:JRE_HOME      = $JAVA_HOME_PATH
    $env:CATALINA_HOME = $global:TOMCAT_DIR
    [System.Environment]::SetEnvironmentVariable("JAVA_HOME",     $JAVA_HOME_PATH,    "Machine")
    [System.Environment]::SetEnvironmentVariable("JRE_HOME",      $JAVA_HOME_PATH,    "Machine")
    [System.Environment]::SetEnvironmentVariable("CATALINA_HOME", $global:TOMCAT_DIR, "Machine")

    $jvmPath = Get-ChildItem $JAVA_HOME_PATH -Recurse -Filter "jvm.dll" -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -like "*server*" } |
               Select-Object -First 1 -ExpandProperty FullName

    if (-not $jvmPath) {
        Write-Output "jvm.dll no encontrado en JAVA_HOME, buscando en Program Files..."
        $jvmPath = Get-ChildItem "C:\Program Files" -Recurse -Filter "jvm.dll" -ErrorAction SilentlyContinue |
                   Where-Object { $_.FullName -like "*server*" } |
                   Select-Object -First 1 -ExpandProperty FullName
    }

    if (-not $jvmPath) {
        Write-Output "Error: jvm.dll no encontrado en ninguna ruta conocida."
        return
    }
    Write-Output "JVM encontrado: $jvmPath"

    $JAVA_HOME_PATH = Split-Path (Split-Path $jvmPath)
    $JAVA_HOME_PATH = Split-Path (Split-Path $JAVA_HOME_PATH)
    $env:JAVA_HOME = $JAVA_HOME_PATH
    $env:JRE_HOME  = $JAVA_HOME_PATH
    [System.Environment]::SetEnvironmentVariable("JAVA_HOME", $JAVA_HOME_PATH, "Machine")
    [System.Environment]::SetEnvironmentVariable("JRE_HOME",  $JAVA_HOME_PATH, "Machine")

    Write-Output "Descargando Tomcat 10.1.24..."
    $zipPath = "$env:TEMP\tomcat.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    try {
        $headers = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"; "Accept" = "*/*" }
        Invoke-WebRequest -Uri $global:TOMCAT_ZIP_URL -OutFile $zipPath -Headers $headers -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Output "Reintentando descarga con curl..."
        curl.exe -L $global:TOMCAT_ZIP_URL -o $zipPath
    }
    if (!(Test-Path $zipPath) -or (Get-Item $zipPath).Length -lt 5MB) {
        Write-Output "Error: Descarga de Tomcat fallida o archivo corrupto."
        return
    }

    Write-Output "Extrayendo Tomcat..."
    $extractDir = "$env:TEMP\tomcat_extract"
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
    $innerDir = Get-ChildItem $extractDir | Where-Object { $_.PSIsContainer } | Select-Object -First 1
    if (-not $innerDir) {
        Write-Output "Error: estructura del ZIP de Tomcat inesperada."
        return
    }
    if (Test-Path $global:TOMCAT_DIR) { Remove-Item $global:TOMCAT_DIR -Recurse -Force }
    Move-Item $innerDir.FullName $global:TOMCAT_DIR
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zipPath -ErrorAction SilentlyContinue

    if (!(Test-Path "$global:TOMCAT_DIR\bin\startup.bat")) {
        Write-Output "Error: startup.bat no encontrado tras extraccion."
        return
    }

    $serverXml = "$global:TOMCAT_DIR\conf\server.xml"
    (Get-Content $serverXml) -replace 'port="8080"', "port=`"$($global:TOMCAT_PORT)`"" | Set-Content $serverXml

    Write-Output "Registrando servicio Tomcat10..."
    $prevLocation = Get-Location
    Set-Location "$global:TOMCAT_DIR\bin"

    & ".\tomcat10.exe" //DS//Tomcat10 2>$null
    Start-Sleep -Seconds 2

    & ".\tomcat10.exe" //IS//Tomcat10 `
        --DisplayName="Apache Tomcat 10.1" `
        --Description="Apache Tomcat 10.1 Server" `
        --Jvm="$jvmPath" `
        --JvmMs=128 `
        --JvmMx=512 `
        --StartMode=jvm `
        --StopMode=jvm `
        --StartClass=org.apache.catalina.startup.Bootstrap `
        --StartParams=start `
        --StopClass=org.apache.catalina.startup.Bootstrap `
        --StopParams=stop `
        --Classpath="$global:TOMCAT_DIR\bin\bootstrap.jar;$global:TOMCAT_DIR\bin\tomcat-juli.jar" `
        --LogPath="$global:TOMCAT_DIR\logs" `
        --StdOutput="$global:TOMCAT_DIR\logs\stdout.log" `
        --StdError="$global:TOMCAT_DIR\logs\stderr.log" `
        --StartPath="$global:TOMCAT_DIR" `
        --StopPath="$global:TOMCAT_DIR"

    Set-Location $prevLocation
    Start-Sleep -Seconds 2

    Start-Service Tomcat10 -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 8

    $svc = Get-Service -Name "Tomcat10" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Set-Service Tomcat10 -StartupType Automatic
        Write-Output "Tomcat instalado en puerto $($global:TOMCAT_PORT). Estado: $($svc.Status)"
    } else {
        Write-Output "Servicio Windows no disponible. Iniciando via startup.bat..."
        $env:JAVA_HOME     = $JAVA_HOME_PATH
        $env:JRE_HOME      = $JAVA_HOME_PATH
        $env:CATALINA_HOME = $global:TOMCAT_DIR
        $env:Path         += ";$JAVA_HOME_PATH\bin"

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = "java.exe"
        $psi.Arguments              = "-cp `"$global:TOMCAT_DIR\bin\bootstrap.jar;$global:TOMCAT_DIR\bin\tomcat-juli.jar`" -Dcatalina.home=`"$global:TOMCAT_DIR`" -Dcatalina.base=`"$global:TOMCAT_DIR`" -Djava.io.tmpdir=`"$global:TOMCAT_DIR\temp`" org.apache.catalina.startup.Bootstrap start"
        $psi.WorkingDirectory       = "$global:TOMCAT_DIR\bin"
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $false
        $psi.WindowStyle            = [System.Diagnostics.ProcessWindowStyle]::Minimized

        $process = [System.Diagnostics.Process]::Start($psi)

        Start-Sleep -Seconds 10

        try {
            $r = Invoke-WebRequest -Uri "http://localhost:$($global:TOMCAT_PORT)/" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            Write-Output "Tomcat iniciado correctamente en puerto $($global:TOMCAT_PORT). HTTP $($r.StatusCode) (PID: $($process.Id))"
        } catch {
            Write-Output "Error: Tomcat no responde en puerto $($global:TOMCAT_PORT). Revisa C:\Tomcat\logs"
        }
    }
}

function Stop-HttpServices {
    Write-Output ""
    Write-Output "Selecciona el servicio a detener:"
    Write-Output "1) IIS"
    Write-Output "2) Apache"
    Write-Output "3) Tomcat"
    Write-Output "4) Todos"
    $opt = Read-Host "Opcion"
    switch ($opt) {
        "1" { Stop-Service W3SVC    -ErrorAction SilentlyContinue; Write-Output "IIS detenido" }
        "2" { Stop-Service Apache24 -ErrorAction SilentlyContinue; Write-Output "Apache detenido" }
        "3" { Stop-Service Tomcat10 -ErrorAction SilentlyContinue; Write-Output "Tomcat detenido" }
        "4" {
            Stop-Service W3SVC    -ErrorAction SilentlyContinue; Write-Output "IIS detenido"
            Stop-Service Apache24 -ErrorAction SilentlyContinue; Write-Output "Apache detenido"
            Stop-Service Tomcat10 -ErrorAction SilentlyContinue; Write-Output "Tomcat detenido"
        }
        default { Write-Output "Opcion invalida" }
    }
}

function Restart-HttpServices {
    Write-Output ""
    Write-Output "Selecciona el servicio a reiniciar:"
    Write-Output "1) IIS"
    Write-Output "2) Apache"
    Write-Output "3) Tomcat"
    Write-Output "4) Todos"
    $opt = Read-Host "Opcion"
    switch ($opt) {
        "1" { Restart-Service W3SVC    -ErrorAction SilentlyContinue; Write-Output "IIS reiniciado" }
        "2" { Restart-Service Apache24 -ErrorAction SilentlyContinue; Write-Output "Apache reiniciado" }
        "3" { Restart-Service Tomcat10 -ErrorAction SilentlyContinue; Write-Output "Tomcat reiniciado" }
        "4" {
            Restart-Service W3SVC    -ErrorAction SilentlyContinue; Write-Output "IIS reiniciado"
            Restart-Service Apache24 -ErrorAction SilentlyContinue; Write-Output "Apache reiniciado"
            Restart-Service Tomcat10 -ErrorAction SilentlyContinue; Write-Output "Tomcat reiniciado"
        }
        default { Write-Output "Opcion invalida" }
    }
}

function Show-Status {
    Write-Output ""
    Write-Output "Estado de servicios"
    foreach ($svc in @("W3SVC","Apache24","Tomcat10")) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) { Write-Output "$svc : $($s.Status)" }
        else     { Write-Output "$svc : no instalado" }
    }
    Write-Output ""
    Write-Output "Puertos en uso"
    netstat -ano | Select-String ":$($global:IIS_PORT)\s|:$($global:APACHE_PORT)\s|:$($global:TOMCAT_PORT)\s"
    Write-Output ""
    Write-Output "Prueba HTTP"
    @(
        @{Name="IIS";    Port=$global:IIS_PORT}
        @{Name="Apache"; Port=$global:APACHE_PORT}
        @{Name="Tomcat"; Port=$global:TOMCAT_PORT}
    ) | ForEach-Object {
        $name = $_.Name; $port = $_.Port
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:$port/" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            Write-Output "$name (puerto $port): HTTP $($r.StatusCode)"
        } catch {
            Write-Output "$name (puerto $port): sin respuesta"
        }
    }
}

function Show-InstallMenu {
    Write-Output ""
    Write-Output "Selecciona los servicios a instalar:"
    Write-Output "1) IIS"
    Write-Output "2) Apache"
    Write-Output "3) Tomcat"
    Write-Output "4) Todos"
    Write-Output "5) Volver"
    $opt = Read-Host "Opcion"
    switch ($opt) {
        "1" { Install-IIS }
        "2" { Install-ApacheWindows }
        "3" { Install-TomcatWindows }
        "4" {
            Install-IIS
            Install-ApacheWindows
            Install-TomcatWindows
        }
        "5" { return }
        default { Write-Output "Opcion invalida" }
    }
}

while ($true) {
    Write-Output ""
    Write-Output "Servicios HTTP"
    Write-Output "1) Instalar servicios"
    Write-Output "2) Detener servicios"
    Write-Output "3) Reiniciar servicios"
    Write-Output "4) Ver estado y puertos"
    Write-Output "5) Salir"
    $opcion = Read-Host "Opcion"
    switch ($opcion) {
        "1" { Show-InstallMenu }
        "2" { Stop-HttpServices }
        "3" { Restart-HttpServices }
        "4" { Show-Status }
        "5" { Write-Output "Saliendo"; exit 0 }
        default { Write-Output "Opcion invalida" }
    }
}