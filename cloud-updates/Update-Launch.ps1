# PowerShell 5.1+ / Update-Launch.ps1 / Windows / verify updates then launch the existing application.
param([Parameter(Mandatory=$true)][string]$Root,[switch]$Launch,[switch]$Force)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Cloud.Common.ps1')
$mutex=$null;$held=$false;$work=$null;$canLaunch=$false
function Write-UpdateLog([string]$Message) {
    try { [IO.Directory]::CreateDirectory((Join-Path $Root 'logs')) | Out-Null;Add-Content -LiteralPath (Join-Path $Root 'logs/updates.log') -Value ([DateTime]::UtcNow.ToString('o')+' '+$Message) -Encoding UTF8 } catch {}
}
try {
    $Root=Assert-CloudRoot $Root
    $trust=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'update-trust.json')) | ConvertFrom-Json
    # The hash of this trust file is pinned in the installed launcher script.
    $expectedTrust='@@TRUST_HASH@@'
    if ($expectedTrust -notmatch '^[0-9a-f]{64}$' -or (Get-CloudFileHash (Join-Path $PSScriptRoot 'update-trust.json')) -ne $expectedTrust) { throw 'Configuracao de confianca alterada; reinstale o verificador pelo instalador original.' }
    if ($trust.owner -notmatch '^[A-Za-z0-9-]+$' -or $trust.repository -notmatch '^[A-Za-z0-9_.-]+$' -or $trust.channel -notin @('stable','beta')) { throw 'Repositorio ou canal invalido.' }
    $rootHash=Get-CloudHash ([Text.Encoding]::UTF8.GetBytes($Root.ToLowerInvariant()))
    $mutex=[Threading.Mutex]::new($false,'Local\ZyonCloud-'+$rootHash.Substring(0,24))
    try { $held=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held=$true }
    if (!$held) { throw 'Outra verificacao ja esta em andamento.' }
    $active=@(Get-Process -Name ZyonRoblox -ErrorAction SilentlyContinue)
    foreach ($process in $active) {
        if (!$process.Path -or [IO.Path]::GetFullPath($process.Path) -eq (Join-Path $Root 'ZyonRoblox.exe')) { throw 'Feche o Zyon antes de atualizar ou iniciar outra instancia.' }
    }
    $canLaunch=$true
    Repair-CloudTransactions $Root
    $roblox=@(Get-Process -Name RobloxPlayerBeta -ErrorAction SilentlyContinue)
    if ($roblox.Count -gt 1) { throw 'Mantenha apenas um cliente Roblox aberto para selecionar o build.' }
    if ($roblox.Count -eq 1) {
        if (!$roblox[0].Path) { throw 'Nao foi possivel identificar o build do Roblox.' }
        $build=Split-Path (Split-Path $roblox[0].Path -Parent) -Leaf
    } else { $build=([IO.File]::ReadAllText((Join-Path $Root 'config/offsets.json')) | ConvertFrom-Json).version }
    if ($build -notmatch '^version-[0-9a-f]{16}$') { throw 'Build do Roblox invalido.' }
    $statePath=Join-Path $Root 'config/update-state.json'
    $state=[ordered]@{sequence=0;lastAttemptUtc='2000-01-01T00:00:00Z';lastInstalledSequence=0;lastBuild=''}
    if (Test-Path -LiteralPath $statePath) {
        if ((Get-Item -LiteralPath $statePath).Length -gt 65536) { throw 'Estado de atualizacao invalido.' }
        $saved=[IO.File]::ReadAllText($statePath) | ConvertFrom-Json
        $state.sequence=[long]$saved.sequence;$state.lastAttemptUtc=[string]$saved.lastAttemptUtc;$state.lastInstalledSequence=[long]$saved.lastInstalledSequence
        if ($saved.PSObject.Properties['lastBuild']) { $state.lastBuild=[string]$saved.lastBuild }
    }
    $recent=([DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse($state.lastAttemptUtc)).TotalMinutes
    if ($Force -or $recent -ge 30 -or $recent -lt 0 -or $state.lastBuild -ne $build) {
        $state.lastAttemptUtc=[DateTimeOffset]::UtcNow.ToString('o');$state.lastBuild=$build;Write-CloudJson $statePath $state
        $work=Join-Path $Root ('build/update-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($work) | Out-Null
        $url='https://github.com/'+$trust.owner+'/'+$trust.repository+'/releases/download/channel-'+$trust.channel+'/'+$trust.channel+'.json'
        $manifestFile=Join-Path $work 'manifest.json';$signatureFile=Join-Path $work 'manifest.sig'
        Write-Host 'Verificando atualizacoes assinadas...'
        Receive-CloudFile $url $manifestFile 65536 8
        Receive-CloudFile ($url+'.sig') $signatureFile 4096 8
        $manifest=Read-CloudManifest $manifestFile $signatureFile $trust.certificate $trust.fingerprint $trust.owner $trust.repository $trust.channel $state.sequence
        $state.sequence=[long]$manifest.releaseSequence;Write-CloudJson $statePath $state
        $packages=@($manifest.packages | Where-Object { $_.robloxBuild -eq $build })
        if ($packages.Count -ne 1) { throw "Ainda nao ha atualizacao validada para $build. Arquivos atuais preservados." }
        $package=$packages[0]
        $same=(Get-CloudFileHash (Join-Path $Root 'ZyonRoblox.exe')) -eq $package.exeSha256 -and (Get-CloudFileHash (Join-Path $Root 'config/offsets.json')) -eq $package.offsetsSha256
        if (!$same) {
            $zip=Join-Path $work 'update.zip'
            Receive-CloudFile $package.url $zip ([long]$package.size) 60
            if ((Get-Item -LiteralPath $zip).Length -ne [long]$package.size -or (Get-CloudFileHash $zip) -ne $package.sha256) { throw 'Tamanho ou hash do pacote nao corresponde ao manifesto assinado.' }
            $stage=Join-Path $work 'staged';Expand-CloudPackage $zip $stage $build | Out-Null
            if ((Get-CloudFileHash (Join-Path $stage 'ZyonRoblox.exe')) -ne $package.exeSha256 -or (Get-CloudFileHash (Join-Path $stage 'config/offsets.json')) -ne $package.offsetsSha256) { throw 'Arquivos extraidos diferentes dos anunciados.' }
            $info=[Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $stage 'ZyonRoblox.exe'))
            $actual='{0}.{1}.{2}' -f $info.FileMajorPart,$info.FileMinorPart,$info.FileBuildPart
            if ($actual -ne $package.appVersion) { throw 'Versao do executavel diferente da versao anunciada.' }
            foreach ($running in @(Get-Process -Name ZyonRoblox -ErrorAction SilentlyContinue)) {
                if (!$running.Path -or [IO.Path]::GetFullPath($running.Path) -eq (Join-Path $Root 'ZyonRoblox.exe')) { $canLaunch=$false;throw 'O Zyon foi aberto durante o download. Feche o programa e verifique novamente.' }
            }
            $backup=Install-CloudPackage $Root $stage $build
            $state.lastInstalledSequence=[long]$manifest.releaseSequence;Write-CloudJson $statePath $state
            Write-UpdateLog ('Instalado '+$package.appVersion+' para '+$build+'; backup '+$backup)
            Write-Host "Atualizado para $($package.appVersion). Backup: $backup"
        } else { Write-Host 'A publicacao atual ja esta instalada.' }
    }
} catch {
    Write-UpdateLog $_.Exception.Message
    Write-Warning $_.Exception.Message
    if ($Force) {
        try { Add-Type -AssemblyName System.Windows.Forms;[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Zyon - atualizacoes') | Out-Null } catch {}
    }
} finally {
    if ($work -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    if ($held -and $mutex) { $mutex.ReleaseMutex() };if ($mutex) { $mutex.Dispose() }
}
if ($Launch -and $canLaunch) { Start-Process -FilePath (Join-Path $Root 'ZyonRoblox.exe') -WorkingDirectory $Root }
