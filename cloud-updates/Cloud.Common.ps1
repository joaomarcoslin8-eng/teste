# PowerShell 5.1+ / Cloud.Common.ps1 / Windows / signed release verification and atomic installation.
Set-StrictMode -Version 2
function Get-CloudHash([byte[]]$Bytes) {
    $h=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($h.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() } finally { $h.Dispose() }
}
function Get-CloudFileHash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Write-CloudJson([string]$Path,$Value) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    $temp=$Path+'.tmp-'+[guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temp,($Value | ConvertTo-Json -Depth 14),[Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp,$Path,[NullString]::Value) } else { [IO.File]::Move($temp,$Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Assert-CloudRoot([string]$Root) {
    if (![IO.Path]::IsPathRooted($Root)) { throw 'Use o caminho completo da pasta do programa.' }
    $rootPath=[IO.Path]::GetFullPath($Root)
    if (!(Test-Path -LiteralPath (Join-Path $rootPath 'ZyonRoblox.exe')) -or !(Test-Path -LiteralPath (Join-Path $rootPath 'config/offsets.json'))) { throw 'A pasta precisa conter ZyonRoblox.exe e config/offsets.json.' }
    return $rootPath
}
function Assert-CloudUrl([string]$Url,[string]$Owner,[string]$Repo) {
    $uri=[Uri]$Url
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Fragment -or
        !$uri.AbsolutePath.StartsWith('/'+$Owner+'/'+$Repo+'/releases/download/',[StringComparison]::Ordinal)) { throw 'URL de atualizacao fora do repositorio autorizado.' }
}
function Receive-CloudFile([string]$Url,[string]$Destination,[long]$MaximumBytes,[int]$TimeoutSeconds=20) {
    if ($MaximumBytes -lt 1 -or $MaximumBytes -gt 104857600) { throw 'Limite de download invalido.' }
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $uri=[Uri]$Url;$watch=[Diagnostics.Stopwatch]::StartNew()
    for ($redirect=0;$redirect -le 5;$redirect++) {
        if ($uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or
            $uri.Host -notin @('github.com','release-assets.githubusercontent.com','objects.githubusercontent.com')) { throw 'Redirecionamento de download nao autorizado.' }
        $request=[Net.HttpWebRequest]::Create($uri);$request.AllowAutoRedirect=$false
        $request.Timeout=$TimeoutSeconds*1000;$request.ReadWriteTimeout=5000;$request.UserAgent='ZyonUpdater/1'
        $response=$null;$inputStream=$null;$outputStream=$null
        try {
            $response=$request.GetResponse();$status=[int]$response.StatusCode
            if ($status -in @(301,302,303,307,308)) { $uri=[Uri]::new($uri,[string]$response.Headers['Location']);continue }
            if ($status -ne 200 -or $response.ContentLength -gt $MaximumBytes) { throw 'Resposta ou tamanho de download invalido.' }
            $inputStream=$response.GetResponseStream();$outputStream=[IO.File]::Open($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $buffer=New-Object byte[] 65536;$total=0L
            while (($read=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                $total+=$read
                if ($total -gt $MaximumBytes -or $watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw 'Download excedeu o limite de tamanho ou tempo.' }
                $outputStream.Write($buffer,0,$read)
            }
            return
        } finally {
            if ($outputStream) { $outputStream.Dispose() };if ($inputStream) { $inputStream.Dispose() };if ($response) { $response.Dispose() }
        }
    }
    throw 'Excesso de redirecionamentos.'
}
function Read-CloudManifest([string]$ManifestPath,[string]$SignaturePath,[string]$CertificateBase64,[string]$Fingerprint,[string]$Owner,[string]$Repo,[string]$Channel,[long]$MinimumSequence=0,[switch]$AllowExpired) {
    if ((Get-Item -LiteralPath $ManifestPath).Length -gt 65536 -or (Get-Item -LiteralPath $SignaturePath).Length -gt 4096) { throw 'Manifesto ou assinatura grande demais.' }
    $certBytes=[Convert]::FromBase64String($CertificateBase64)
    if ((Get-CloudHash $certBytes) -ne $Fingerprint) { throw 'Chave publica diferente da chave instalada.' }
    $cert=[Security.Cryptography.X509Certificates.X509Certificate2]::new($certBytes)
    $public=$null
    try {
        $public=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($cert)
        if (!$public -or ($public.ExportParameters($false).Modulus.Length*8) -lt 3072) { throw 'Chave de assinatura invalida.' }
        $bytes=[IO.File]::ReadAllBytes($ManifestPath);$signature=[IO.File]::ReadAllBytes($SignaturePath)
        if (!$public.VerifyData($bytes,$signature,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)) { throw 'Assinatura do manifesto invalida.' }
    } finally { if ($public) { $public.Dispose() };$cert.Dispose() }
    $manifest=[Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.minimumUpdaterVersion -gt 1 -or $manifest.channel -ne $Channel -or
        ($manifest.releaseSequence -isnot [int] -and $manifest.releaseSequence -isnot [long]) -or [long]$manifest.releaseSequence -lt 1 -or [long]$manifest.releaseSequence -lt $MinimumSequence) { throw 'Versao, canal ou sequencia de atualizacao invalida.' }
    $now=[DateTimeOffset]::UtcNow;$published=[DateTimeOffset]::Parse([string]$manifest.publishedAt);$expires=[DateTimeOffset]::Parse([string]$manifest.expiresAt)
    if ($published -gt $now.AddMinutes(5) -or (!$AllowExpired -and $expires -le $now) -or $expires -le $published -or $expires -gt $published.AddDays(31)) { throw 'Manifesto expirado ou com datas invalidas.' }
    if (@($manifest.packages).Count -lt 1 -or @($manifest.packages).Count -gt 32) { throw 'Lista de pacotes invalida.' }
    $builds=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($package in $manifest.packages) {
        if ($package.platform -ne 'windows-x64' -or $package.robloxBuild -notmatch '^version-[0-9a-f]{16}$' -or
            $package.sha256 -notmatch '^[0-9a-f]{64}$' -or $package.exeSha256 -notmatch '^[0-9a-f]{64}$' -or $package.offsetsSha256 -notmatch '^[0-9a-f]{64}$' -or [long]$package.size -lt 1 -or [long]$package.size -gt 52428800 -or
            !$builds.Add([string]$package.robloxBuild)) { throw 'Pacote anunciado invalido ou duplicado.' }
        [Version]$package.appVersion | Out-Null
        Assert-CloudUrl $package.url $Owner $Repo
    }
    return $manifest
}
function Assert-CloudOffsets([string]$Path,[string]$Build) {
    if ((Get-Item -LiteralPath $Path).Length -gt 1048576) { throw 'Configuracao grande demais.' }
    $value=[IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if ($value.game -ne 'roblox' -or $value.version -ne $Build -or $value.version -notmatch '^version-[0-9a-f]{16}$' -or !$value.offsets) { throw 'Configuracao nao corresponde ao build anunciado.' }
    foreach ($property in $value.offsets.PSObject.Properties) {
        if ($property.Value -isnot [string] -or $property.Value -notmatch '^0x[0-9a-fA-F]{1,16}$') { throw 'Offset com formato invalido.' }
    }
    foreach ($name in @('FakeDataModel.Pointer','FakeDataModel.RealDataModel','VisualEngine.Pointer','VisualEngine.ViewMatrix','VisualEngine.Dimensions','Instance.ChildrenStart','Instance.ChildrenEnd','Instance.NameContainer','Instance.Name','Instance.ClassDescriptor','Instance.ClassName','Instance.Parent','Player.LocalPlayer','Player.ModelInstance','Player.Team','Humanoid.Health','Humanoid.MaxHealth','Humanoid.Walkspeed','Humanoid.JumpPower','Humanoid.JumpHeight','Humanoid.Jump','Humanoid.UseJumpPower','Humanoid.HumanoidRootPart','Workspace.CurrentCamera','Camera.Rotation','BasePart.Primitive','Primitive.Position','Primitive.AssemblyLinearVelocity','Primitive.Flags','PrimitiveFlags.CanCollide','Primitive.Size','Model.PrimaryPart')) {
        $property=$value.offsets.PSObject.Properties[$name]
        if (!$property -or ($name -ne 'Instance.Name' -and [Convert]::ToUInt64($property.Value.Substring(2),16) -eq 0)) { throw "Offset obrigatorio ausente ou zero: $name" }
    }
    return $value
}
function Expand-CloudPackage([string]$ZipPath,[string]$Stage,[string]$Build) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Directory]::CreateDirectory($Stage) | Out-Null
    $allowed=@('ZyonRoblox.exe','config/offsets.json','docs/THIRD-PARTY-NOTICES.txt')
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $archive=[IO.Compression.ZipFile]::OpenRead($ZipPath);$total=0L
    try {
        if ($archive.Entries.Count -gt 10) { throw 'Pacote contem arquivos inesperados.' }
        foreach ($entry in $archive.Entries) {
            $name=$entry.FullName.Replace('\','/')
            if ($name -in @('config/','docs/') -and $entry.Length -eq 0) { continue }
            if ($name -cnotin $allowed -or !$seen.Add($name) -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw "Arquivo de pacote nao autorizado: $name" }
            $total+=$entry.Length
            if ($entry.Length -gt 52428800 -or $total -gt 62914560) { throw 'Pacote descompactado grande demais.' }
            $dest=Join-Path $Stage $name;[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest)) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$dest,$false)
        }
    } finally { $archive.Dispose() }
    foreach ($name in $allowed) { if (!$seen.Contains($name)) { throw "Arquivo obrigatorio ausente: $name" } }
    Assert-CloudOffsets (Join-Path $Stage 'config/offsets.json') $Build | Out-Null
    $exe=[IO.File]::ReadAllBytes((Join-Path $Stage 'ZyonRoblox.exe'))
    if ($exe.Length -lt 128 -or $exe[0] -ne 0x4d -or $exe[1] -ne 0x5a) { throw 'Executavel invalido.' }
    $pe=[BitConverter]::ToInt32($exe,60)
    if ($pe -lt 64 -or $pe -gt $exe.Length-6 -or [BitConverter]::ToUInt32($exe,$pe) -ne 0x00004550 -or [BitConverter]::ToUInt16($exe,$pe+4) -ne 0x8664) { throw 'Executavel precisa ser Windows x64.' }
    return $allowed
}
function Install-CloudPackage([string]$Root,[string]$Stage,[string]$Build) {
    $files=@('ZyonRoblox.exe','config/offsets.json','docs/THIRD-PARTY-NOTICES.txt')
    $backup=Join-Path $Root ('backups/cloud-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
    $record=@();$changed=@();$started=$false
    try {
        foreach ($name in $files) {
            $source=Join-Path $Stage $name;$target=Join-Path $Root $name;$saved=Join-Path $backup $name
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($saved)) | Out-Null
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
            if ((Get-Item -LiteralPath ([IO.Path]::GetDirectoryName($target))).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Destino da atualizacao nao pode ser um link de diretorio.' }
            $exists=[IO.File]::Exists($target)
            if ($exists) { [IO.File]::Copy($target,$saved,$false) }
            $oldSha=$null;if ($exists) { $oldSha=Get-CloudFileHash $saved }
            $record+=@{Name=$name;Target=$target;Backup=$saved;Exists=$exists;OldHash=$oldSha;Hash=(Get-CloudFileHash $source)}
        }
        $journalFiles=@($record | ForEach-Object { [ordered]@{name=$_.Name;existed=$_.Exists;oldSha256=$_.OldHash} })
        Write-CloudJson (Join-Path $backup 'transaction.json') ([ordered]@{build=$Build;status='prepared';files=$journalFiles})
        $started=$true
        foreach ($file in $record) {
            $new=$file.Target+'.update-'+[guid]::NewGuid().ToString('N')
            try {
                [IO.File]::Copy((Join-Path $Stage $file.Name),$new,$false)
                if ((Get-CloudFileHash $new) -ne $file.Hash) { throw 'Falha ao verificar arquivo preparado.' }
                if ($file.Exists) { [IO.File]::Replace($new,$file.Target,[NullString]::Value) } else { [IO.File]::Move($new,$file.Target) }
                $changed+=,$file
            } finally { if ([IO.File]::Exists($new)) { [IO.File]::Delete($new) } }
        }
        Assert-CloudOffsets (Join-Path $Root 'config/offsets.json') $Build | Out-Null
        Write-CloudJson (Join-Path $backup 'transaction.json') ([ordered]@{build=$Build;status='installed';files=$journalFiles})
    } catch {
        if ($started) {
            foreach ($file in $changed) {
                if ($file.Exists) { [IO.File]::Copy($file.Backup,$file.Target,$true) } elseif ([IO.File]::Exists($file.Target)) { [IO.File]::Delete($file.Target) }
            }
            Write-CloudJson (Join-Path $backup 'transaction.json') ([ordered]@{build=$Build;status='restored';files=$journalFiles})
        }
        throw
    }
    return $backup
}
function Repair-CloudTransactions([string]$Root) {
    $folder=Join-Path $Root 'backups'
    if (!(Test-Path -LiteralPath $folder)) { return }
    foreach ($dir in @(Get-ChildItem -LiteralPath $folder -Directory -Filter 'cloud-*')) {
        $journal=Join-Path $dir.FullName 'transaction.json'
        if (!(Test-Path -LiteralPath $journal)) { continue }
        if ((Get-Item -LiteralPath $journal).Length -gt 65536) { throw 'Registro de recuperacao invalido.' }
        $value=[IO.File]::ReadAllText($journal) | ConvertFrom-Json
        if ($value.status -ne 'prepared') { continue }
        $allowed=@('ZyonRoblox.exe','config/offsets.json','docs/THIRD-PARTY-NOTICES.txt')
        $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        if (@($value.files).Count -ne 3) { throw 'Registro de recuperacao incompleto.' }
        foreach ($file in $value.files) {
            if ($file.name -cnotin $allowed -or !$seen.Add([string]$file.name)) { throw 'Arquivo nao autorizado no registro de recuperacao.' }
            if ($file.existed -and (!(Test-Path -LiteralPath (Join-Path $dir.FullName $file.name)) -or (Get-CloudFileHash (Join-Path $dir.FullName $file.name)) -ne $file.oldSha256)) { throw 'Backup de recuperacao ausente ou alterado.' }
        }
        foreach ($file in $value.files) {
            $target=Join-Path $Root $file.name
            if ($file.existed) { [IO.File]::Copy((Join-Path $dir.FullName $file.name),$target,$true) } elseif ([IO.File]::Exists($target)) { [IO.File]::Delete($target) }
        }
        $value.status='restored';Write-CloudJson $journal $value
    }
}
