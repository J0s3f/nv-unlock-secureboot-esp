#!/usr/bin/env bash
# One-time setup (run inside WSL / any Debian-or-Ubuntu Linux, no root needed):
#   - downloads Ubuntu's Microsoft-signed shim + MokManager and sbsigntool (.deb, not installed)
#   - extracts them into ./work/root
#   - creates your personal Machine Owner Key (MOK) in ./work/mok
#
# Usage:  bash setup-signing.sh [WORK_DIR]        (default: <repo>/work)
#
# KEEP work/mok/MOK.key PRIVATE. Anything signed with it will boot on every machine
# that has enrolled MOK.cer, even with Secure Boot enabled.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${1:-$REPO/work}"
mkdir -p "$WORK/pkgs" "$WORK/root" "$WORK/mok"
chmod 700 "$WORK/mok"

need() { command -v "$1" >/dev/null || { echo "missing tool: $1 (sudo apt install $2)"; exit 1; }; }
need apt-get apt; need dpkg dpkg; need openssl openssl; need objcopy binutils; need objdump binutils

echo "[1/3] downloading shim-signed + sbsigntool packages (no install)"
( cd "$WORK/pkgs" && apt-get download shim-signed sbsigntool )
for f in "$WORK"/pkgs/*.deb; do dpkg -x "$f" "$WORK/root"; done
test -f "$WORK/root/usr/lib/shim/shimx64.efi.signed.latest"
test -f "$WORK/root/usr/lib/shim/mmx64.efi"
test -x "$WORK/root/usr/bin/sbsign"

echo "[2/3] shim signature (should be issued by 'Microsoft Corporation UEFI CA 2011'):"
"$WORK/root/usr/bin/sbverify" --list "$WORK/root/usr/lib/shim/shimx64.efi.signed.latest" | grep -E "subject|issuer" | head -4

echo "[3/3] Machine Owner Key"
if [ -f "$WORK/mok/MOK.key" ]; then
  echo "existing key kept: $WORK/mok/MOK.key"
else
  openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -subj "/CN=nv-unlock local MOK/" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "$WORK/mok/MOK.key" -out "$WORK/mok/MOK.crt" 2>/dev/null
  chmod 600 "$WORK/mok/MOK.key"
fi
openssl x509 -in "$WORK/mok/MOK.crt" -outform DER -out "$WORK/mok/MOK.cer"
openssl x509 -in "$WORK/mok/MOK.crt" -noout -subject -enddate -fingerprint -sha256
echo
echo "Note the SHA256 fingerprint above - MokManager shows it when you enroll MOK.cer."
echo "done: $WORK"
