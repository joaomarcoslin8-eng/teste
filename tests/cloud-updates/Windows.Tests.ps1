# Windows PowerShell 5.1 / Windows.Tests.ps1 / native certificate, PE version and update integration.
param([string]$Workspace=(Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $Workspace 'cloud-updates/Cloud.Common.ps1')
$work=Join-Path $env:TEMP ('zyon-native-test-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($work) | Out-Null
$cert=$null;$private=$null;$provider=$null
try {
    $cert=New-SelfSignedCertificate -Type Custom -Subject 'CN=Zyon CI Test Only' -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 -KeyUsage DigitalSignature -CertStoreLocation 'Cert:\CurrentUser\My' -NotAfter (Get-Date).AddDays(1)
    $private=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    $public=$cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $root=Join-Path $work 'app';$payload=Join-Path $work 'payload'
    foreach ($dir in @('config','docs')) { [IO.Directory]::CreateDirectory((Join-Path $root $dir)) | Out-Null;[IO.Directory]::CreateDirectory((Join-Path $payload $dir)) | Out-Null }
    $offsets=Get-Content -LiteralPath (Join-Path $Workspace 'tests/cloud-updates/schema-fixture.json') -Raw | ConvertFrom-Json
    Write-CloudJson (Join-Path $payload 'config/offsets.json') $offsets;Write-CloudJson (Join-Path $root 'config/offsets.json') $offsets
    [IO.File]::WriteAllText((Join-Path $root 'config/ui.json'),'{"language":"en"}')
    [IO.File]::WriteAllText((Join-Path $root 'ZyonRoblox.exe'),'old executable')
    [IO.File]::WriteAllText((Join-Path $root 'docs/THIRD-PARTY-NOTICES.txt'),'old notices')
    [IO.File]::WriteAllText((Join-Path $payload 'docs/THIRD-PARTY-NOTICES.txt'),'new notices')
    $provider=New-Object Microsoft.CSharp.CSharpCodeProvider
    $parameters=New-Object CodeDom.Compiler.CompilerParameters
    $parameters.GenerateExecutable=$true;$parameters.OutputAssembly=Join-Path $payload 'ZyonRoblox.exe';$parameters.CompilerOptions='/platform:x64 /optimize+'
    $result=$provider.CompileAssemblyFromSource($parameters,'using System.Reflection; [assembly: AssemblyFileVersion("1.0.1.0")] public static class App { public static void Main() {} }')
    if ($result.Errors.HasErrors) { throw 'Native fixture compilation failed.' }
    $info=[Diagnostics.FileVersionInfo]::GetVersionInfo($parameters.OutputAssembly)
    if ($info.FileVersion -ne '1.0.1.0') { throw 'Native executable version does not match.' }
    $zip=Join-Path $work 'package.zip';Compress-Archive -LiteralPath @((Join-Path $payload 'ZyonRoblox.exe'),(Join-Path $payload 'config'),(Join-Path $payload 'docs')) -DestinationPath $zip
    $stage=Join-Path $work 'verified';Expand-CloudPackage $zip $stage $offsets.version | Out-Null
    $now=[DateTimeOffset]::UtcNow
    $manifest=[ordered]@{schemaVersion=1;minimumUpdaterVersion=1;releaseSequence=1;channel='beta';publishedAt=$now.ToString('o');expiresAt=$now.AddDays(7).ToString('o');packages=@([ordered]@{platform='windows-x64';robloxBuild=$offsets.version;appVersion='1.0.1';url='https://github.com/test-owner/zyon-updates/releases/download/v1/package.zip';sha256=(Get-CloudFileHash $zip);size=(Get-Item $zip).Length;exeSha256=(Get-CloudFileHash (Join-Path $payload 'ZyonRoblox.exe'));offsetsSha256=(Get-CloudFileHash (Join-Path $payload 'config/offsets.json'))})}
    $manifestPath=Join-Path $work 'manifest.json';Write-CloudJson $manifestPath $manifest
    $signaturePath=$manifestPath+'.sig';[IO.File]::WriteAllBytes($signaturePath,$private.SignData([IO.File]::ReadAllBytes($manifestPath),[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1))
    Read-CloudManifest $manifestPath $signaturePath ([Convert]::ToBase64String($public)) (Get-CloudHash $public) 'test-owner' 'zyon-updates' 'beta' | Out-Null
    $testTools=Join-Path $work 'client';[IO.Directory]::CreateDirectory($testTools) | Out-Null
    $trust=[ordered]@{owner='test-owner';repository='zyon-updates';channel='beta';certificate=[Convert]::ToBase64String($public);fingerprint=(Get-CloudHash $public)}
    $trustFile=Join-Path $testTools 'update-trust.json';Write-CloudJson $trustFile $trust
    $client=[IO.File]::ReadAllText((Join-Path $Workspace 'cloud-updates/Update-Launch.ps1')).Replace('@@TRUST_HASH@@',(Get-CloudFileHash $trustFile))
    [IO.File]::WriteAllText((Join-Path $testTools 'Update-Launch.ps1'),$client)
    $realCommon=(Join-Path $Workspace 'cloud-updates/Cloud.Common.ps1').Replace("'","''")
    $wrapper=". '$realCommon'`r`n"+@'
function Receive-CloudFile([string]$Url,[string]$Destination,[long]$MaximumBytes,[int]$TimeoutSeconds) {
    $source=if ($Url.EndsWith('.json.sig')) { '@@SIGNATURE@@' } elseif ($Url.EndsWith('.json')) { '@@MANIFEST@@' } else { '@@ZIP@@' }
    Copy-Item -LiteralPath $source -Destination $Destination
}
'@
    $wrapper=$wrapper.Replace('@@SIGNATURE@@',$signaturePath.Replace("'","''")).Replace('@@MANIFEST@@',$manifestPath.Replace("'","''")).Replace('@@ZIP@@',$zip.Replace("'","''"))
    [IO.File]::WriteAllText((Join-Path $testTools 'Cloud.Common.ps1'),$wrapper)
    $powershell=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testTools 'Update-Launch.ps1') -Root $root
    if ($LASTEXITCODE -ne 0) { throw 'Native update subprocess failed.' }
    if ((Get-CloudFileHash (Join-Path $root 'ZyonRoblox.exe')) -ne (Get-CloudFileHash (Join-Path $payload 'ZyonRoblox.exe'))) { throw 'End-to-end update did not install the verified executable.' }
    if ([IO.File]::ReadAllText((Join-Path $root 'config/ui.json')) -ne '{"language":"en"}') { throw 'User settings changed.' }
    $state=Get-Content -LiteralPath (Join-Path $root 'config/update-state.json') -Raw | ConvertFrom-Json
    if ($state.lastInstalledSequence -ne 1) { throw 'Installation state was not recorded.' }
    Write-Host 'PASS native Windows PowerShell 5.1: certificate, signed manifest, x64 PE, version, full update and preference preservation.'
} finally {
    if ($private) { $private.Dispose() };if ($provider) { $provider.Dispose() }
    if ($cert) { Remove-Item -LiteralPath ('Cert:\CurrentUser\My\'+$cert.Thumbprint) -DeleteKey -Force;$cert.Dispose() }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
