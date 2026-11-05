#!/usr/bin/env bash
# Wraps the nv-uefi-unlocker loader in Ubuntu's Microsoft-signed shim + your MOK.
#
# Usage:  bash sign-usbroot.sh /mnt/<drive>/path/to/usbroot [WORK_DIR]
#   usbroot  = output folder of upstream make-usbroot.ps1 / make-usbroot.sh
#   WORK_DIR = folder created by setup-signing.sh (default: <repo>/work)
#
# Result: <usbroot>-sb/  (copy its CONTENTS to a FAT32 stick, or use install-esp.ps1)
#   EFI/BOOT/BOOTX64.EFI  = shim (MS UEFI CA 2011 signed)
#   EFI/BOOT/mmx64.efi    = MokManager
#   EFI/BOOT/grubx64.efi  = unlocker + .sbat section, signed with your MOK
#   MOK.cer               = certificate to enroll in MokManager ("Enroll key from disk")
#
# Env: NVU_VERSION  version string written into the SBAT entry (default: "upstream")
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${1:?usage: sign-usbroot.sh <usbroot> [WORK_DIR]}"; SRC="${SRC%/}"
WORK="${2:-$REPO/work}"
DST="${SRC}-sb"
SB="$WORK/root/usr/bin"
SHIM="$WORK/root/usr/lib/shim"
LOADER="$SRC/EFI/BOOT/BOOTX64.EFI"
VER="${NVU_VERSION:-upstream}"
[ -f "$LOADER" ] || { echo "missing $LOADER (run upstream make-usbroot first)"; exit 1; }
[ -f "$WORK/mok/MOK.key" ] || { echo "missing $WORK/mok/MOK.key (run setup-signing.sh first)"; exit 1; }

rm -rf "$DST"; cp -r "$SRC" "$DST"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp "$LOADER" "$TMP/loader.efi"

# 1) SBAT section - shim refuses second-stage images without one when Secure Boot is on
if objdump -h "$TMP/loader.efi" | grep -q '\.sbat'; then
  echo "loader already has a .sbat section"
else
  cat > "$TMP/sbat.csv" <<CSV
sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md
nvunlock,1,nv-uefi-unlocker,nvunlock,${VER},https://github.com/physicsdolphin/nv-uefi-unlocker
CSV
  # place the new section after the last one, aligned to SectionAlignment (bash hex math; mawk has no strtonum)
  ALIGN=$(( 0x$(objdump -p "$TMP/loader.efi" | awk '/SectionAlignment/{print $2}') ))
  END=0
  while read -r size vma; do
    e=$(( 0x$vma + 0x$size )); (( e > END )) && END=$e
  done < <(objdump -h "$TMP/loader.efi" | awk '$1 ~ /^[0-9]+$/ {print $3, $4}')
  VMA=$(( (END + ALIGN - 1) / ALIGN * ALIGN ))
  printf 'SectionAlignment=0x%x lastEnd=0x%x -> .sbat at VMA 0x%x\n' "$ALIGN" "$END" "$VMA"
  objcopy --add-section .sbat="$TMP/sbat.csv" \
          --set-section-flags .sbat=contents,alloc,load,readonly,data \
          --change-section-vma .sbat="$VMA" \
          "$TMP/loader.efi" "$TMP/loader-sbat.efi"
  mv "$TMP/loader-sbat.efi" "$TMP/loader.efi"
  objdump -h "$TMP/loader.efi" | grep -A1 '\.sbat'
fi

# 2) sign with your MOK
"$SB/sbsign" --key "$WORK/mok/MOK.key" --cert "$WORK/mok/MOK.crt" \
  --output "$DST/EFI/BOOT/grubx64.efi" "$TMP/loader.efi"
"$SB/sbverify" --cert "$WORK/mok/MOK.crt" "$DST/EFI/BOOT/grubx64.efi"

# 3) shim + MokManager + certificate
cp "$SHIM/shimx64.efi.signed.latest" "$DST/EFI/BOOT/BOOTX64.EFI"
cp "$SHIM/mmx64.efi" "$DST/EFI/BOOT/mmx64.efi"
cp "$WORK/mok/MOK.cer" "$DST/MOK.cer"

echo; echo "done -> $DST"
( cd "$DST" && sha256sum EFI/BOOT/*.efi EFI/BOOT/*.EFI MOK.cer 2>/dev/null | sort -u )
