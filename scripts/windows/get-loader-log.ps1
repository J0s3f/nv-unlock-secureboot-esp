#Requires -RunAsAdministrator
# Copies \loader.log from the ESP (written by the loader on every boot) and prints the key lines.
param([string]$Letter = "S:", [string]$Out = (Join-Path (Get-Location) "loader-esp.log"))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "common.ps1")
$mounted = Mount-Esp $Letter
try { Copy-Item "$Letter\loader.log" $Out -Force } finally { if ($mounted) { mountvol $Letter /D } }
"saved $Out"; ""
Select-String -Path $Out -Pattern 'armed|CONFIRM:|SELECTOR RESULT|HANDOFF-OUT|NATIVE-GOP: complete|FINAL:|CHAIN-BOOT|CHAIN-PRE: start' |
    ForEach-Object { $_.Line.Substring(0, [Math]::Min(200, $_.Line.Length)) }
