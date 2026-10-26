# PowerShell 5.1+ / Install-ZyonCloud.ps1 / Windows publisher / install keys, GitHub repository and update launcher.
param([Parameter(Mandatory=$true)][string]$Root,[string]$Owner='joaomarcoslin8-eng',[string]$Repository='zyon-updates',[ValidateSet('stable','beta')][string]$Channel='beta',[string]$Version='1.0.1',[switch]$Publish)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Cloud.Common.ps1')
$Root=Assert-CloudRoot $Root
if ($env:OS -ne 'Windows_NT') { throw 'Execute este instalador no Windows onde esta o programa.' }
if ($Owner -notmatch '^[A-Za-z0-9-]+$' -or $Repository -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Nome de repositorio invalido.' }
$install=Join-Path $Root 'tools/cloud';[IO.Directory]::CreateDirectory($install) | Out-Null
$log=Join-Path $Root 'logs/cloud-setup.log';[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($log)) | Out-Null
Start-Transcript -LiteralPath $log -Append | Out-Null
try {
    $cli=Get-Command gh.exe -ErrorAction SilentlyContinue
    if ($cli) { $script:gh=$cli.Source } else {
        Write-Host 'Instalando GitHub CLI portatil para seu usuario...'
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        $release=Invoke-RestMethod -Uri 'https://api.github.com/repos/cli/cli/releases/latest' -Headers @{'User-Agent'='ZyonSetup/1'} -TimeoutSec 20
        $asset=@($release.assets | Where-Object { $_.name -match '^gh_[0-9.]+_windows_amd64\.zip$' })
        $checks=@($release.assets | Where-Object { $_.name -match '_checksums\.txt$' })
        if ($asset.Count -ne 1 -or $checks.Count -ne 1) { throw 'Distribuicao oficial do GitHub CLI nao encontrada.' }
        $ghDir=Join-Path $env:LOCALAPPDATA 'ZyonPublisher/GitHubCLI';[IO.Directory]::CreateDirectory($ghDir) | Out-Null
        $ghZip=Join-Path $ghDir ($asset[0].name);$ghSums=Join-Path $ghDir 'checksums.txt'
        Invoke-WebRequest -UseBasicParsing -Uri $asset[0].browser_download_url -OutFile $ghZip -TimeoutSec 60
        Invoke-WebRequest -UseBasicParsing -Uri $checks[0].browser_download_url -OutFile $ghSums -TimeoutSec 20
        $pattern='^([0-9a-fA-F]{64})\s+\*?'+[regex]::Escape($asset[0].name)+'$'
        $expected=$null
        foreach ($line in [IO.File]::ReadAllLines($ghSums)) { if ($line -match $pattern) { $expected=$Matches[1].ToLowerInvariant() } }
        if (!$expected -or (Get-CloudFileHash $ghZip) -ne $expected) { throw 'GitHub CLI: hash diferente do publicado oficialmente.' }
        Expand-Archive -LiteralPath $ghZip -DestinationPath (Join-Path $ghDir 'app') -Force
        $binaries=@(Get-ChildItem -LiteralPath (Join-Path $ghDir 'app') -Recurse -File -Filter 'gh.exe')
        if ($binaries.Count -ne 1) { throw 'GitHub CLI nao foi extraido corretamente.' }
        $script:gh=$binaries[0].FullName
    }
    function Invoke-SetupGh([string[]]$Arguments) {
        $old=$ErrorActionPreference;$err=Join-Path $env:TEMP ('zyon-gh-'+[guid]::NewGuid().ToString('N')+'.txt')
        try {
            $ErrorActionPreference='Continue';$output=@(& $script:gh @Arguments 2>$err);$exit=$LASTEXITCODE
            if ($exit -ne 0) { throw ('GitHub: '+[IO.File]::ReadAllText($err)) }
            return ($output -join "`n")
        } finally { $ErrorActionPreference=$old;if (Test-Path -LiteralPath $err) { Remove-Item -LiteralPath $err -Force } }
    }
    $login=$null
    try { $login=(Invoke-SetupGh @('api','user','--jq','.login')).Trim() } catch {
        Write-Host 'Entre na conta correta na pagina oficial que o GitHub CLI abrir.'
        & $script:gh auth login --hostname github.com --git-protocol https --web
        if ($LASTEXITCODE -ne 0) { throw 'A autenticacao oficial do GitHub nao foi concluida.' }
        $login=(Invoke-SetupGh @('api','user','--jq','.login')).Trim()
    }
    if ($login -ne $Owner) { throw "Conta autenticada: $login. Este projeto foi configurado para $Owner." }
    $repo=$Owner+'/'+$Repository;$exists=$false
    try { $metadata=Invoke-SetupGh @('api',('repos/'+$repo));$repoInfo=$metadata | ConvertFrom-Json;$exists=$true } catch {
        if ($_.Exception.Message -notmatch '404|Not Found') { throw }
    }
    if (!$exists) {
        Invoke-SetupGh @('repo','create',$repo,'--public','--add-readme','--description','Signed Windows application update packages. No application sources or private signing keys.') | Out-Null
        $repoInfo=(Invoke-SetupGh @('api',('repos/'+$repo))) | ConvertFrom-Json
    }
    if ($repoInfo.private -or !$repoInfo.permissions.push) { throw 'O repositorio precisa ser publico e permitir publicacao por esta conta.' }
    $publisherFile=Join-Path $install 'publisher.json'
    if (Test-Path -LiteralPath $publisherFile) {
        $settings=[IO.File]::ReadAllText($publisherFile) | ConvertFrom-Json
        if ($settings.owner -ne $Owner -or $settings.repository -ne $Repository) { throw 'Existe uma configuracao de publicacao para outro repositorio.' }
        $cert=Get-Item -LiteralPath ('Cert:\CurrentUser\My\'+$settings.certificateThumbprint)
        if (!$cert.HasPrivateKey) { throw 'A chave privada anterior precisa ser recuperada.' }
    } else {
        foreach ($alias in @('channel-stable','channel-beta')) {
            $found=$false
            try { Invoke-SetupGh @('release','view',$alias,'--repo',$repo,'--json','tagName') | Out-Null;$found=$true } catch { if ($_.Exception.Message -notmatch '404|not found|release not found') { throw } }
            if ($found) { throw 'Este repositorio ja tem atualizacoes. Recupere publisher.json e a chave original; nao gere outra chave.' }
        }
        Write-Host 'Criando chave RSA de assinatura no armazenamento do seu usuario Windows...'
        $cert=New-SelfSignedCertificate -Type Custom -Subject 'CN=Zyon Update Signing' -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 -KeyExportPolicy Exportable -KeyUsage DigitalSignature -CertStoreLocation 'Cert:\CurrentUser\My' -NotAfter (Get-Date).AddYears(5)
        $settings=[ordered]@{owner=$Owner;repository=$Repository;certificateThumbprint=$cert.Thumbprint;fingerprint=(Get-CloudHash ($cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert)));sequence=0;ghPath=$script:gh}
    }
    $settings.ghPath=$script:gh;Write-CloudJson $publisherFile $settings
    $public=[Convert]::ToBase64String($cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert));$cert.Dispose()
    $trust=[ordered]@{owner=$Owner;repository=$Repository;channel=$Channel;certificate=$public;fingerprint=$settings.fingerprint}
    $trustFile=Join-Path $install 'update-trust.json';Write-CloudJson $trustFile $trust
    foreach ($name in @('Cloud.Common.ps1','Publish-Cloud.ps1','Export-SigningKey.ps1','Build-ClientBundle.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $install $name) -Force }
    $launcher=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Update-Launch.ps1')).Replace('@@TRUST_HASH@@',(Get-CloudFileHash $trustFile))
    [IO.File]::WriteAllText((Join-Path $install 'Update-Launch.ps1'),$launcher,[Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Client-Shortcuts.ps1') -Destination (Join-Path $Root 'tools/Client-Shortcuts.ps1') -Force
    & (Join-Path $Root 'tools/Client-Shortcuts.ps1') -Root $Root
    Write-Host "Configurado: https://github.com/$repo"
    if ($Publish) {
        & (Join-Path $install 'Publish-Cloud.ps1') -Root $Root -Version $Version -Channel $Channel
        & (Join-Path $install 'Build-ClientBundle.ps1') -Root $Root
    }
    Write-Host 'Use o atalho Zyon - iniciar para verificar atualizacoes antes de abrir o programa.'
    Write-Host 'A chave privada permanece no seu usuario Windows. Use Export-SigningKey.ps1 para backup protegido.'
} finally { Stop-Transcript | Out-Null }
