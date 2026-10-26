# Zyon cloud update tooling

Windows PowerShell 5.1 publisher and external launch-time updater. This branch
contains setup tools and synthetic tests, not the application's source, real
offsets, executables, private signing keys or GitHub credentials.

The publisher creates `OWNER/zyon-updates` as a public package repository on the
operator's Windows machine. Authentication uses the official GitHub CLI browser
flow. A local RSA-3072 signing certificate is created in CurrentUser/My; only its
public certificate is distributed. Signatures cover the exact manifest bytes
using RSA PKCS#1 SHA-256. Each downloaded package is checked against its signed
SHA-256, size, exact Roblox build, executable version and fixed file whitelist.

## Install

Run the pinned Bootstrap-Cloud.ps1 provided by the setup operator with the actual
application root, SourceRevision, Owner and Repository. `-Publish` compiles and
publishes the initial beta. The Windows root must already contain the working
application, development tools, embedded icon and validated configuration.

The installer creates shortcuts **Zyon - iniciar** and **Zyon - verificar
atualizacoes**. Start through the former to check for updates before opening the
application. Opening the application EXE directly continues to work and skips
this external check. No service, driver, scheduled task or administrator account
is installed.

## Publish subsequent updates

Close the application, validate its configuration and run on the publisher PC:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "ROOT\tools\cloud\Publish-Cloud.ps1" -Root "ROOT" -Version 1.0.2 -Channel beta
```

Publish stable only after testing. To configure the local launch shortcut to use
stable, re-run the installer with `-Channel stable` and the same publisher key.
Never replace the signing key during routine updates. The public certificate is
pinned in each installed launcher. Publisher state and the signing certificate
must be backed up; Export-SigningKey.ps1 makes a password-protected PFX plus a
publisher settings backup outside the application folder.

The channel manifests are fixed GitHub release assets:

```
https://github.com/OWNER/REPO/releases/download/channel-beta/beta.json
https://github.com/OWNER/REPO/releases/download/channel-beta/beta.json.sig
https://github.com/OWNER/REPO/releases/download/channel-stable/stable.json
https://github.com/OWNER/REPO/releases/download/channel-stable/stable.json.sig
```

Every application package has its own immutable version/release-sequence tag.
Existing entries for other Roblox builds are retained only after checking the
previous manifest's signature. Release numbers are monotonic. A retired release
is replaced by a new signed publication, never by reducing the sequence.

## Customer installation

Build-ClientBundle.ps1 generates a first-install ZIP with the working app and
public verifier. It excludes signing certificates/private keys, publisher
configuration, source, compilers, user preferences and backups. Customers extract
it, run tools/Instalar-Atalhos.cmd, then use the launch shortcut. Subsequent update
ZIPs only replace ZyonRoblox.exe, config/offsets.json and third-party notices.
config/ui.json and development tools are preserved.

## Failure handling

A running application is never killed. Updates require it closed. Offline or
invalid updates preserve installed files and are recorded in logs/updates.log;
the launch shortcut can still start the existing app. Backup journals restore
partially installed releases after a write failure or an interrupted transaction.
An unknown Roblox build does not receive another build's configuration. The
application already checks exact build compatibility when connecting.

The launcher checks at most every 30 minutes for the same build. A changed build
or the manual check bypasses this cache. The first beta must be published before
its channel URL exists. Download metadata alone does not discover or validate
new offsets; publishing requires developer validation.

## Tests

Common.Tests.ps1 tests crypto rejection, package restrictions, settings
preservation and rollback on PowerShell 7. Windows.Tests.ps1 runs in native
Windows PowerShell 5.1, creates a disposable CNG certificate and x64 executable,
and verifies full update installation with a local simulated transport. The
workflow tests Windows and Ubuntu; test keys and binaries are temporary.
