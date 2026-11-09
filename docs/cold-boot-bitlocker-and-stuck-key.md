# Cold-boot BitLocker recovery, a stuck mouse key, and the "Invalid Parameter" shim message

Field notes from one machine (Lenovo Legion 5 Pro 16ACH6H, 82JQ, BIOS GKCN65WW, RTX 3070 Laptop `10de:24dd`,
Windows 11 Build 26100, Secure Boot on, BitLocker with TPM, PCR profile 0/2/4/11). Everything below was observed in
`loader.log`, the Windows event logs and the measured-boot (TCG2) logs captured with
[`scripts/windows/diagnostics/Collect-BootDiagnostics.ps1`](../scripts/windows/diagnostics/Collect-BootDiagnostics.ps1).
One machine, one mouse: treat it as a lead, not as a general rule.

## 1. Symptom A: BitLocker recovery key on every cold boot (not on restarts)

- Restart (warm boot): countdown runs, the unlock runs, Windows starts without a prompt.
- Cold boot (power off, power on): BitLocker asks for the recovery key. Ctrl+Alt+Del on that screen then boots Windows
  without a code.

### Cause

The loader log of the failing cold boot:

```
CONFIRM: key Special(LEFT) during the 5s armed countdown - ABORT (no GPU writes this boot)
```

Nobody pressed a key. The unlock was aborted, so the loader skipped its second native-GOP driver load. That driver is
measured into PCR 2; on a normal unlocked boot it appears **twice** in the TCG2 log (before and after the separator),
on the aborted boot only once. BitLocker (PCR 0/2/4/11) sees the mismatch:

- System event 24707: `MismatchedPcr=2`, `ExpectedEventsCount=3`, `ObservedEventsCount=2`.
- Replaying PCR 2 from the two binary TCG2 logs gave different values; the warm-boot value matched the one Windows
  expected.

So: stray key -> unlock aborted -> PCR 2 differs -> recovery. Not a defective TPM, and not only Fast Startup.

After you enter the recovery key, Windows re-binds the key to the PCRs of that (aborted) boot (BitLocker events 892/793).
The next boot with a **complete** unlock differs again; suspend BitLocker for that change
(`manage-bde -protectors -disable C: -RebootCount 1`, the scripts here do it) or expect one more prompt.

BitLocker events 881/813/893 (OS-loader authority / PCR 7) are not the cause; PCR 7 is simply not part of the profile.
Do not remove PCRs or force PCR 7.

## 2. Where the "key" comes from: a mouse with a keyboard interface

Unplugging USB devices narrowed it to the mouse: **Patriot PV570LUXWK** (USB `0C45:7E0C`, Microdia).
With the loader built to log every USB interface (`USB-INV` lines):

```
USB-INV: 0C45:7E0C iface#0 class=03 sub=01 proto=02 (HID boot MOUSE)
USB-INV: 0C45:7E0C iface#1 class=03 sub=01 proto=01 (HID boot KEYBOARD)
```

Cold boot, all devices attached vs. only the mouse unplugged (same loader, same ESP, protection active):

| | mouse attached | mouse unplugged |
|---|---|---|
| USB interfaces seen | 22 | 20 (the two `0C45:7E0C` lines are missing) |
| keys read before the countdown | 80 in 4 s, input never quiet | 0, quiet after 1 s |
| unlock | runs (with the fix below) | runs |

Firmware `read_key()` returns `Special(LEFT)` on every poll from the moment the firmware USB stack comes up
(the first console read blocks for about 5 s while it does). A single flush is therefore not enough:

- `ConIn.Reset()` returned `UNSUPPORTED`; there was nothing buffered to drain.
- A key-quiet settle window (discard everything until 1 s of silence) never ended - the key is streamed continuously.
- `UsbPortReset()` on `0C45:7E0C` (and the other Microdia device, `0C45:8006`, which was not involved) reported
  success but the key came back immediately.

What works: when the input never goes quiet, ignore that key. Two variants were run on this machine:

- **ESC-only fallback** (my first version, v2.1.10 build, hardware-tested): all keys except Esc are ignored for the
  boot. This is what the logs below show.
- **Phantom-key suppression** (what the maintainer asked for in the review of PR #220, now in the PR branch, **not run
  on hardware yet**): the same key value on >= 3 consecutive polls is suppressed for this boot, Space/Enter/other
  keys keep their meaning, Esc is never suppressed, the console prints
  `INPUT-SETTLE: Special(LEFT) repeated 3x - phantom key, suppressed for this boot`. A healthy boot returns after one
  quiet poll instead of waiting 1 s. PR #222 adds `	x-ignore-key.txt` (put `Special(LEFT)` in it) to make this permanent
  without a rebuild.

Cold boot with BitLocker protection on, mouse attached, ESC-only build:

```
INPUT-SETTLE: input never went quiet (stuck/streaming key) - countdown abort is now ESC-ONLY, other keys are ignored
CONFIRM: 5s armed countdown elapsed - PROCEED (marker file opted in)
SELECTOR RESULT: SS0=0x88888888 SS1=0x8
POST-FLR: verified (selectors survive AON)
FINAL: transaction complete, all DMA released
```

No recovery prompt, no event 24707 for those boots.

### Loader change

Upstream PRs: <https://github.com/physicsdolphin/nv-uefi-unlocker/pull/220> (settle + suppression, branch
`J0s3f:input-settle`) and <https://github.com/physicsdolphin/nv-uefi-unlocker/pull/222> (`tx-ignore-key.txt`).
Hardware testing was done with the ESC-only variant on v2.1.10; the current branches build and pass `cargo xt` but
were not run on hardware. Until it is merged you either
build that branch, or unplug the receiver/mouse for the countdown, or use a mouse without a keyboard interface.

Optional `\input-reset.txt` on the ESP root (`usb VID:PID` per line) makes the loader port-reset those devices before
the countdown. It did not help with this mouse; `install-esp.ps1 -UsbResetDevices` writes it if you want to try.

Log size: `loader.log` is deleted and recreated on every boot, so it cannot grow across boots. The new input lines log
at most the first three discarded keys.

## 3. Symptom B: `Invalid Parameter ... falling back to default loader` before the unlocker

Seen on screen at the start of each boot (the unlocker still ran, through shim's fallback):

```
Failed to open ... - Invalid Parameter
Failed to load image ...: Invalid Parameter
start_image() returned Invalid Parameter, falling back to default loader
```

### Cause

The install scripts create the firmware entry with `bcdedit /copy '{bootmgr}'`. Windows writes that entry to NVRAM
with a ~136-byte OptionalData blob starting with `WINDOWS\0 ... BCDOBJECT`. Shim hands OptionalData to the second stage
as load options and gets `Invalid Parameter`. `Repair`/`fix-boot-entry.ps1 -Inspect` on the affected machine:

```
Target: Boot0004, NV Unlock, \EFI\nvunlock\shimx64.efi
Additional load parameters (OptionalData): 136 bytes
OptionalData prefix (hex): 57-49-4E-44-4F-57-53-00-01-00-00-00-88-00-00-00 ...
```

Related upstream reports of the same message with Windows-generated entries: rhboot/shim#506, #696.

### Fix and a trap

`scripts/windows/fix-boot-entry.ps1` rewrites only that `Boot####` variable without the bytes after the device path
(same number, description, device path, attributes), reads it back, checks BootOrder and the Windows entry are
unchanged, backs the original up as JSON. The shim message was gone afterwards.

**Trap:** after that, Windows imports the cleaned variable as a *new* BCD firmware-application object
(`{xxxxxxxx-....-806e6f6e6963}`, type `101fffff`) **and** re-creates the original BCD copy's NVRAM entry, with
OptionalData. Two "NV Unlock" entries, the old one first in the order. Booting that one brings the message back; the
repair script then refuses to run ("found 2"). Fix by hand (this is what was done and verified):

```powershell
bcdedit /enum firmware            # two entries with path \EFI\nvunlock\shimx64.efi
bcdedit /delete "{OLD-copy-id}"   # the one install-esp.ps1 created (see %ProgramData%\nv-unlock-esp\entry-id.txt)
# put the id of the remaining (firmware application) entry into entry-id.txt
```

`fix-boot-entry.ps1` does the same automatically (waits up to 5 min for the second object, deletes the old one,
updates `entry-id.txt`). That automatic part was **not** exercised end to end as a script; its BCD parsing was checked
against the real captured `bcdedit` output only.

## 4. What is not proven

- One machine, one mouse, a few cold boots with protection active; no long-term data.
- The GPU speed-up under Windows was not measured in this session; the log shows the selectors set and surviving FLR
  (`readout1` 0x00400080 -> 0x00000000).
- Windows may add OptionalData to the entry again after updates/BCD changes. Re-run `fix-boot-entry.ps1 -Inspect`.
- Why the mouse streams a key: unknown (firmware USB HID boot-protocol handling of its second interface is the likely
  place, not verified).
