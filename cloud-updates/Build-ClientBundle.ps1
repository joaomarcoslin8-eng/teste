# PowerShell 5.1+ / Build-ClientBundle.ps1 / Windows / first-install customer bundle with public update verifier only.
param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Cloud.Common.ps1')
$Root=Assert-CloudRoot $Root
$id=[guid]::NewGuid().ToString('N');$stage=Join-Path $Root ('build/client-'+$id)
try {
    foreach ($dir in @('config','docs','tools/cloud')) { [IO.Directory]::CreateDirectory((Join-Path $stage $dir)) | Out-Null }
    foreach ($file in @('ZyonRoblox.exe','config/offsets.json','docs/THIRD-PARTY-NOTICES.txt','tools/Client-Shortcuts.ps1')) { Copy-Item -LiteralPath (Join-Path $Root $file) -Destination (Join-Path $stage $file) }
    foreach ($name in @('Cloud.Common.ps1','Update-Launch.ps1','update-trust.json')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $stage ('tools/cloud/'+$name)) }
    $cmd='@echo off'+"`r`n"+'"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Client-Shortcuts.ps1"'+"`r`n"+'pause'+"`r`n"
    [IO.File]::WriteAllText((Join-Path $stage 'tools/Instalar-Atalhos.cmd'),$cmd,[Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $stage 'docs/ATUALIZACOES.txt'),"Extraia tudo para uma pasta. Execute tools\Instalar-Atalhos.cmd uma vez.`r`nAbra pelo atalho Zyon - iniciar. Ele verifica atualizacoes assinadas antes de iniciar.`r`nPara verificar imediatamente, feche o programa e use Zyon - verificar atualizacoes.`r`nAbrir o EXE diretamente pula essa verificacao. Preferencias de idioma ficam em config\ui.json.`r`n",[Text.UTF8Encoding]::new($false))
    $output=Join-Path $Root ('build/Zyon-Client-'+$id.Substring(0,8)+'.zip')
    Compress-Archive -LiteralPath @((Join-Path $stage 'ZyonRoblox.exe'),(Join-Path $stage 'config'),(Join-Path $stage 'docs'),(Join-Path $stage 'tools')) -DestinationPath $output
    Write-Host "Pacote inicial dos clientes: $output"
} finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force } }
