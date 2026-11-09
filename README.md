# nv-unlock-secureboot-esp

Run [nv-uefi-unlocker](https://github.com/physicsdolphin/nv-uefi-unlocker) **from the internal disk with Secure Boot left ON**. You don't need a USB stick, you don't turn off Secure Boot, and BitLocker doesn't ask for the recovery key.

This repository contains **no unlocker code, no NVIDIA firmware and no shim binaries**. It is a guide plus helper scripts:

- `scripts/wsl/setup-signing.sh` downloads Ubuntu's Microsoft-signed `shim` and `sbsigntool` (no root needed), then creates your own Machine Owner Key (MOK).
- `scripts/wsl/sign-usbroot.sh` adds an SBAT section to the upstream loader, signs it with your MOK, and places it behind shim.
- `scripts/windows/install-esp.ps1` copies everything to the EFI System Partition (ESP) and adds a firmware boot entry, **"NV Unlock"**.
- `scripts/windows/reboot-unlock.ps1` does one unlocked boot.
- `scripts/windows/set-default.ps1` makes the unlock run on every boot, or reverts that.
- `scripts/windows/uninstall-esp.ps1` removes everything again.
- `scripts/windows/fix-boot-entry.ps1` strips the Windows OptionalData from the firmware entry (called by `install-esp.ps1`; fixes shim's `Invalid Parameter` message).
- `scripts/windows/replace-loader.ps1` swaps only `grubx64.efi` for a new signed build, with backup and `-Rollback`.
- `scripts/windows/diagnostics/` read-only boot/BitLocker/TPM diagnostics (`Collect-BootDiagnostics.ps1`).
- `scripts/windows/get-loader-log.ps1` reads the loader's log from the ESP.
- `bench/bench.py` is a before/after tensor throughput benchmark.

> [!WARNING]
> You run third-party code that writes GPU registers before the OS starts, and you add your own key to the Secure Boot chain of trust. Everything here is **at your own risk**. Read the upstream README first, especially its FAQ and recovery guide. Make sure you have your **BitLocker recovery key** before you start (<https://aka.ms/myrecoverykey>).

---

## What the unlock does (and doesn't do)

GeForce cards run tensor-core math with **FP32 accumulation** (FP16/BF16/TF32 → FP32) at half rate. The upstream loader lifts that limit before the NVIDIA driver loads. The change lives in volatile GPU registers and is gone after a full power-off, which is why it has to run on every boot.

- **Helps:** mixed-precision compute. That includes PyTorch training and fine-tuning, diffusion models, TF32 matmuls, and prompt processing (prefill) of local language models.
- **Doesn't help:** games. Rasterization runs on the normal FP32 shader cores, and DLSS doesn't use the throttled path in any meaningful way. Token generation of language models is mostly limited by memory bandwidth, so it barely changes.
- **Power limit:** The unlocked card does twice the work per clock, so a power-limited GPU (especially a laptop) lowers its clocks. Expect **less than 2×**. One power-limited laptop RTX 30 GPU measured about **1.5×** on FP16, BF16 and TF32, while FP32 (the control) stayed unchanged.

## How the boot chain works

```
UEFI firmware (Secure Boot ON)
 └─ \EFI\nvunlock\shimx64.efi    Ubuntu shim, signed by "Microsoft Corporation UEFI CA 2011"  → trusted via db
     └─ \EFI\nvunlock\grubx64.efi   nv-uefi-unlocker + .sbat, signed with YOUR MOK            → trusted via MokList
         ├─ reads \*.bin from the ESP root, unlocks the GPU, rebuilds the console (GOP)
         └─ chains \EFI\Microsoft\Boot\bootmgfw.efi   signed by Microsoft                    → trusted via db
             └─ Windows (BitLocker unseals after one reseal boot)
```

- **Why shim:** Shim is already trusted by most PCs because the Microsoft third-party UEFI CA is in `db`. It trusts additional keys that you enroll yourself (MOK). Your platform keys (PK/KEK/db) are **not modified**, and you don't need firmware "setup mode".
- **Why the SBAT section:** Shim 15.3+ refuses to start a second-stage image without a `.sbat` section when Secure Boot is on. The upstream binary has none, so `sign-usbroot.sh` adds one with `objcopy`.
- **Why the ESP root:** The loader reads its assets from the root of the volume it was started from. On the ESP that means the root of the ESP, which needs about 85 MB per GPU family.
- **Why chaining works:** The loader walks the firmware `BootOrder`. It skips **its own entry** and the Windows entry on the same ESP, then falls back to a volume scan for `\EFI\Microsoft\Boot\bootmgfw.efi`. So "NV Unlock" can be the first boot entry without causing a boot loop.

## Requirements

| | |
|---|---|
| GPU | Supported by upstream (RTX 20/30/40, see their compatibility matrix). **Tested here: RTX 30 laptop (ga102 family).** The `ad102` and `tu10x` asset lists come from upstream `make-usbroot.ps1` but haven't been tested with this ESP setup. Turing also needs upstream's GSP prerequisites. |
| Firmware | UEFI boot, CSM off (upstream recommends this), and the **Microsoft third-party UEFI CA trusted** (see step 0). |
| OS | Windows 10/11 with PowerShell 7 (`pwsh`). Windows PowerShell 5.1 should work but is untested. |
| Linux tools | WSL with Ubuntu or Debian (or any Debian-based Linux) for signing: `apt-get`, `dpkg`, `openssl`, `binutils`. |
| ESP | At least about 100 MB free (`install-esp.ps1` checks this). |
| Benchmark (optional) | Python 3.10+ and PyTorch with CUDA. |

Laptops: upstream recommends **dGPU-only / MUX mode** if available.

---

## Step-by-step

All Windows commands go in an **elevated** PowerShell (Run as administrator), unless noted otherwise.

Downloaded scripts carry the "Mark of the Web", so with the default `RemoteSigned` policy you need to start them with a per-process bypass, for example `pwsh -NoProfile -ExecutionPolicy Bypass -File .\script.ps1`. You don't need to change the machine policy.

### 0. Check Secure Boot and the third-party CA

```powershell
Confirm-SecureBootUEFI
[Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI db).Bytes) -match 'Microsoft Corporation UEFI CA 2011'
```

Both lines must print `True`. If the second prints `False`, enable an option like **"Allow Microsoft 3rd Party UEFI CA"** in your firmware setup. Without it, shim can't start.

Then check BitLocker and **write down or save the recovery key**:

```powershell
manage-bde -status $env:SystemDrive
```

### 1. Baseline benchmark (optional, but you want proof)

```powershell
cd bench
py -3.12 -m venv .venv
.venv\Scripts\python -m pip install torch --index-url https://download.pytorch.org/whl/cu128
.venv\Scripts\python bench.py before
```

Plug in the power adapter, use the same vendor performance mode for both runs, start with a cool GPU and close other GPU apps. The script measures FP32 (control), TF32, FP16 and BF16 matmuls with FP32 accumulation.

### 2. Build the upstream stick root

Download the latest upstream release from <https://github.com/physicsdolphin/nv-uefi-unlocker/releases> and extract it, for example to `C:\nvu\release`. Then generate the assets. A normal (non-admin) shell is fine:

```powershell
cd C:\nvu\release
pwsh -NoProfile -ExecutionPolicy Bypass -File .\make-usbroot.ps1 -Family 30   # 40 / 30 / 20, or omit to auto-detect
```

The script downloads pinned public NVIDIA packages, checks their SHA-256 and writes `C:\nvu\release\usbroot\`. Read the script before you run it.

### 3. One-time signing setup (WSL)

Clone this repo somewhere WSL can reach (for example `C:\nvu\nv-unlock-secureboot-esp`). Then:

```bash
cd /mnt/c/nvu/nv-unlock-secureboot-esp
bash scripts/wsl/setup-signing.sh
```

This creates `work/` (git-ignored):

- `work/root/...` contains the extracted shim, MokManager and sbsign.
- `work/mok/MOK.key` is your **private signing key**. Keep it secret (see [Security](#security)).
- `work/mok/MOK.cer` is the certificate you enroll. **Note the SHA-256 fingerprint** that the script prints.

### 4. Sign the loader

```bash
NVU_VERSION=2.1.10 bash scripts/wsl/sign-usbroot.sh /mnt/c/nvu/release/usbroot
```

This produces `C:\nvu\release\usbroot-sb\`. The output should contain `Signature verification OK`. Re-run this step after every upstream update, because each new loader needs a new signature.

### 5. Enroll your MOK (first boot only)

The first time shim starts the loader, the loader isn't trusted yet. Shim then opens **MokManager** by itself. The easiest way is a **USB test run**. It's also a good dry run before you touch the ESP:

1. Copy the **contents** of `usbroot-sb\` to a FAT32 stick. Back up the stick first. The command doesn't delete anything:
   ```powershell
   xcopy "C:\nvu\release\usbroot-sb\*" X:\ /E /H /Y
   ```
2. `Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 2`
3. Boot the stick once. The most reliable way is *Settings → System → Recovery → Advanced startup → Restart now → Use a device*. Alternatively use the firmware boot menu (vendor key, often F12 / F8 / F11 / Esc, or a "Novo" pinhole button).
4. Shim reports that it can't verify `grubx64.efi` and opens MokManager. Choose **Enroll key from disk → (stick) → MOK.cer → Continue → Yes → Reboot**. Check that the shown fingerprint matches the one from step 3.
5. Boot the stick again. The upstream banner appears. Press **Space/Enter** to confirm, and Windows starts afterwards.
6. Check `X:\loader.log`. You want `SELECTOR RESULT: transaction complete` and a `HANDOFF-OUT` line with `readout1=0x00000000`. Then run `bench.py after-usb` and compare (step 9).

The MOK stays enrolled in NVRAM. You only do this once per machine and key.

> Without a stick: `install-esp.ps1` also copies `MOK.cer` to `\EFI\nvunlock\`. The first boot of the ESP entry (step 7) then opens MokManager, and you pick `MOK.cer` from the EFI partition. This route is **untested**. The USB route above is tested.

### 6. Install on the ESP

```powershell
cd C:\nvu\nv-unlock-secureboot-esp\scripts\windows
pwsh -NoProfile -ExecutionPolicy Bypass -File .\install-esp.ps1 -Src C:\nvu\release\usbroot-sb
```

What the script does:

- It temporarily mounts the ESP (`S:` by default, change with `-Letter`) and checks the free space.
- It copies the signed EFI files to `\EFI\nvunlock\` and the family assets to the ESP root. It refuses to overwrite a foreign file with different content.
- It creates `\i_know_what_i_am_doing.txt`. This is upstream's own marker: **5 s countdown, then auto-run, and any key aborts**. Pass `-NoAutoRun` to keep upstream's "press Space/Enter within 30 s" behaviour.
- It adds the firmware boot entry **"NV Unlock"** at the **end** of the boot order, so normal boots don't change yet.
- It then runs `fix-boot-entry.ps1`, which removes the Windows OptionalData from that entry (skip with `-NoFixEntry`). Without this, shim prints `Invalid Parameter ... falling back to default loader` at every boot. See [Duplicate entry](#duplicate-nv-unlock-entry).
- Optional `-UsbResetDevices 0C45:7E0C` writes `\input-reset.txt` (needs the loader from [upstream PR #220](https://github.com/physicsdolphin/nv-uefi-unlocker/pull/220)).
- It stores its state (entry id and the list of installed files) in `%ProgramData%\nv-unlock-esp\`.

### 7. One unlocked boot from the disk

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\reboot-unlock.ps1
```

This pauses BitLocker for one reboot, sets `bootsequence` (a one-time boot target) to "NV Unlock" and restarts. **Don't press a key** during the 5 s countdown. Back in Windows:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\get-loader-log.ps1
```

You should see `5s armed countdown elapsed - PROCEED`, `SELECTOR RESULT: SS0=0x88888888 SS1=0x8` (ga102/ad102), `readout1=0x00000000`, and `StartImage ... bootmgfw.efi`.

### 8. Make it the default (optional)

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\set-default.ps1
```

- It moves "NV Unlock" to the **first** place in the firmware boot order.
- It disables **Fast Startup**, because Fast Startup is a hybrid hibernate and the unlock doesn't reliably survive an S4 resume. Pass `-KeepFastStartup` to skip this.
- It pauses BitLocker for one reboot, so BitLocker reseals to the new boot path.

Use **Restart** once to apply. From then on every cold boot shows the countdown, unlocks the GPU and starts Windows. BitLocker doesn't prompt, because the boot path is the same every time.

To revert: `.\set-default.ps1 -Revert` puts Windows Boot Manager first again and keeps the entry at the end.

### 9. Verify with the benchmark

```powershell
cd bench
.venv\Scripts\python bench.py after
.venv\Scripts\python bench.py --compare before after
```

FP16/BF16/TF32 should go up clearly, while FP32 (the control) should stay about the same. Upstream also ships `ssdiag-x86_64-windows.exe` to read the unlock state.

---

## Daily use and caveats

- **Power-off resets the unlock.** With the default entry it runs again at every boot. Without the default entry, use `reboot-unlock.ps1`.
- **Sleep and hibernate** may re-lock the card (see the upstream FAQ). Restarting fixes it.
- **Windows updates and firmware updates** sometimes move Windows Boot Manager back to the first place. Nothing breaks, the card just runs locked. Re-run `set-default.ps1`.
- **Skipping the unlock once:** press any key during the countdown. If a USB device keeps reporting a key (seen with a mouse that has a keyboard interface), a loader with [PR #220](https://github.com/physicsdolphin/nv-uefi-unlocker/pull/220) switches to *Esc only* and says so in `loader.log`; without it the countdown aborts by itself on cold boots and BitLocker asks for the recovery key. Details: [docs/cold-boot-bitlocker-and-stuck-key.md](docs/cold-boot-bitlocker-and-stuck-key.md).
- **If a boot hangs or the screen stays black:** don't retry in the same session. Power off completely, choose *Windows Boot Manager* in the firmware boot menu, and read `loader.log` (upstream recovery guide).
- **Switching between booting with and without the unlocker** changes the measured boot path. Each switch makes BitLocker ask for the recovery key unless you suspend it first: `Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 1`. The scripts do this whenever they change the boot path.
- **Upstream update:** repeat steps 2, 4 and 6. `install-esp.ps1` updates the files in place and keeps the boot entry.

## Uninstall

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\uninstall-esp.ps1
```

This removes the boot entry, `\EFI\nvunlock\`, the copied assets, the marker file and `loader.log` from the ESP, and the state folder. It also pauses BitLocker for one reboot.

### Removing the MOK

The MOK stays enrolled until you delete it. You need `mokutil` (Linux, for example a live USB):

```bash
sudo mokutil --delete MOK.cer      # set a one-time password
# reboot -> MokManager -> Delete MOK -> confirm with that password
```

## Security

- **`work/mok/MOK.key` is a Secure Boot signing key for every machine that enrolled its certificate.** Anyone who has it can sign bootloaders or kernels that your PC will run with Secure Boot on. Store it encrypted or offline, or delete it after signing. You can always create a new key and enroll the new `MOK.cer`.
- Never commit `work/`. It's in `.gitignore`.
- The MOK only extends trust for images that **shim** loads. Firmware-loaded images (for example `bootmgfw.efi` and option ROMs) are still checked against `db`.
- Each extra binary in the boot chain is extra attack surface. Only sign loaders you have built yourself or whose release you trust.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `make-usbroot.ps1 cannot be loaded ... not digitally signed` | Mark of the Web with `RemoteSigned`. Start it with `pwsh -ExecutionPolicy Bypass -File ...`. |
| Firmware boot menu key does nothing | Fast Boot is skipping the menu. Use *Advanced startup → Use a device*, or the vendor's Novo/pinhole button. |
| Shim: `Verification failed: (0x1A) Security Violation` on every boot | The MOK isn't enrolled, or the loader was signed with a different key. Enroll `MOK.cer` (step 5). |
| Shim: `SBAT data not found` / `SBAT self-check failed` | The loader wasn't processed by `sign-usbroot.sh`, or the shim/SBAT revocation level is too new. Re-run step 4. |
| Shim doesn't start at all | The third-party UEFI CA isn't trusted (step 0), or shim was revoked by a DBX update. Run `setup-signing.sh` again in a fresh `work/` to get the current shim. |
| BitLocker recovery screen | The boot path changed without a suspend. Enter the key once, then use the scripts (they suspend automatically). |
| `install-esp.ps1`: not enough space | The ESP is too small (common: 100 MB). Build only your GPU's family (`-Family 30` etc.), or resize the ESP. |
| `drive S: is in use` | Pass `-Letter X:` with a free drive letter to every script that takes one. |
| Unlock not active after wake-up | Sleep/hibernate re-locked the card. Restart. |
| Recovery key on cold boot only, `loader.log` says `key Special(LEFT) during the 5s armed countdown - ABORT` | A USB device reports a key by itself. Unplug it to confirm, then use a loader with PR #220 (ESC-only fallback). See [docs](docs/cold-boot-bitlocker-and-stuck-key.md). |
| Shim prints `Invalid Parameter ... falling back to default loader` | The firmware entry carries the Windows OptionalData. Run `fix-boot-entry.ps1`. |
| Two "NV Unlock" entries in `bcdedit /enum firmware` | See [Duplicate entry](#duplicate-nv-unlock-entry). |

### Duplicate NV Unlock entry

After `fix-boot-entry.ps1` writes the cleaned `Boot####`, Windows may import it as a second BCD object and re-create
the old copy (with OptionalData) as another firmware entry, listed first. The script cleans this up automatically; to do it by hand:

```powershell
bcdedit /enum firmware                    # two entries with path \EFI\nvunlock\shimx64.efi
Get-Content "$env:ProgramData\nv-unlock-esp\entry-id.txt"   # the OLD copy created by install-esp.ps1
bcdedit /delete "{old-id}"                # delete only the old copy
Set-Content "$env:ProgramData\nv-unlock-esp\entry-id.txt" "{id-of-the-remaining-entry}"
```

The remaining entry is of type "Firmware application (101fffff)" and has no OptionalData
(`fix-boot-entry.ps1 -Inspect` shows 0 bytes). Background and evidence: [docs/cold-boot-bitlocker-and-stuck-key.md](docs/cold-boot-bitlocker-and-stuck-key.md).

## Credits

- [physicsdolphin/nv-uefi-unlocker](https://github.com/physicsdolphin/nv-uefi-unlocker): the UEFI unlocker this guide wraps
- [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock): the original unlock transaction (Linux kernel module)
- [rhboot/shim](https://github.com/rhboot/shim), Ubuntu `shim-signed` and `sbsigntool`

This project isn't affiliated with NVIDIA, Microsoft, Canonical or the upstream authors. Licensed under MIT (scripts and documentation only).
