#!/bin/sh
# shellcheck disable=SC2016
# Static production-readiness audit. This does not modify disks or boot media.
set -eu
cd "$(dirname "$0")/.."
ISO=${1:-}
FAIL=0
pass(){ echo "PASS: $*"; }
fail(){ echo "FAIL: $*" >&2; FAIL=1; }
need_file(){ if [ -e "$1" ]; then pass "source present: $1"; else fail "source missing: $1"; fi }
need_exec(){ if [ -x "$1" ]; then pass "executable present: $1"; else fail "executable missing: $1"; fi }

for f in \
  boot/g1os-init boot/g1os-ui-health.c boot/g1os-failure-ui.c boot/grub-efi.cfg \
  boot/initrd.list compositor/comp.c installer/mica-installer.c installer/maclite-installer-backend \
  scripts/build.sh scripts/make-initrd.sh scripts/make-iso.sh scripts/validate-boot-artifacts.sh Makefile; do
  need_file "$f"
done

if grep -F '/usr/bin/mica-comp --backend "$BACKEND"' boot/g1os-init >/dev/null; then
  pass "live installer starts compositor without desktop --session"
else
  fail "live installer still uses desktop session path"
fi
if grep -F '/usr/bin/mica-installer' boot/g1os-init >/dev/null; then
  pass "live installer explicitly launches mica-installer"
else
  fail "mica-installer launch is missing"
fi
if grep -F 'Graphical installer ready: compositor responsive and installer surface present' boot/g1os-init >/dev/null; then
  pass "graphical readiness requires compositor + installer health"
else
  fail "graphical readiness gate missing"
fi
if grep -F 'g1os-failure-ui' boot/g1os-init >/dev/null; then
  pass "startup failures use framebuffer diagnostic UI"
else
  fail "startup failure diagnostic UI missing"
fi
if grep -F 'mount "$DATA_DEV" /mnt/var/data' boot/g1os-init >/dev/null; then
  pass "installed boot mounts the persistent data partition"
else
  fail "installed boot does not mount the persistent data partition"
fi

if grep -F 'video=efifb' boot/grub-efi.cfg >/dev/null; then pass "Safe Graphics preserves EFI framebuffer"; else fail "Safe Graphics disables/omits EFI framebuffer"; fi
if grep -F 'nomodeset' boot/grub-efi.cfg >/dev/null; then pass "Safe Graphics requests conservative GPU mode"; else fail "Safe Graphics command line missing"; fi
if grep -F 'panic=-1' boot/grub-efi.cfg >/dev/null; then pass "kernel panic does not trigger automatic reboot"; else fail "panic reboot behavior is unsafe"; fi

for b in mica-comp mica-installer mica-shell g1os-ui-health g1os-failure-ui; do
  need_exec "out/$b"
done
for b in mica-comp mica-installer mica-shell g1os-ui-health; do
  if grep -F "out/$b" scripts/make-initrd.sh >/dev/null; then
    pass "initrd requires current build output for $b"
  else
    fail "initrd does not require current build output for $b"
  fi
done

if grep -F 'Re-apply the current build outputs after rootfs/usr was copied.' scripts/make-iso.sh >/dev/null; then
  pass "ISO prevents rootfs binaries from overwriting fresh build outputs"
else
  fail "ISO may package stale rootfs binaries"
fi
if grep -F 'runtime-provenance.sha256' scripts/make-iso.sh >/dev/null; then
  pass "ISO records runtime binary provenance"
else
  fail "runtime provenance is missing"
fi
if grep -F '/tmp/initrd_inspect' scripts/make-iso.sh >/dev/null; then
  fail "ISO build depends on stale external /tmp/initrd_inspect content"
else
  pass "ISO runtime content comes from the current initrd/build"
fi
if grep -Eq 'blkid.*\|\|[[:space:]]*echo[[:space:]]*"[0-9A-Za-z-]+"' installer/maclite-installer-backend >/dev/null; then
  fail "installer can substitute fabricated block UUIDs after blkid failure"
else
  pass "installer fails closed when real filesystem/PARTUUID values cannot be read"
fi
if grep -F 'fdisk "$DEV" 2>/dev/null || true' installer/maclite-installer-backend >/dev/null; then
  fail "fdisk partitioning failure is silently ignored"
else
  pass "fdisk partitioning failures are fatal"
fi
if grep -F 'partprobe "$DEV" 2>/dev/null || true' installer/maclite-installer-backend >/dev/null; then
  fail "partition-table reread failure is silently ignored"
else
  pass "partition-table reread failures are fatal"
fi

for f in boot/g1os-init scripts/make-initrd.sh scripts/make-iso.sh; do
  if grep -nE '(^|;)[[:space:]]*(true|:)[[:space:]]*(#|$)' "$f" >/dev/null; then
    fail "suspicious unconditional success token in $f"
  else
    pass "no unconditional success token in $f"
  fi
done

if [ -n "$ISO" ]; then
  [ -s "$ISO" ] || fail "ISO is missing or empty: $ISO"
  if command -v xorriso >/dev/null 2>&1; then
    LIST=$(mktemp)
    trap 'rm -f "$LIST"' EXIT
    xorriso -indev "$ISO" -find / -exec report_lba >"$LIST" 2>/dev/null || fail "cannot inspect ISO"
    for p in boot/vmlinuz-maclite boot/initrd-maclite.img live/maclite-base.sqfs EFI/BOOT/BOOTX64.EFI; do
      if grep -Fi "$p" "$LIST" >/dev/null; then pass "ISO contains $p"; else fail "ISO missing $p"; fi
    done
    if grep -Fi "/base/" "$LIST" >/dev/null; then
      fail "ISO contains leaked uncompressed rootfs staging tree (/base)"
    else
      pass "ISO does not contain leaked staging tree (/base)"
    fi
  else
    fail "xorriso is required for ISO inspection"
  fi
fi

if [ "$FAIL" -ne 0 ]; then
  echo "PRODUCTION AUDIT: FAIL" >&2
  exit 1
fi
echo "PRODUCTION AUDIT: PASS"
