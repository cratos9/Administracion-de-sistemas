function Ver-EstadoServidor {
	Log "Nombre del host"
	hostname
	Write-Host ""
	Log "Dirección IP:"
	ipconfig
	Write-Host ""
	Log "Espacio en disco:"
	Get-PSDrive
}