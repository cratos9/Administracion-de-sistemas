#Requires -RunAsAdministrator

$DomainName     = "PRACTICA.LOCAL"
$NetBIOSName    = "PRACTICA"
$SafeModePass   = ConvertTo-SecureString "Admin123" -AsPlainText -Force
$DefaultPass    = ConvertTo-SecureString "f8Y28KT0mtnd" -AsPlainText -Force
$DomainDN       = "DC=PRACTICA,DC=LOCAL"

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

Write-Log "Iniciando instalación del rol AD DS y herramientas de administración..."

try {
    $installResult = Install-WindowsFeature `
        -Name AD-Domain-Services `
        -IncludeManagementTools `
        -IncludeAllSubFeature `
        -Verbose

    if ($installResult.Success) {
        Write-Log "Rol AD DS instalado correctamente." "SUCCESS"
    } else {
        Write-Log "La instalación del rol AD DS no fue exitosa." "ERROR"
        exit 1
    }
}
catch {
    Write-Log "Error al instalar el rol AD DS: $_" "ERROR"
    exit 1
}

Write-Log "Promoviendo el servidor a Domain Controller..."
Write-Log "Dominio: $DomainName | NetBIOS: $NetBIOSName"

try {
    Import-Module ADDSDeployment -ErrorAction Stop

    Install-ADDSForest `
        -DomainName            $DomainName `
        -DomainNetbiosName     $NetBIOSName `
        -ForestMode            "WinThreshold" `
        -DomainMode            "WinThreshold" `
        -InstallDns:$true `
        -SafeModeAdministratorPassword $SafeModePass `
        -NoRebootOnCompletion:$false `
        -Force:$true

    Write-Log "El servidor será reiniciado para completar la promoción a DC." "SUCCESS"
}
catch {
    Write-Log "Error durante la promoción a Domain Controller: $_" "ERROR"
    exit 1
}
