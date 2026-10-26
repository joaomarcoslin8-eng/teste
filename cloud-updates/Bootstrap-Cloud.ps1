# PowerShell 5.1+ / Bootstrap-Cloud.ps1 / Windows / download only pinned setup files and run the local installer.
param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{40}$')][string]$SourceRevision,
    [string]$Owner='joaomarcoslin8-eng',
    [string]$Repository='zyon-updates',
    [ValidateSet('stable','beta')][string]$Channel='beta',
    [string]$Version='1.0.1',
    [switch]$Publish
)
$ErrorActionPreference='Stop'
$hashes=@'
{"Cloud.Common.ps1":"27a80a4887a36fc10b2e63a4305fe0a2fadd725115f30c805b70fbcfe009a569","Update-Launch.ps1":"00c644fcccf5cd94ff84812be2ead74e393123ce256351add87e0037d7dbd45c","Publish-Cloud.ps1":"08850058b437158c2c5087865a934d3d0822ec6147c71b44e45dea6e146b25f8","Client-Shortcuts.ps1":"d49f5fe81ac46ff61ee3cec682e57da41d935ad06e331ee58126c72614476829","Install-ZyonCloud.ps1":"df32a97b1444c58bab8ab71a47748d6adb574c29d894219c3d331d25b3994399","Export-SigningKey.ps1":"032dcfb4f2c2273bf4b04c6ddb1008ecc82f51372812d5fe78e30d2772403ba0","Build-ClientBundle.ps1":"be5d7354f9e771819edd5adbb0e854e068960fc5e243cc41e2dea67ffabe12ce"}
'@ | ConvertFrom-Json
$stage=Join-Path $env:TEMP ('zyon-cloud-setup-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($stage) | Out-Null
try {
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    foreach ($item in $hashes.PSObject.Properties) {
        $url='https://raw.githubusercontent.com/joaomarcoslin8-eng/teste/'+$SourceRevision+'/cloud-updates/'+$item.Name
        $file=Join-Path $stage $item.Name
        Write-Host ('Preparando '+$item.Name)
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $file -TimeoutSec 30
        if ((Get-Item -LiteralPath $file).Length -gt 131072 -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $item.Value) { throw ('Arquivo de instalacao alterado: '+$item.Name) }
    }
    $power=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $stage 'Install-ZyonCloud.ps1'),'-Root',$Root,'-Owner',$Owner,'-Repository',$Repository,'-Channel',$Channel,'-Version',$Version)
    if ($Publish) { $arguments+='-Publish' }
    & $power @arguments
    if ($LASTEXITCODE -ne 0) { throw ('Instalacao interrompida. Consulte '+(Join-Path $Root 'logs/cloud-setup.log')) }
} finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force } }
