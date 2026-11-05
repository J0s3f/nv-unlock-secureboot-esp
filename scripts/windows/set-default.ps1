#Requires -RunAsAdministrator
<#
Makes "NV Unlock" the FIRST firmware boot entry: every boot runs the countdown, unlocks,
then chains Windows Boot Manager.

  .\set-default.ps1                    make it default, disable Fast Startup, pause BitLocker once
  .\set-default.ps1 -KeepFastStartup   same, but leave Fast Startup alone
  .\set-default.ps1 -Revert            Windows Boot Manager first again (NV Unlock stays, last)

Fallback if a boot ever misbehaves: press any key during the countdown (skips the unlock),
or pick "Windows Boot Manager" in the firmware boot menu.
#>
param([switch]$Revert, [switch]$KeepFastStartup)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "common.ps1")
$id = Get-EntryId

if ($Revert) {
    bcdedit /set '{fwbootmgr}' displayorder '{bootmgr}' /addfirst | Out-Null
    bcdedit /set '{fwbootmgr}' displayorder $id /addlast | Out-Null
    "reverted: Windows Boot Manager first, NV Unlock last"
} else {
    bcdedit /set '{fwbootmgr}' displayorder $id /addfirst | Out-Null
    bcdedit /deletevalue '{fwbootmgr}' bootsequence 2>$null | Out-Null
    "NV Unlock is now the first boot entry"
    if (-not $KeepFastStartup) {
        # Fast Startup = hybrid hibernate; the unlock does not reliably survive an S4 resume
        reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f | Out-Null
        "Fast Startup disabled"
    }
}
Suspend-BitLockerOnce
""; "firmware boot order:"
bcdedit /enum '{fwbootmgr}'
""; "Use Restart (not Shut down) once to apply."
