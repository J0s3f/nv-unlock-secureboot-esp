#Requires -RunAsAdministrator
<#
Installs the signed nv-uefi-unlocker (shim + MOK-signed loader) on the internal EFI
system partition (ESP) and adds a NON-default firmware boot entry "NV Unlock".
Normal boots are unchanged until you run set-default.ps1 (or use reboot-unlock.ps1).

  ESP:\EFI\nvunlock\shimx64.efi   Ubuntu shim (Microsoft UEFI CA 2011 signed)
  ESP:\EFI\nvunlock\grubx64.efi   unlocker, signed with your MOK
  ESP:\EFI\nvunlock\mmx64.efi     MokManager
  ESP:\EFI\nvunlock\MOK.cer       your certificate (for enrolling from the ESP)
  ESP:\<family assets>            the loader reads its assets from the volume root
  ESP:\i_know_what_i_am_doing.txt upstream marker: 5 s auto-run, any key aborts

Usage:
  .\install-esp.ps1 -Src C:\path\to\usbroot-sb [-Letter S:] [-NoAutoRun]
#>
param(
    [Parameter(Mandatory)][string]$Src,
    [string]$Letter = "S:",
    [switch]$NoAutoRun     # keep upstream "Space/Enter within 30 s" confirmation instead
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "common.ps1")
$Src = (Resolve-Path $Src).Path

# signed EFI files produced by sign-usbroot.sh
$efis = [ordered]@{
    "shimx64.efi" = "EFI\BOOT\BOOTX64.EFI"
    "grubx64.efi" = "EFI\BOOT\grubx64.efi"
    "mmx64.efi"   = "EFI\BOOT\mmx64.efi"
    "MOK.cer"     = "MOK.cer"
}
foreach ($v in $efis.Values) { if (-not (Test-Path "$Src\$v")) { throw "missing $Src\$v - did you run sign-usbroot.sh?" } }

# families present in the usbroot (one v67 payload per family)
$families = @(Get-ChildItem "$Src\v67-*-four-plm.bin" | ForEach-Object { ($_.Name -split '-')[1] })
if (-not $families) { throw "no v67-*-four-plm.bin in $Src" }
$assets = @($families | ForEach-Object { $FamilyAssets[$_] } | Select-Object -Unique)
foreach ($f in $assets) { if (-not (Test-Path "$Src\$f")) { throw "missing $Src\$f" } }
"families: $($families -join ', ')"

$mounted = Mount-Esp $Letter
try {
    $need = (($assets | ForEach-Object { "$Src\$_" }) + ($efis.Values | ForEach-Object { "$Src\$_" }) |
             Get-Item | Measure-Object Length -Sum).Sum
    $free = [System.IO.DriveInfo]::new($Letter.TrimEnd(':')).AvailableFreeSpace
    "ESP free: {0:N0} MB, need: {1:N0} MB (+10 MB headroom)" -f ($free / 1MB), ($need / 1MB)
    if ($free -lt $need + 10MB) { throw "not enough free space on the ESP" }

    # never overwrite foreign files at the ESP root
    foreach ($f in $assets) {
        $t = "$Letter\$f"
        if ((Test-Path $t) -and ((Get-FileHash $t).Hash -ne (Get-FileHash "$Src\$f").Hash)) {
            throw "$t already exists with different content - refusing"
        }
    }
    New-Item -ItemType Directory -Force "$Letter\EFI\nvunlock" | Out-Null
    foreach ($k in $efis.Keys) { Copy-Item "$Src\$($efis[$k])" "$Letter\EFI\nvunlock\$k" -Force }
    foreach ($f in $assets) { Copy-Item "$Src\$f" "$Letter\$f" -Force }
    $installed = @($assets)
    if (-not $NoAutoRun) {
        New-Item -ItemType File -Force "$Letter\i_know_what_i_am_doing.txt" | Out-Null
        $installed += "i_know_what_i_am_doing.txt"
    }
    New-Item -ItemType Directory -Force $StateDir | Out-Null
    Set-Content -Path $FilesList -Value $installed

    $listed = @("$Letter\EFI\nvunlock\*") + @($installed | ForEach-Object { "$Letter\$_" })
    "files installed:"; Get-Item -Path $listed | Select-Object FullName, Length | Format-Table -AutoSize | Out-String
} finally {
    if ($mounted) { mountvol $Letter /D }
}

# Firmware boot entry: a copy of {bootmgr} is a firmware application on the ESP; bcdedit
# syncs it to a UEFI Boot#### variable. Appended LAST, so nothing changes yet.
$id = $null
if (Test-Path $IdFile) { try { $id = Get-EntryId } catch { $id = $null } }
if ($id) {
    "boot entry exists: $id"
} else {
    $out = bcdedit /copy '{bootmgr}' /d "NV Unlock"
    if (($out -join ' ') -notmatch '\{[0-9a-fA-F-]{36}\}') { throw "bcdedit /copy failed: $out" }
    $id = $Matches[0]
    bcdedit /set $id path \EFI\nvunlock\shimx64.efi | Out-Null
    bcdedit /set '{fwbootmgr}' displayorder $id /addlast | Out-Null
    Set-Content -Path $IdFile -Value $id
    "boot entry created: $id"
}
bcdedit /enum $id
""
"Done. The normal boot order is unchanged."
"Next: .\reboot-unlock.ps1 (one unlocked boot)  or  .\set-default.ps1 (every boot)."
