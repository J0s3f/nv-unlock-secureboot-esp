#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
Read-only boot diagnostics. Writes only the report directory.
-IncludeEsp temporarily mounts the system ESP on a free letter and removes that mount.
Never suspends BitLocker, changes BCD/firmware, clears TPM, or reboots.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('warm','cold-recovery','after-ctrlaltdel','baseline')]
    [string]$Label,
    [string]$Note = '',
    [ValidateRange(1,30)][int]$Days = 7,
    [switch]$IncludeEsp,
    [string]$OutputRoot = ''
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $scriptDirectory = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptDirectory)) {
        $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    $OutputRoot = Join-Path $scriptDirectory 'reports'
}
$report = Join-Path $OutputRoot ('{0}-{1}-{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Label, ([guid]::NewGuid().ToString('N').Substring(0,6)))
$null = New-Item -ItemType Directory -Path $report -Force
$report = (Resolve-Path -LiteralPath $report).Path
$script:issues = New-Object 'System.Collections.Generic.List[string]'
$script:summary = [ordered]@{
    Label = $Label; Note = $Note; CollectedAt = (Get-Date).ToString('o')
    LastBootUpTime = $null; Manufacturer = $null; Model = $null; BIOSVersion = $null
    WindowsBuild = $null; SecureBoot = $null; HiberbootEnabled = $null
    ProtectionStatus = $null; VolumeStatus = $null; Protectors = @(); PcrProfiles = @()
    TpmPresent = $null; TpmReady = $null; EspCollected = $false
}
function Protect-Text([string]$Text) {
    # Defense in depth for unexpected recovery passwords in event messages or user notes.
    [regex]::Replace($Text, '(?<!\d)(?:\d{6}[-\s]){7}\d{6}(?!\d)', '[REDACTED-BITLOCKER-RECOVERY-PASSWORD]')
}
function Save-Text([string]$Name, $Value) {
    $s = $Value | Out-String -Width 300
    Protect-Text $s | Set-Content -LiteralPath (Join-Path $report $Name) -Encoding UTF8
}
function Section([string]$Name, [scriptblock]$Action) {
    Write-Host "Collecting $Name ..."
    try { & $Action } catch {
        $script:issues.Add((Protect-Text ("{0}: {1}" -f $Name, $_.Exception.Message)))
        Write-Warning "$Name unavailable; continuing."
    }
}
function Native-Text([string]$Exe, [string[]]$Arguments) {
    $result = & $Exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "$Exe exited $LASTEXITCODE : $($result -join ' ')" }
    $result
}
Section 'system' {
    $os = Get-CimInstance Win32_OperatingSystem
    $bios = Get-CimInstance Win32_BIOS
    $pc = Get-CimInstance Win32_ComputerSystem
    $script:summary.LastBootUpTime = $os.LastBootUpTime.ToString('o')
    $script:summary.Manufacturer = $pc.Manufacturer
    $script:summary.Model = $pc.Model
    $script:summary.BIOSVersion = $bios.SMBIOSBIOSVersion
    $script:summary.WindowsBuild = $os.BuildNumber
    Save-Text 'system.txt' @(
        ($os | Select-Object Caption,Version,BuildNumber,LastBootUpTime | Format-List | Out-String)
        ($bios | Select-Object Manufacturer,SMBIOSBIOSVersion,ReleaseDate | Format-List | Out-String)
        ($pc | Select-Object Manufacturer,Model,SystemType | Format-List | Out-String)
        (Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion,PNPDeviceID | Format-List | Out-String)
    )
}
Section 'BitLocker status (no recovery secrets)' {
    Save-Text 'bitlocker-status.txt' (Native-Text 'manage-bde.exe' @('-status', $env:SystemDrive))
    $v = Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter ("DriveLetter='{0}'" -f $env:SystemDrive)
    if (-not $v) { throw 'No OS encryption volume found.' }
    $protection = Invoke-CimMethod -InputObject $v -MethodName GetProtectionStatus
    $conversion = Invoke-CimMethod -InputObject $v -MethodName GetConversionStatus
    if ($protection.ReturnValue -ne 0 -or $conversion.ReturnValue -ne 0) { throw 'Cannot query encryption/protection state.' }
    $script:summary.ProtectionStatus = switch ($protection.ProtectionStatus) { 0 {'Off'} 1 {'On'} default {'Unknown'} }
    $script:summary.VolumeStatus = [int]$conversion.ConversionStatus
    # Query IDs/types only. Never call the methods returning recovery passwords/keys.
    $ids = Invoke-CimMethod -InputObject $v -MethodName GetKeyProtectors -Arguments @{KeyProtectorType=[uint32]0}
    if ($ids.ReturnValue -ne 0) { throw "GetKeyProtectors returned $($ids.ReturnValue)" }
    $script:summary.Protectors = @(foreach ($id in $ids.VolumeKeyProtectorID) {
        if (-not $id) { continue }
        $kind = Invoke-CimMethod -InputObject $v -MethodName GetKeyProtectorType -Arguments @{VolumeKeyProtectorID=[string]$id}
        [pscustomobject]@{Type=$kind.KeyProtectorType; Id=$id; ReturnValue=$kind.ReturnValue}
    })
    Save-Text 'bitlocker-protector-types.txt' ($script:summary.Protectors | Format-Table -AutoSize)
}
Section 'TPM protector PCR validation profiles' {
    $vol = Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter ("DriveLetter='{0}'" -f $env:SystemDrive)
    if (-not $vol) { throw 'No OS encryption volume found.' }
    $profiles = @()
    # 1=TPM, 4=TPM+PIN, 5=TPM+startup key, 6=TPM+PIN+startup key.
    foreach ($kind in @(1,4,5,6)) {
        $ids = Invoke-CimMethod -InputObject $vol -MethodName GetKeyProtectors -Arguments @{KeyProtectorType=[uint32]$kind}
        if ($ids.ReturnValue -ne 0) { throw "GetKeyProtectors returned $($ids.ReturnValue)" }
        foreach ($id in $ids.VolumeKeyProtectorID) {
            if (-not $id) { continue }
            $pcr = Invoke-CimMethod -InputObject $vol -MethodName GetKeyProtectorPlatformValidationProfile -Arguments @{VolumeKeyProtectorID=[string]$id}
            $profiles += [pscustomobject]@{Type=$kind; Id=$id; ReturnValue=$pcr.ReturnValue; PCRs=@($pcr.PlatformValidationProfile)}
        }
    }
    $script:summary.PcrProfiles = @($profiles)
    Save-Text 'pcr-validation-profiles.txt' ($profiles | Format-List)
}
Section 'TPM status' {
    $tpm = Get-Tpm
    $script:summary.TpmPresent = $tpm.TpmPresent
    $script:summary.TpmReady = $tpm.TpmReady
    Save-Text 'tpm.txt' ($tpm | Select-Object TpmPresent,TpmReady,TpmEnabled,TpmActivated,TpmOwned,RestartPending,ManufacturerIdTxt,ManufacturerVersion,AutoProvisioning,LockedOut,LockoutCount,LockoutMax | Format-List)
}
Section 'Secure Boot' { $script:summary.SecureBoot = Confirm-SecureBootUEFI }
Section 'firmware boot entries' { Save-Text 'bcd-firmware.txt' (Native-Text 'bcdedit.exe' @('/enum','firmware','/v')) }
Section 'Windows BCD' { Save-Text 'bcd-all.txt' (Native-Text 'bcdedit.exe' @('/enum','all','/v')) }
Section 'power' {
    $script:summary.HiberbootEnabled = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled).HiberbootEnabled
    Save-Text 'power.txt' (Native-Text 'powercfg.exe' @('/a'))
}
Section 'BitLocker policies' {
    if (Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\FVE') {
        Save-Text 'bitlocker-policy.txt' (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\FVE' | Format-List)
    } else { Save-Text 'bitlocker-policy.txt' 'No HKLM policy key present.' }
}
Section 'disk layout' {
    Save-Text 'partitions.txt' (Get-Partition | Select-Object DiskNumber,PartitionNumber,DriveLetter,Type,GptType,Size,IsBoot,IsSystem | Format-Table -AutoSize)
}
$since = (Get-Date).AddDays(-$Days)
$script:eventLogs = @('Microsoft-Windows-Kernel-Boot/Operational','System')
Section 'discover BitLocker and TPM event channels' {
    # Provider/display names differ from actual channel names, e.g.
    # Microsoft-Windows-BitLocker/BitLocker Management (provider: BitLocker-API).
    $discoveryErrors = @()
    $channels = @(Get-WinEvent -ListLog '*BitLocker*','*TPM*' -ErrorAction SilentlyContinue -ErrorVariable discoveryErrors)
    Save-Text 'event-channel-inventory.txt' ($channels | Select-Object LogName,IsEnabled,RecordCount,LogType | Format-Table -AutoSize)
    foreach ($err in $discoveryErrors) { $script:issues.Add("Event channel discovery: $($err.Exception.Message)") }
    $enabled = @($channels | Where-Object { $_.IsEnabled -and [string]$_.LogType -notin @('Analytical','Debug') })
    $script:eventLogs = @($script:eventLogs + @($enabled | ForEach-Object { $_.LogName }) | Sort-Object -Unique)
}
foreach ($log in $script:eventLogs) {
    Section "events: $log" {
        $info = Get-WinEvent -ListLog $log
        if (-not $info.IsEnabled) { throw 'Log is disabled (left unchanged).' }
        $filter = @{LogName=$log; StartTime=$since}
        if ($log -eq 'System') {
            $filter.ProviderName = @('Microsoft-Windows-BitLocker-Driver','Microsoft-Windows-TPM-WMI','Microsoft-Windows-Kernel-Boot','Microsoft-Windows-Kernel-Power','Microsoft-Windows-Kernel-General','Microsoft-Windows-WER-SystemErrorReporting','EventLog')
        }
        $name = $log -replace '[/\\]', '_'
        try { $events = @(Get-WinEvent -FilterHashtable $filter -MaxEvents 1000 -ErrorAction Stop) }
        catch {
            if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
                Save-Text ("events-$name.txt") "No matching events since $($since.ToString('o'))."
                Save-Text ("events-$name.xml") '<Events />'
                return
            }
            throw
        }
        Save-Text ("events-$name.txt") ($events | Select-Object TimeCreated,Id,ProviderName,LevelDisplayName,Message | Format-List)
        # XML preserves event data even if a localized message cannot be rendered.
        Save-Text ("events-$name.xml") ("<Events>`r`n" + (($events | ForEach-Object { $_.ToXml() }) -join "`r`n") + "`r`n</Events>")
    }
}
Section 'Measured Boot logs' {
    $source = Join-Path $env:SystemRoot 'Logs\MeasuredBoot'
    $files = @(Get-ChildItem -LiteralPath $source -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 30)
    if ($files.Count -eq 0) { throw 'No Measured Boot files found.' }
    $dest = Join-Path $report 'MeasuredBoot'
    $null = New-Item -ItemType Directory -Path $dest
    Save-Text 'measured-boot-index.txt' ($files | Select-Object Name,Length,CreationTimeUtc,LastWriteTimeUtc | Format-Table -AutoSize)
    foreach ($file in $files) {
        try { Copy-Item -LiteralPath $file.FullName -Destination $dest -ErrorAction Stop }
        catch { $script:issues.Add("MeasuredBoot/$($file.Name): $($_.Exception.Message)") }
    }
}
if ($IncludeEsp) {
    Section 'ESP loader log and EFI hashes' {
        $mount = $null
        try {
            # Avoid existing DOS drives, including mappings not visible to Get-Volume.
            $used = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0,1) })
            $used += @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name })
            $letter = @('Z','Y','X','W','V','U','T','S','R') | Where-Object { $_ -notin $used } | Select-Object -First 1
            if (-not $letter) { throw 'No free drive letter for temporary ESP mount.' }
            $drive = "${letter}:"
            $null = Native-Text 'mountvol.exe' @($drive,'/S')
            $mount = $drive
            $root = "$drive\"
            if (-not (Test-Path -LiteralPath (Join-Path $root 'EFI\Microsoft\Boot\bootmgfw.efi'))) { throw 'Mounted ESP has no Windows boot manager.' }
            $logPath = Join-Path $root 'loader.log'
            if (Test-Path -LiteralPath $logPath) {
                Save-Text 'loader.log' (Get-Content -LiteralPath $logPath -Raw)
                Save-Text 'loader-file-info.txt' (Get-Item -LiteralPath $logPath | Select-Object Length,CreationTimeUtc,LastWriteTimeUtc | Format-List)
            } else { $script:issues.Add('ESP: loader.log not found.') }
            $efiFiles = @('EFI\nvunlock\shimx64.efi','EFI\nvunlock\grubx64.efi','EFI\Microsoft\Boot\bootmgfw.efi')
            $hashes = foreach ($relative in $efiFiles) {
                $path = Join-Path $root $relative
                if (Test-Path -LiteralPath $path) {
                    $f = Get-Item -LiteralPath $path
                    [pscustomobject]@{Path=$relative; Length=$f.Length; LastWriteTimeUtc=$f.LastWriteTimeUtc; SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
                }
            }
            Save-Text 'efi-hashes.txt' ($hashes | Format-List)
            Save-Text 'esp-root-file-names.txt' (Get-ChildItem -LiteralPath $root -File | Select-Object Name,Length,LastWriteTimeUtc | Format-Table -AutoSize)
            $script:summary.EspCollected = $true
        } finally {
            if ($mount) {
                try { $null = Native-Text 'mountvol.exe' @($mount,'/D') }
                catch { $script:issues.Add("ESP UNMOUNT FAILED: $mount : $($_.Exception.Message)"); Write-Warning "Remove temporary mount manually: mountvol $mount /D" }
            }
        }
    }
}
Save-Text 'summary.json' ($script:summary | ConvertTo-Json -Depth 8)
Save-Text 'collection-issues.txt' $script:issues
Save-Text 'README.txt' @'
Read-only boot diagnostics. No recovery password, TPM owner authorization, or private signing key was requested.
Files can contain device identifiers, paths, firmware configuration and event details. Do not publish unreviewed.
The PCR profile lists checked PCR indices, NOT the measured PCR values. Compare MeasuredBoot logs for the values/events.
A failed pre-Windows boot may have no saved Windows log. After Ctrl+Alt+Del this report primarily describes the successful warm boot.
loader.log may be overwritten on the next boot. Check its timestamp and the label/note in summary.json.
Missing/disabled/inaccessible event logs are recorded in collection-issues.txt, not enabled or changed.
No restart/shutdown is performed. BitLocker protection remains as found.
'@
Write-Host "`nReport saved: $report" -ForegroundColor Green
Write-Host "Collection issues: $($script:issues.Count) (see collection-issues.txt)"
