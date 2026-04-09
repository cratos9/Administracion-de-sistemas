function Log($msg) {
	Write-Host "[*] $msg"
}

function Verificar-Admin{
	$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
	if (-not $isAdmin) {
	    Write-Host "Debes ejecutar como administrador"
	    exit 1
	}
}

function Validar-IP($ip) {
    return $ip -match "^(\d{1,3}\.){3}\d{1,3}$" -and
        ($ip.Split('.') | ForEach-Object { [int]$_ -le 255 -and [int]$_ -ge 0 }) -notcontains $false
}

function Leer-IP($prompt) {
	do {
		$val = Read-Host $prompt
		if (-not (Validar-IP $val)) { Write-Host "IP invalida" }
	} while (-not (Validar-IP $val))
	return $val
}

function Pausar {
	Read-Host "Presiona Enter para continuar"
}