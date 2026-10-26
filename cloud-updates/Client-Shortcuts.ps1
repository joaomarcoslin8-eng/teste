# PowerShell 5.1+ / Client-Shortcuts.ps1 / Windows / user-level shortcuts; no administrator required.
param([string]$Root=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$Root=[IO.Path]::GetFullPath($Root)
$power=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
$script=Join-Path $Root 'tools/cloud/Update-Launch.ps1'
if (!(Test-Path -LiteralPath $script)) { throw 'Verificador nao instalado.' }
$shell=New-Object -ComObject WScript.Shell
$desktop=[Environment]::GetFolderPath('Desktop')
foreach ($entry in @(@('Zyon - iniciar',' -Launch',7),@('Zyon - verificar atualizacoes',' -Force',1))) {
    $link=$shell.CreateShortcut((Join-Path $desktop ($entry[0]+'.lnk')))
    $link.TargetPath=$power
    $link.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$script+'" -Root "'+$Root+'"'+$entry[1]
    $link.WorkingDirectory=$Root;$link.IconLocation=(Join-Path $Root 'ZyonRoblox.exe')+',0';$link.WindowStyle=$entry[2];$link.Save()
}
Write-Host 'Atalhos Zyon criados na area de trabalho.'
