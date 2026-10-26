# PowerShell 7 / Common.Tests.ps1 / cross-platform / signatures, package restrictions and rollback.
param([string]$Workspace=(Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $Workspace 'cloud-updates/Cloud.Common.ps1')
$count=0
function Check([bool]$Condition,[string]$Name) { if (!$Condition) { throw ('FAIL '+$Name) };$script:count++;Write-Host ('PASS '+$Name) }
function Reject([scriptblock]$Body,[string]$Name) { $rejected=$false;try { & $Body | Out-Null } catch { $rejected=$true };Check $rejected $Name }
$temp=Join-Path ([IO.Path]::GetTempPath()) ('zyon-cloud-tests-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($temp) | Out-Null
$key=[Security.Cryptography.RSA]::Create(3072)
$request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Zyon Test Only',$key,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
$cert=$request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1),[DateTimeOffset]::UtcNow.AddDays(1));$certBytes=$cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert)
$pub=[Convert]::ToBase64String($certBytes);$pin=Get-CloudHash $certBytes
$build='version-1234567890abcdef'
$manifestPath=Join-Path $temp 'manifest.json';$sigPath=Join-Path $temp 'manifest.sig'
function Make-Manifest {
    $now=[DateTimeOffset]::UtcNow
    return [ordered]@{schemaVersion=1;minimumUpdaterVersion=1;releaseSequence=5;channel='beta';publishedAt=$now.ToString('o');expiresAt=$now.AddDays(7).ToString('o');packages=@([ordered]@{platform='windows-x64';robloxBuild=$build;appVersion='1.0.1';url='https://github.com/test-owner/zyon-updates/releases/download/v1/package.zip';sha256=('a'*64);exeSha256=('b'*64);offsetsSha256=('c'*64);size=1234})}
}
function Sign-Test($Value) {
    Write-CloudJson $manifestPath $Value
    [IO.File]::WriteAllBytes($sigPath,$key.SignData([IO.File]::ReadAllBytes($manifestPath),[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1))
}
try {
    Sign-Test (Make-Manifest)
    $value=Read-CloudManifest $manifestPath $sigPath $pub $pin 'test-owner' 'zyon-updates' 'beta' 4
    Check ($value.releaseSequence -eq 5) 'valid RSA-3072 manifest is accepted'
    Reject { Read-CloudManifest $manifestPath $sigPath $pub ('0'*64) 'test-owner' 'zyon-updates' 'beta' } 'public-key pin mismatch rejected'
    Reject { Read-CloudManifest $manifestPath $sigPath $pub $pin 'test-owner' 'zyon-updates' 'stable' } 'wrong channel rejected'
    Reject { Read-CloudManifest $manifestPath $sigPath $pub $pin 'test-owner' 'zyon-updates' 'beta' 6 } 'replayed older sequence rejected'
    [IO.File]::AppendAllText($manifestPath,' ')
    Reject { Read-CloudManifest $manifestPath $sigPath $pub $pin 'test-owner' 'zyon-updates' 'beta' } 'tampering exact manifest bytes rejected'
    foreach ($case in @('expiry','future','schema','protocol','fraction','stringSequence','duplicate','foreignURL','hash','size','build')) {
        $m=Make-Manifest
        switch ($case) {
            expiry {$m.publishedAt=[DateTimeOffset]::UtcNow.AddDays(-3).ToString('o');$m.expiresAt=[DateTimeOffset]::UtcNow.AddDays(-1).ToString('o')}
            future {$m.publishedAt=[DateTimeOffset]::UtcNow.AddDays(1).ToString('o')}
            schema {$m.schemaVersion=2}
            protocol {$m.minimumUpdaterVersion=2}
            fraction {$m.releaseSequence=5.5}
            stringSequence {$m.releaseSequence='5'}
            duplicate {$m.packages+=,$m.packages[0]}
            foreignURL {$m.packages[0].url='https://github.com/someone/else/releases/download/v1/p.zip'}
            hash {$m.packages[0].sha256='INVALID'}
            size {$m.packages[0].size=52428801}
            build {$m.packages[0].robloxBuild='version-wrong'}
        }
        Sign-Test $m
        Reject { Read-CloudManifest $manifestPath $sigPath $pub $pin 'test-owner' 'zyon-updates' 'beta' } ('invalid '+$case+' rejected')
    }
    $m=Make-Manifest;$m.publishedAt=[DateTimeOffset]::UtcNow.AddDays(-3).ToString('o');$m.expiresAt=[DateTimeOffset]::UtcNow.AddDays(-1).ToString('o');Sign-Test $m
    Check ((Read-CloudManifest $manifestPath $sigPath $pub $pin 'test-owner' 'zyon-updates' 'beta' 0 -AllowExpired).releaseSequence -eq 5) 'publisher can recover authentic expired metadata'
    foreach ($url in @('http://github.com/test-owner/zyon-updates/releases/download/v1/p.zip','https://github.com.evil.example/test-owner/zyon-updates/releases/download/v1/p.zip','https://user@github.com/test-owner/zyon-updates/releases/download/v1/p.zip','https://github.com/test-owner/zyon-updates-other/releases/download/v1/p.zip')) {
        Reject { Assert-CloudUrl $url 'test-owner' 'zyon-updates' } 'unexpected download origin rejected'
    }
    $stage=Join-Path $temp 'stage';[IO.Directory]::CreateDirectory((Join-Path $stage 'config')) | Out-Null;[IO.Directory]::CreateDirectory((Join-Path $stage 'docs')) | Out-Null
    $offsets=Get-Content -LiteralPath (Join-Path $Workspace 'tests/cloud-updates/schema-fixture.json') -Raw | ConvertFrom-Json;$offsets.version=$build
    Write-CloudJson (Join-Path $stage 'config/offsets.json') $offsets
    [IO.File]::WriteAllText((Join-Path $stage 'docs/THIRD-PARTY-NOTICES.txt'),'test license')
    $pe=New-Object byte[] 128;$pe[0]=0x4d;$pe[1]=0x5a;$pe[60]=64;$pe[64]=0x50;$pe[65]=0x45;$pe[68]=0x64;$pe[69]=0x86
    [IO.File]::WriteAllBytes((Join-Path $stage 'ZyonRoblox.exe'),$pe)
    $zip=Join-Path $temp 'valid.zip';Compress-Archive -LiteralPath @((Join-Path $stage 'ZyonRoblox.exe'),(Join-Path $stage 'config'),(Join-Path $stage 'docs')) -DestinationPath $zip
    $expanded=Join-Path $temp 'expanded';$files=@(Expand-CloudPackage $zip $expanded $build)
    Check ($files.Count -eq 3) 'valid x64 package extracted with exact whitelist'
    Reject { Expand-CloudPackage $zip (Join-Path $temp 'wrong-build') 'version-fedcba0987654321' } 'offsets for another exact build rejected'
    $malicious=Join-Path $temp 'traversal.zip';$archive=[IO.Compression.ZipFile]::Open($malicious,[IO.Compression.ZipArchiveMode]::Create)
    $entry=$archive.CreateEntry('../outside.txt');$writer=[IO.StreamWriter]::new($entry.Open());$writer.Write('bad');$writer.Dispose();$archive.Dispose()
    Reject { Expand-CloudPackage $malicious (Join-Path $temp 'traversal') $build } 'path traversal rejected'
    Check (!(Test-Path -LiteralPath (Join-Path $temp 'outside.txt'))) 'traversal wrote no file outside staging'
    $root=Join-Path $temp 'app';[IO.Directory]::CreateDirectory((Join-Path $root 'config')) | Out-Null;[IO.Directory]::CreateDirectory((Join-Path $root 'docs')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $root 'ZyonRoblox.exe'),'old exe');[IO.File]::WriteAllText((Join-Path $root 'config/offsets.json'),'old offsets');[IO.File]::WriteAllText((Join-Path $root 'config/ui.json'),'{"language":"en"}');[IO.File]::WriteAllText((Join-Path $root 'docs/THIRD-PARTY-NOTICES.txt'),'old notice')
    $backup=Install-CloudPackage $root $expanded $build
    Check ((Get-CloudFileHash (Join-Path $root 'ZyonRoblox.exe')) -eq (Get-CloudFileHash (Join-Path $stage 'ZyonRoblox.exe'))) 'verified package installed'
    Check ([IO.File]::ReadAllText((Join-Path $root 'config/ui.json')) -eq '{"language":"en"}') 'user language preference preserved'
    Check ([IO.File]::ReadAllText((Join-Path $backup 'ZyonRoblox.exe')) -eq 'old exe') 'original executable backed up exactly'
    $journal=Join-Path $backup 'transaction.json';$value=Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json;$value.status='prepared';Write-CloudJson $journal $value
    Repair-CloudTransactions $root
    Check ([IO.File]::ReadAllText((Join-Path $root 'ZyonRoblox.exe')) -eq 'old exe') 'unfinished transaction restored on next launch'
    Check ((Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json).status -eq 'restored') 'recovery journal completed'
    Remove-Item -LiteralPath (Join-Path $root 'docs/THIRD-PARTY-NOTICES.txt');[IO.Directory]::CreateDirectory((Join-Path $root 'docs/THIRD-PARTY-NOTICES.txt')) | Out-Null
    Reject { Install-CloudPackage $root $expanded $build } 'failure during third file replacement reported'
    Check ([IO.File]::ReadAllText((Join-Path $root 'ZyonRoblox.exe')) -eq 'old exe') 'partial replacement rolled executable back'
    Check ([IO.File]::ReadAllText((Join-Path $root 'config/offsets.json')) -eq 'old offsets') 'partial replacement rolled offsets back'
    Check ([IO.File]::ReadAllText((Join-Path $root 'config/ui.json')) -eq '{"language":"en"}') 'rollback preserved user settings'
    Write-Host "$count cloud verification checks passed"
} finally { $cert.Dispose();$key.Dispose();Remove-Item -LiteralPath $temp -Recurse -Force }
