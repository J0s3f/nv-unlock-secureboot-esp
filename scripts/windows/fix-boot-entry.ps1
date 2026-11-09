#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
Removes the Windows-specific OptionalData from the "NV Unlock" UEFI boot entry.

Why: `bcdedit /copy {bootmgr}` makes the firmware entry carry a ~136-byte blob that
starts with "WINDOWS". shim passes it on as load options; it then fails with
"Failed to open ... Invalid Parameter / start_image() returned Invalid Parameter,
falling back to default loader" before the unlocker even starts (it still works
through shim's fallback, but the message is noise and the path is fragile).

What it does (and nothing else):
  1. -Inspect: read-only report of the entry.
  2. Default: back up Boot#### (JSON, SHA256), suspend BitLocker for one boot,
     rewrite ONLY that variable without the bytes after the device path
     (name, device path, attributes unchanged), read it back, verify BootOrder
     and the Windows Boot Manager entries are unchanged. No reboot.
  3. BCD cleanup: Windows then imports the cleaned entry as a NEW firmware-application
     object and re-creates the old BCD copy (with OptionalData) as a second entry.
     This script waits for that, deletes the old copy and records the new id in
     entry-id.txt. Skip with -SkipBcdCleanup and do it by hand (see README).
  -RestoreBackup <json>: put a backed-up entry back (only if the entry is still the
     cleaned one).

Verified by hand on a Lenovo Legion 5 Pro 16ACH6H (the same steps, executed one by one).
The automatic BCD cleanup part has NOT been exercised end to end as a script.
#>
[CmdletBinding(DefaultParameterSetName='Repair')]
param(
    [Parameter(ParameterSetName='Inspect')][switch]$Inspect,
    [Parameter(Mandatory=$true,ParameterSetName='Restore')][string]$RestoreBackup,
    [Parameter(ParameterSetName='Repair')][switch]$SkipBcdCleanup,
    [string]$BackupRoot = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')
if ([string]::IsNullOrWhiteSpace($BackupRoot)) { $BackupRoot = Join-Path $StateDir 'boot-entry-backups' }
if (-not ('NvUnlockBootRepair.Firmware' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'BootEntryTools.cs') }
[NvUnlockBootRepair.Firmware]::EnablePrivilege()

function Hash-Bytes([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','') } finally { $sha.Dispose() }
}
function Equal-Variable($A,$B) { ($A.Attributes -eq $B.Attributes -and [NvUnlockBootRepair.Codec]::Equal($A.Data,$B.Data)) }
function Suspend-ForChange {
    $v = Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter ("DriveLetter='{0}'" -f $env:SystemDrive)
    if (-not $v) { throw 'Cannot determine OS BitLocker status. Nothing written to firmware.' }
    $state = Invoke-CimMethod -InputObject $v -MethodName GetProtectionStatus
    if ($state.ReturnValue -ne 0 -or $state.ProtectionStatus -notin @(0,1)) { throw 'Unknown BitLocker protection state. Nothing written to firmware.' }
    if ($state.ProtectionStatus -eq 1) {
        & manage-bde.exe -protectors -disable $env:SystemDrive -RebootCount 1
        if ($LASTEXITCODE -ne 0) { throw 'BitLocker suspension failed. Nothing written to firmware.' }
        Write-Host 'BitLocker protection suspended for one boot; data remains encrypted.'
    } else { Write-Warning 'BitLocker protection is already off/suspended; left unchanged.' }
}
function Get-NvUnlockBcdIds {
    # BCD objects whose path is the shim; bcdedit labels are localized, so match on content only.
    $text = (bcdedit /enum all 2>&1) -join "`n"
    $ids = @()
    $parts = [regex]::Split($text, '(?m)^-{5,}\s*$')
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($parts[$i] -match '(?i)\\EFI\\nvunlock\\shimx64\.efi') {
            $m = [regex]::Match($parts[$i], '\{[0-9a-fA-F-]{36}\}')
            if ($m.Success) { $ids += $m.Value }
        }
    }
    return @($ids | Select-Object -Unique)
}

$order = [NvUnlockBootRepair.Firmware]::Read('BootOrder')
if ($order.Data.Length % 2 -ne 0) { throw 'Invalid BootOrder length.' }
$entries = @()
for ($i=0; $i -lt $order.Data.Length; $i+=2) {
    $name = 'Boot{0:X4}' -f [BitConverter]::ToUInt16($order.Data,$i)
    $raw = [NvUnlockBootRepair.Firmware]::Read($name)
    $entries += [pscustomobject]@{Name=$name; Raw=$raw; Parsed=[NvUnlockBootRepair.Codec]::Parse($raw.Data)}
}
$targets = @($entries | Where-Object { $_.Parsed.FilePath -ieq '\EFI\nvunlock\shimx64.efi' })
if ($targets.Count -eq 0) { throw 'No NV Unlock entry in BootOrder. Run install-esp.ps1 first. No change made.' }
foreach ($t in $targets) {
    Write-Host "Entry $($t.Name): $($t.Parsed.Description), OptionalData $($t.Parsed.OptionalLength) bytes, SHA256 $(Hash-Bytes $t.Raw.Data)"
}
if ($Inspect) { Write-Host 'Inspection only. Nothing changed.'; return }

$dirty = @($targets | Where-Object { $_.Parsed.OptionalLength -gt 0 })
$clean = @($targets | Where-Object { $_.Parsed.OptionalLength -eq 0 })

if ($PSCmdlet.ParameterSetName -eq 'Restore') {
    if ($targets.Count -ne 1) { throw 'Restore needs exactly one NV Unlock entry in BootOrder.' }
    $target = $targets[0]
    $backup = Get-Content -LiteralPath $RestoreBackup -Raw | ConvertFrom-Json
    if ($backup.Schema -ne 1 -or $backup.Variable -cne $target.Name -or $backup.Attributes -ne $target.Raw.Attributes) { throw 'Backup does not match this boot entry.' }
    $original = [Convert]::FromBase64String($backup.OriginalBase64)
    $cleaned  = [Convert]::FromBase64String($backup.CleanedBase64)
    if ((Hash-Bytes $original) -cne $backup.OriginalSHA256 -or (Hash-Bytes $cleaned) -cne $backup.CleanedSHA256) { throw 'Backup hash mismatch.' }
    $o = [NvUnlockBootRepair.Codec]::Parse($original); [NvUnlockBootRepair.Codec]::RequireNvUnlock($o)
    if (-not [NvUnlockBootRepair.Codec]::Equal($o.Prefix,$cleaned)) { throw 'Invalid backup.' }
    if ([NvUnlockBootRepair.Codec]::Equal($target.Raw.Data,$original)) { Write-Host 'Already restored.'; return }
    if (-not [NvUnlockBootRepair.Codec]::Equal($target.Raw.Data,$cleaned)) { throw 'Entry changed since repair. Refusing to overwrite it.' }
    $replacement = $original
    $writeTarget = $target
} elseif ($dirty.Count -eq 0) {
    Write-Host 'No OptionalData on any NV Unlock entry. Nothing to repair.'
    $writeTarget = $null
} elseif ($dirty.Count -eq 1 -and $clean.Count -eq 0) {
    $writeTarget = $dirty[0]
    [NvUnlockBootRepair.Codec]::RequireNvUnlock($writeTarget.Parsed)
    if ($writeTarget.Raw.Attributes -ne 7) { throw 'Unexpected firmware variable attributes. No change made.' }
    $replacement = [byte[]]$writeTarget.Parsed.Prefix
} else {
    # A cleaned entry already exists next to a stale Windows-managed copy: only the BCD copy is left to remove.
    $writeTarget = $null
    Write-Host 'A cleaned entry and a Windows-managed copy are both present; going straight to the BCD cleanup.'
}
$windows = @($entries | Where-Object { $_.Parsed.FilePath -ieq '\EFI\Microsoft\Boot\bootmgfw.efi' })
if ($writeTarget -and $PSCmdlet.ParameterSetName -ne 'Restore' -and $windows.Count -lt 1) { throw 'No separate Windows Boot Manager entry in BootOrder. No change made.' }

if ($writeTarget) {
    $null = New-Item -ItemType Directory -Path $BackupRoot -Force
    $backupPath = Join-Path $BackupRoot ('{0}-{1}-{2}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'),$writeTarget.Name,[guid]::NewGuid().ToString('N').Substring(0,8))
    [ordered]@{
        Schema=1; Created=(Get-Date).ToString('o'); Variable=$writeTarget.Name; Attributes=$writeTarget.Raw.Attributes
        Description=$writeTarget.Parsed.Description; FilePath=$writeTarget.Parsed.FilePath
        OriginalBase64=[Convert]::ToBase64String($writeTarget.Raw.Data); OriginalSHA256=(Hash-Bytes $writeTarget.Raw.Data)
        CleanedBase64=[Convert]::ToBase64String($writeTarget.Parsed.Prefix); CleanedSHA256=(Hash-Bytes $writeTarget.Parsed.Prefix)
        BootOrderBase64=[Convert]::ToBase64String($order.Data); Operation=$PSCmdlet.ParameterSetName
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $backupPath -Encoding UTF8
    $saved = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
    if (-not [NvUnlockBootRepair.Codec]::Equal([Convert]::FromBase64String($saved.OriginalBase64),$writeTarget.Raw.Data)) { throw 'Backup verification failed.' }
    Write-Host "Backup saved: $backupPath"
    Suspend-ForChange
    if (-not (Equal-Variable ([NvUnlockBootRepair.Firmware]::Read($writeTarget.Name)) $writeTarget.Raw) -or
        -not (Equal-Variable ([NvUnlockBootRepair.Firmware]::Read('BootOrder')) $order)) {
        throw 'Boot configuration changed during collection. Nothing written.'
    }
    try {
        [NvUnlockBootRepair.Firmware]::WriteNvUnlock($writeTarget.Name,$replacement,$writeTarget.Raw.Attributes)
        $after = [NvUnlockBootRepair.Firmware]::Read($writeTarget.Name)
        if ($after.Attributes -ne $writeTarget.Raw.Attributes -or -not [NvUnlockBootRepair.Codec]::Equal($after.Data,$replacement)) { throw 'Firmware read-back mismatch.' }
    } catch {
        $why = $_.Exception.Message
        try {
            [NvUnlockBootRepair.Firmware]::WriteNvUnlock($writeTarget.Name,$writeTarget.Raw.Data,$writeTarget.Raw.Attributes)
            if (-not (Equal-Variable ([NvUnlockBootRepair.Firmware]::Read($writeTarget.Name)) $writeTarget.Raw)) { throw 'Rollback verification failed.' }
            Write-Warning 'Original entry restored and verified.'
        } catch { throw "REPAIR AND ROLLBACK FAILED. Backup: $backupPath. The Windows Boot Manager entry still boots. Details: $($_.Exception.Message)" }
        throw "Repair failed: $why"
    }
    if (-not (Equal-Variable ([NvUnlockBootRepair.Firmware]::Read('BootOrder')) $order)) { throw 'Entry written, but BootOrder changed externally. Check firmware settings before rebooting.' }
    foreach ($w in $windows) {
        if (-not (Equal-Variable ([NvUnlockBootRepair.Firmware]::Read($w.Name)) $w.Raw)) { throw 'Entry written, but the Windows Boot Manager entry changed externally.' }
    }
    Write-Host "SUCCESS: $($writeTarget.Name) written and verified. BootOrder and Windows Boot Manager unchanged." -ForegroundColor Green
    if ($PSCmdlet.ParameterSetName -eq 'Restore') { Write-Host 'Restore done. No BCD cleanup is attempted after a restore.'; return }
}

if ($SkipBcdCleanup) { Write-Host 'Skipping BCD cleanup (see README, "Duplicate entry").'; return }

# --- BCD cleanup ---------------------------------------------------------------------
$oldId = if (Test-Path $IdFile) { (Get-Content $IdFile).Trim() } else { $null }
if (-not $oldId) { Write-Warning "No $IdFile - cannot tell which BCD object is the old copy. Do the cleanup by hand (README)."; return }
Write-Host 'Waiting up to 5 min for Windows to import the cleaned entry as its own BCD object ...'
$deadline = (Get-Date).AddMinutes(5)
$ids = @()
do {
    $ids = @(Get-NvUnlockBcdIds)
    if ($ids.Count -ge 2) { break }
    Start-Sleep -Seconds 5
} while ((Get-Date) -lt $deadline)
if ($ids.Count -lt 2) {
    Write-Warning "Only $($ids.Count) BCD object(s) point at the shim. If a second one appears later, delete the OLD one ($oldId) with: bcdedit /delete $oldId  and put the new id into $IdFile."
    return
}
if ($ids -notcontains $oldId) { Write-Warning "Old id $oldId not among $($ids -join ', '); not deleting anything."; return }
$newId = @($ids | Where-Object { $_ -ne $oldId })
if ($newId.Count -ne 1) { Write-Warning "Expected exactly one new object, found $($newId.Count): $($newId -join ', '). Not deleting anything."; return }
bcdedit /delete $oldId | Out-Host
Set-Content -Path $IdFile -Value $newId[0]
Write-Host "Done: old BCD copy $oldId deleted; entry id is now $($newId[0])." -ForegroundColor Green
Write-Host 'Check with: bcdedit /enum firmware   (one NV Unlock entry, no WINDOWS blob)'
