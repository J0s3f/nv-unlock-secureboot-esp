#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Reference,
    [Parameter(Mandatory=$true)][string]$Difference
)
$ErrorActionPreference = 'Stop'
$a = Get-Content -LiteralPath (Join-Path $Reference 'summary.json') -Raw | ConvertFrom-Json
$b = Get-Content -LiteralPath (Join-Path $Difference 'summary.json') -Raw | ConvertFrom-Json
Write-Output "Reference:  $Reference"
Write-Output "Difference: $Difference"
Write-Output 'Summary (labels/timestamps differ by design):'
$rows = foreach ($name in $a.PSObject.Properties.Name) {
    $av = ConvertTo-Json -InputObject $a.$name -Depth 8 -Compress
    $bv = ConvertTo-Json -InputObject $b.$name -Depth 8 -Compress
    [pscustomobject]@{Field=$name; Same=($av -eq $bv); Reference=$av; Difference=$bv}
}
$rows | Format-Table -Wrap -AutoSize
foreach ($name in @('bcd-firmware.txt','bcd-all.txt','pcr-validation-profiles.txt','bitlocker-policy.txt','efi-hashes.txt')) {
    $ap = Join-Path $Reference $name
    $bp = Join-Path $Difference $name
    Write-Output "`n--- $name ---"
    if ((Test-Path -LiteralPath $ap) -and (Test-Path -LiteralPath $bp)) {
        # Line-oriented aid, not an order-sensitive BCD or Measured Boot parser.
        $diff = @(Compare-Object -ReferenceObject @(Get-Content -LiteralPath $ap) -DifferenceObject @(Get-Content -LiteralPath $bp))
        if ($diff.Count) { $diff | Format-Table -Wrap -AutoSize } else { Write-Output 'No line differences.' }
    } else { Write-Output 'Missing from one or both reports; inspect collection-issues.txt.' }
}
Write-Output "`n<= reference only; => difference only. A matching PCR profile does NOT prove matching PCR measurements."
Write-Output 'Event logs and binary MeasuredBoot logs require separate analysis; this script does not determine the root cause.'
