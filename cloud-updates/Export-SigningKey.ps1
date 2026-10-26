# PowerShell 5.1+ / Export-SigningKey.ps1 / Windows / encrypted publisher backup, outside the application folder.
param([Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'
$settings=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'publisher.json') -Raw | ConvertFrom-Json
$cert=Get-Item -LiteralPath ('Cert:\CurrentUser\My\'+$settings.certificateThumbprint)
if (Test-Path -LiteralPath $Destination) { throw 'Escolha um arquivo de backup que ainda nao exista.' }
$password=Read-Host 'Senha para proteger o backup PFX' -AsSecureString
Export-PfxCertificate -Cert $cert -FilePath $Destination -Password $password | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'publisher.json') -Destination ($Destination+'.publisher.json')
Write-Host 'Guarde PFX, senha e publisher.json em local protegido. Nao publique esses arquivos no GitHub.'
