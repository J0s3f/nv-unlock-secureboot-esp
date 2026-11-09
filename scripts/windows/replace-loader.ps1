#Requires -RunAsAdministrator
<#
Replaces ONLY ESP:\EFI\nvunlock\grubx64.efi (the signed unlocker) with a new signed build.
Backs up the current file first (name contains its SHA256 prefix); -Rollback restores the newest backup.
Suspends BitLocker for one boot (the measured boot path changes). Never reboots.

  .\replace-loader.ps1 -New C:\path\grubx64.signed.efi [-ExpectedSha256 <hex>]
  .\replace-loader.ps1 -Rollback
#>
param(
    [string]$New,
    [string]$ExpectedSha256 = '',
    [switch]$Rollback,
    [string]$Letter = 'S:'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
if (-not $Rollback -and -not $New) { throw 'pass -New <signed grubx64.efi> or -Rollback' }
$BackupDir = Join-Path $StateDir 'loader-backups'
New-Item -ItemType Directory -Force $BackupDir | Out-Null
$mounted = Mount-Esp $Letter
try {
    $target = "$Letter\EFI\nvunlock\grubx64.efi"
    if (-not (Test-Path $target)) { throw "missing $target - run install-esp.ps1 first" }
    $cur = (Get-FileHash $target -Algorithm SHA256).Hash.ToLower()
    if ($Rollback) {
        $b = Get-ChildItem $BackupDir -Filter 'grubx64.*.efi' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $b) { throw "no backup in $BackupDir" }
        $src = $b.FullName
    } else {
        $src = (Resolve-Path $New).Path
        $h = (Get-FileHash $src -Algorithm SHA256).Hash.ToLower()
        if ($ExpectedSha256 -and $h -ne $ExpectedSha256.ToLower()) { throw "hash mismatch: $h" }
        $bk = Join-Path $BackupDir ('grubx64.{0}.{1}.efi' -f (Get-Date -Format yyyyMMdd-HHmmss), $cur.Substring(0,12))
        Copy-Item $target $bk
        if ((Get-FileHash $bk -Algorithm SHA256).Hash.ToLower() -ne $cur) { throw 'backup verify failed' }
        "backup: $bk"
    }
    Suspend-BitLockerOnce
    Copy-Item $src $target -Force
    $want = (Get-FileHash $src -Algorithm SHA256).Hash
    if ((Get-FileHash $target -Algorithm SHA256).Hash -ne $want) { throw 'copy verify failed - run -Rollback' }
    "installed $want -> $target"
    "No reboot triggered."
} finally {
    if ($mounted) { mountvol $Letter /D }
}
