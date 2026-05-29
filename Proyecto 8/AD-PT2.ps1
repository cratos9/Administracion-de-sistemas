#Requires -RunAsAdministrator

$DomainDN    = "DC=PRACTICA,DC=LOCAL"
$DefaultPass = ConvertTo-SecureString "f8Y28KT0mtnd" -AsPlainText -Force

function Write-Log {
    param([string]$Message, [string]$Type = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Type) {
        "SUCCESS" { "Green" }
        "WARNING" { "Yellow" }
        "ERROR"   { "Red" }
        default   { "Cyan" }
    }
    Write-Host "[$timestamp] [$Type] $Message" -ForegroundColor $color
}

Write-Log "Esperando que los servicios de Active Directory estén listos..."
Start-Sleep -Seconds 30

try {
    Import-Module ActiveDirectory -ErrorAction Stop
    Write-Log "Módulo Active Directory cargado correctamente." "SUCCESS"
}
catch {
    Write-Log "No se pudo cargar el módulo Active Directory. ¿El servidor fue reiniciado como DC?" "ERROR"
    exit 1
}

Write-Log "Creando Unidades Organizativas..."

$OUs = @(
    @{ Name = "Windows"; Path = $DomainDN; Description = "Windows" },
    @{ Name = "Linux";   Path = $DomainDN; Description = "Linux" }
)

foreach ($OU in $OUs) {
    try {
        $ouExists = Get-ADOrganizationalUnit -Filter "Name -eq '$($OU.Name)'" -SearchBase $OU.Path -ErrorAction SilentlyContinue
        if ($null -eq $ouExists) {
            New-ADOrganizationalUnit `
                -Name                            $OU.Name `
                -Path                            $OU.Path `
                -Description                     $OU.Description `
                -ProtectedFromAccidentalDeletion $false
            Write-Log "OU '$($OU.Name)' creada correctamente." "SUCCESS"
        } else {
            Write-Log "OU '$($OU.Name)' ya existe. Se omite." "WARNING"
        }
    }
    catch {
        Write-Log "Error al crear la OU '$($OU.Name)': $_" "ERROR"
    }
}

Write-Log "Creando usuarios de dominio..."

$Usuarios = @(
    @{
        Nombre      = "Miguel"
        Apellido    = "Silis"
        DisplayName = "Miguel Silis"
        SamAccount  = "msilis01"
        UPN         = "msilis01@PRACTICA.LOCAL"
        OU          = "OU=Windows,$DomainDN"
    },
    @{
        Nombre      = "Iveth"
        Apellido    = "Pichardo"
        DisplayName = "Iveth Pichardo"
        SamAccount  = "ipichardo01"
        UPN         = "ipichardo01@PRACTICA.LOCAL"
        OU          = "OU=Windows,$DomainDN"
    },
    @{
        Nombre      = "Montserrat"
        Apellido    = "Lopez"
        DisplayName = "Montserrat Lopez"
        SamAccount  = "mlopez01"
        UPN         = "mlopez01@PRACTICA.LOCAL"
        OU          = "OU=Linux,$DomainDN"
    },
    @{
        Nombre      = "Fernando"
        Apellido    = "Solis"
        DisplayName = "Fernando Solis"
        SamAccount  = "fsolis01"
        UPN         = "fsolis01@PRACTICA.LOCAL"
        OU          = "OU=Linux,$DomainDN"
    }
)

foreach ($u in $Usuarios) {
    try {
        $existe = Get-ADUser -Filter "SamAccountName -eq '$($u.SamAccount)'" -ErrorAction SilentlyContinue
        if ($null -ne $existe) {
            Write-Log "Usuario '$($u.SamAccount)' ya existe. Se omite." "WARNING"
            continue
        }

        New-ADUser `
            -GivenName            $u.Nombre `
            -Surname              $u.Apellido `
            -DisplayName          $u.DisplayName `
            -Name                 $u.DisplayName `
            -SamAccountName       $u.SamAccount `
            -UserPrincipalName    $u.UPN `
            -Path                 $u.OU `
            -AccountPassword      $DefaultPass `
            -Enabled              $true `
            -PasswordNeverExpires $true `
            -ChangePasswordAtLogon $false

        Write-Log "Usuario '$($u.SamAccount)' ($($u.DisplayName)) creado en '$($u.OU)'." "SUCCESS"
    }
    catch {
        Write-Log "Error al crear el usuario '$($u.SamAccount)': $_" "ERROR"
    }
}

Write-Log "CONFIGURACIÓN COMPLETADA"

Write-Log "Unidades Organizativas:"
Get-ADOrganizationalUnit -Filter * -SearchBase $DomainDN -SearchScope OneLevel |
    Select-Object Name, DistinguishedName |
    Format-Table -AutoSize | Out-String | Write-Host

Write-Log "Usuarios creados:"
Get-ADUser -Filter * -SearchBase $DomainDN -Properties DisplayName, Enabled |
    Where-Object { $_.SamAccountName -ne "Administrator" -and $_.SamAccountName -ne "Guest" } |
    Select-Object DisplayName, SamAccountName, Enabled, DistinguishedName |
    Format-Table -AutoSize | Out-String | Write-Host

Write-Log "¡Configuración de PRACTICA.LOCAL finalizada correctamente!" "SUCCESS"
