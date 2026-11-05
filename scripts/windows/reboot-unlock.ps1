#Requires -RunAsAdministrator
# One-shot: pause BitLocker for one reboot, boot "NV Unlock" ONCE, restart.
# The boot after that follows the normal firmware boot order again.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "common.ps1")
$id = Get-EntryId
Suspend-BitLockerOnce
bcdedit /set '{fwbootmgr}' bootsequence $id | Out-Null
"next boot: NV Unlock -> Windows. Restarting in 5 s (Ctrl+C to cancel; then run: bcdedit /deletevalue {fwbootmgr} bootsequence)"
shutdown /r /t 5
