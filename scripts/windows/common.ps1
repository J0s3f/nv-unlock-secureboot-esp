# Shared helpers for the nv-unlock ESP scripts (dot-sourced).
$script:StateDir  = Join-Path $env:ProgramData "nv-unlock-esp"
$script:IdFile    = Join-Path $StateDir "entry-id.txt"
$script:FilesList = Join-Path $StateDir "installed-files.txt"

# Assets each family's loader reads from the ROOT of the volume it was started from
# (same lists as upstream make-usbroot.ps1).
$script:FamilyAssets = @{
    "ga102" = @("booter_load_ga102.bin", "gsp_boot_desc_ga102.bin", "gsp_boot_ga102.bin",
                "fwimage_ga102.bin", "fwsignature_ga102.bin", "scrubber_ad10x.bin",
                "v67-ga102-four-plm.bin")
    "ad102" = @("booter_load_ad102.bin", "gsp_boot_desc_ad102.bin", "gsp_boot_ad102.bin",
                "fwimage_ad102.bin", "fwsignature_ad102.bin", "scrubber_ad10x.bin",
                "v67-ad102-four-plm.bin")
    "tu10x" = @("booter_load_tu10x.bin", "gsp_boot_desc_tu10x.bin", "gsp_boot_tu10x.bin",
                "fwimage_tu10x.bin", "fwsignature_tu10x.bin", "sec2_bl_tu10x.bin",
                "v67-tu10x-four-plm.bin", "gsp-gate.txt")
}

function Get-EntryId {
    if (-not (Test-Path $IdFile)) { throw "no install state ($IdFile) - run install-esp.ps1 first" }
    $id = (Get-Content $IdFile).Trim()
    # bcdedit labels are localized; only check that the entry points at our path
    if (((bcdedit /enum $id 2>&1) -join "`n") -notmatch 'nvunlock') { throw "boot entry $id not found - run install-esp.ps1" }
    return $id
}

function Mount-Esp([string]$Letter) {
    # returns $true if this call mounted it (caller must unmount)
    if (Test-Path "$Letter\EFI\Microsoft\Boot\bootmgfw.efi") { return $false }
    if (Test-Path "$Letter\") { throw "drive $Letter is in use by another volume - pass -Letter X: with a free letter" }
    mountvol $Letter /S
    if (-not (Test-Path "$Letter\EFI\Microsoft\Boot\bootmgfw.efi")) { mountvol $Letter /D; throw "mounted $Letter but it does not look like the Windows ESP" }
    return $true
}

function Suspend-BitLockerOnce {
    $v = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue
    if ($v -and $v.ProtectionStatus -eq 'On') {
        Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 1 | Out-Null
        "BitLocker suspended for 1 reboot (it reseals to the new boot path on that boot)"
    }
}
