#Requires -RunAsAdministrator
# Removes the "NV Unlock" boot entry and every file install-esp.ps1 put on the ESP.
# Your MOK stays enrolled (see README: "Removing the MOK").
param([string]$Letter = "S:")
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "common.ps1")

if (Test-Path $IdFile) {
    $id = (Get-Content $IdFile).Trim()
    bcdedit /delete $id 2>&1 | Out-Host
}
Suspend-BitLockerOnce   # boot path changes back -> reseal instead of a recovery-key prompt

$mounted = Mount-Esp $Letter
try {
    Remove-Item "$Letter\EFI\nvunlock" -Recurse -Force -ErrorAction SilentlyContinue
    $files = if (Test-Path $FilesList) { Get-Content $FilesList } else { @() }
    foreach ($f in @($files) + "loader.log") {
        if ($f -and (Test-Path "$Letter\$f")) { Remove-Item "$Letter\$f" -Force; "removed $f" }
    }
} finally {
    if ($mounted) { mountvol $Letter /D }
}
Remove-Item $StateDir -Recurse -Force -ErrorAction SilentlyContinue
"uninstalled"
