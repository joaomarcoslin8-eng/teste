# PowerShell 5.1+ / Publish-Cloud.ps1 / Windows publisher / compile, sign and publish an immutable release.
param([Parameter(Mandatory=$true)][string]$Root,[ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version='1.0.1',[ValidateSet('stable','beta')][string]$Channel='stable',[switch]$SkipCompile)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Cloud.Common.ps1')
function Invoke-ZyonGh([string[]]$Arguments) {
    $err=Join-Path $env:TEMP ('zyon-gh-'+[guid]::NewGuid().ToString('N')+'.txt');$old=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue';$output=@(& $script:gh @Arguments 2>$err);$exit=$LASTEXITCODE
        if ($exit -ne 0) { throw ('GitHub CLI: '+([IO.File]::ReadAllText($err))) }
        return ($output -join "`n")
    } finally { $ErrorActionPreference=$old;if (Test-Path -LiteralPath $err) { Remove-Item -LiteralPath $err -Force } }
}
$publisherMutex=[Threading.Mutex]::new($false,'Local\ZyonPublisher-'+(Get-CloudHash ([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Root).ToLowerInvariant()))).Substring(0,24))
$publisherHeld=$false
try {
    try { $publisherHeld=$publisherMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $publisherHeld=$true }
    if (!$publisherHeld) { throw 'Outra publicacao ja esta em andamento.' }
$Root=Assert-CloudRoot $Root
$settingsPath=Join-Path $PSScriptRoot 'publisher.json';$settings=[IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
$script:gh=$settings.ghPath
$login=(Invoke-ZyonGh @('api','user','--jq','.login')).Trim()
if ($login -ne $settings.owner) { throw 'A conta autenticada nao corresponde ao publicador configurado.' }
$cert=Get-Item -LiteralPath ('Cert:\CurrentUser\My\'+$settings.certificateThumbprint)
$certData=$cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert)
if ((Get-CloudHash $certData) -ne $settings.fingerprint -or !$cert.HasPrivateKey) { throw 'Chave privada do publicador indisponivel ou diferente.' }
if (!$SkipCompile) {
    if (@(Get-Process -Name ZyonRoblox -ErrorAction SilentlyContinue).Count) { throw 'Feche o Zyon antes de compilar.' }
    $v=[Version]$Version;$header=Join-Path $Root 'assets/version.h'
    $oldHeader=[IO.File]::ReadAllBytes($header)
    try {
        [IO.File]::WriteAllText($header,"// Windows release version.`r`n#define ZYON_VERSION_NUM $($v.Major),$($v.Minor),$($v.Build),0`r`n#define ZYON_VERSION_TEXT `"$Version.0\0`"`r`n",[Text.UTF8Encoding]::new($false))
        Push-Location $Root
        try { & $env:ComSpec /d /c 'tools\Compilar.cmd --no-pause';if ($LASTEXITCODE -ne 0) { throw 'A compilacao falhou.' } } finally { Pop-Location }
    } catch { [IO.File]::WriteAllBytes($header,$oldHeader);throw }
}
$info=[Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $Root 'ZyonRoblox.exe'))
if (('{0}.{1}.{2}' -f $info.FileMajorPart,$info.FileMinorPart,$info.FileBuildPart) -ne $Version) { throw 'Compile o executavel com a versao solicitada antes de publicar.' }
$config=[IO.File]::ReadAllText((Join-Path $Root 'config/offsets.json')) | ConvertFrom-Json
Assert-CloudOffsets (Join-Path $Root 'config/offsets.json') $config.version | Out-Null
$sequence=[long]$settings.sequence+1;$settings.sequence=$sequence;Write-CloudJson $settingsPath $settings
$tag='v'+$Version+'-'+$Channel+'-r'+$sequence
$output=Join-Path $Root ('build/cloud/'+$tag);[IO.Directory]::CreateDirectory($output) | Out-Null
$stage=Join-Path $output 'package';[IO.Directory]::CreateDirectory((Join-Path $stage 'config')) | Out-Null;[IO.Directory]::CreateDirectory((Join-Path $stage 'docs')) | Out-Null
foreach ($name in @('ZyonRoblox.exe','config/offsets.json','docs/THIRD-PARTY-NOTICES.txt')) { Copy-Item -LiteralPath (Join-Path $Root $name) -Destination (Join-Path $stage $name) }
$asset='ZyonRoblox-'+$Version+'-'+$config.version+'-x64.zip';$zip=Join-Path $output $asset
Compress-Archive -LiteralPath @((Join-Path $stage 'ZyonRoblox.exe'),(Join-Path $stage 'config'),(Join-Path $stage 'docs')) -DestinationPath $zip
$verified=Join-Path $output 'verified';Expand-CloudPackage $zip $verified $config.version | Out-Null
Remove-Item -LiteralPath $stage,$verified -Recurse -Force
$repo=$settings.owner+'/'+$settings.repository
$entry=[ordered]@{platform='windows-x64';robloxBuild=$config.version;appVersion=$Version;url=('https://github.com/'+$repo+'/releases/download/'+$tag+'/'+$asset);sha256=(Get-CloudFileHash $zip);size=(Get-Item -LiteralPath $zip).Length;exeSha256=(Get-CloudFileHash (Join-Path $Root 'ZyonRoblox.exe'));offsetsSha256=(Get-CloudFileHash (Join-Path $Root 'config/offsets.json'))}
$packages=@()
$alias='channel-'+$Channel
# Retain packages for other exact builds, but only from a previously signed manifest.
$oldManifest=Join-Path $output 'previous.json';$oldSig=Join-Path $output 'previous.sig'
$existingAlias=$false
try { Invoke-ZyonGh @('release','view',$alias,'--repo',$repo,'--json','tagName') | Out-Null;$existingAlias=$true } catch {
    if ($_.Exception.Message -notmatch '404|not found|release not found') { throw }
}
if ($existingAlias) {
    $base='https://github.com/'+$repo+'/releases/download/'+$alias+'/'+$Channel+'.json'
    Receive-CloudFile $base $oldManifest 65536 20;Receive-CloudFile ($base+'.sig') $oldSig 4096 20
    $previous=Read-CloudManifest $oldManifest $oldSig ([Convert]::ToBase64String($certData)) $settings.fingerprint $settings.owner $settings.repository $Channel 0 -AllowExpired
    if ([long]$previous.releaseSequence -ge $sequence) { throw 'Estado local antigo. Recupere a sequencia do publicador antes de publicar.' }
    $packages=@($previous.packages | Where-Object { $_.robloxBuild -ne $config.version })
}
$packages+=,$entry
if ($packages.Count -gt 32) { throw 'Limite de builds por canal atingido.' }
$now=[DateTimeOffset]::UtcNow
$manifest=[ordered]@{schemaVersion=1;minimumUpdaterVersion=1;releaseSequence=$sequence;channel=$Channel;publishedAt=$now.ToString('o');expiresAt=$now.AddDays(30).ToString('o');packages=$packages}
$manifestPath=Join-Path $output ($Channel+'.json');Write-CloudJson $manifestPath $manifest
$key=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
try { $signature=$key.SignData([IO.File]::ReadAllBytes($manifestPath),[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1);[IO.File]::WriteAllBytes(($manifestPath+'.sig'),$signature) } finally { $key.Dispose();$cert.Dispose() }
$notes=Join-Path $output 'release.txt';[IO.File]::WriteAllText($notes,('Zyon '+$Version+'; exact Roblox build '+$config.version+'; signed release '+$sequence))
Invoke-ZyonGh @('release','create',$tag,'--repo',$repo,'--draft','--title',('Zyon '+$Version+' '+$Channel),'--notes-file',$notes) | Out-Null
Invoke-ZyonGh @('release','upload',$tag,$zip,$manifestPath,($manifestPath+'.sig'),'--repo',$repo) | Out-Null
$edit=@('release','edit',$tag,'--repo',$repo,'--draft=false','--latest=false');if ($Channel -eq 'beta') { $edit+='--prerelease' }
Invoke-ZyonGh $edit | Out-Null
# Check the public artifact before moving the channel pointer.
$roundTrip=Join-Path $output 'remote-verified.zip';Receive-CloudFile $entry.url $roundTrip $entry.size 60
if ((Get-CloudFileHash $roundTrip) -ne $entry.sha256) { throw 'O pacote publicado nao passou na verificacao de download.' }
Remove-Item -LiteralPath $roundTrip -Force
if (!$existingAlias) {
    $create=@('release','create',$alias,'--repo',$repo,'--title',('Zyon '+$Channel+' update channel'),'--notes','Signed update channel metadata.','--latest=false');if ($Channel -eq 'beta') { $create+='--prerelease' }
    Invoke-ZyonGh $create | Out-Null
}
Invoke-ZyonGh @('release','upload',$alias,($manifestPath+'.sig'),$manifestPath,'--clobber','--repo',$repo) | Out-Null
Write-Host ('Publicado: https://github.com/'+$repo+'/releases/tag/'+$tag)
Write-Host ('Canal: https://github.com/'+$repo+'/releases/download/'+$alias+'/'+$Channel+'.json')

} finally { if ($publisherHeld) { $publisherMutex.ReleaseMutex() };$publisherMutex.Dispose() }
