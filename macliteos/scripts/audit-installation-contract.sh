#!/bin/sh
# Read-only G1OS installation contract audit.
set -eu
cd "$(dirname "$0")/.."
FAIL=0
pass(){ echo "INSTALL CONTRACT: PASS: $*"; }
fail(){ echo "INSTALL CONTRACT: FAIL: $*" >&2; FAIL=1; }
need(){ if [ -e "$1" ]; then pass "required source exists: $1"; else fail "missing required source: $1"; fi; }
has(){ if grep -F "$2" "$1" >/dev/null 2>&1; then pass "$3"; else fail "$4"; fi; }
BACKEND=installer/maclite-installer-backend
GUI=installer/mica-installer.c
INIT=boot/g1os-init
GRUB=boot/grub-efi.cfg
ISO=${1:-out/G1OS.iso}
for f in "$BACKEND" "$GUI" "$INIT" "$GRUB" scripts/make-initrd.sh scripts/make-iso.sh; do need "$f"; done
if grep -nE "swapoff[[:space:]]+-a|dmsetup[[:space:]]+remove_all" "$BACKEND" >/dev/null 2>&1; then fail "backend contains host-wide cleanup"; else pass "no host-wide swapoff/dmsetup cleanup"; fi
has "$BACKEND" "validate_physical_target()" "physical target validation is present" "physical target validation is missing"
has "$BACKEND" "refusing virtual/optical installation target" "virtual/optical target rejection is present" "virtual/optical target rejection is missing"
has "$BACKEND" "refusing partition as installation target" "partition-as-disk rejection is present" "partition-as-disk rejection is missing"
has "$BACKEND" "refusing to install to active live installation media" "live-media overwrite protection is present" "live-media overwrite protection is missing"
has "$BACKEND" "target disk is too small" "minimum target capacity check is present" "minimum target capacity check is missing"
has "$BACKEND" "require_partition_nodes()" "partition-node readiness check is present" "partition-node readiness check is missing"
has "$BACKEND" "read_block_tag" "post-format UUID/PARTUUID verification is present" "post-format block identity verification is missing"
has "$BACKEND" "validate_repair_layout" "repair-mode layout validation is present" "repair-mode layout validation is missing"
has "$BACKEND" 'emit_state "VERIFYING"' "authoritative VERIFYING state is present" "authoritative VERIFYING state is missing"
has "$BACKEND" "COMPLETED" "authoritative COMPLETED state is present" "authoritative COMPLETED state is missing"
if grep -F "waitpid(INSTALL_PID, NULL, 0)" "$GUI" >/dev/null 2>&1; then fail "GUI contains an unbounded backend wait"; else pass "GUI backend cancellation is bounded"; fi
has "$GUI" "stop_backend" "GUI has explicit backend shutdown handling" "GUI backend shutdown handling is missing"
has "$GUI" "STAGE = STAGE_COMPLETE;" "SUMMARY -> COMPLETE transition exists" "SUMMARY -> COMPLETE transition is missing"
has "$GUI" "summary_verification_ready" "Complete action requires verification gate" "Complete action verification gate is missing"
has "$INIT" "real G1OS kernel artifact is missing from the mounted ISO" "real-kernel presence is checked" "real-kernel presence check is missing"
has "$INIT" "authoritative G1OS boot manifest is invalid" "boot manifest is validated at runtime" "runtime boot-manifest validation is missing"
has "$INIT" 'mount "$DATA_DEV" /mnt/var/data' "persistent data filesystem is explicitly mounted" "installed data filesystem mount is missing"
has "$INIT" "compositor crashed/exited" "compositor crash is detected" "compositor crash detection is missing"
has "$INIT" "graphical installer exited before installation completion" "installer early-exit is fail-closed" "installer early-exit handling is missing"
for entry in "linux /boot/vmlinuz-maclite init=/init" "initrd /boot/initrd-maclite.img" "search --no-floppy --set=root --file /live/maclite-base.sqfs"; do has "$GRUB" "$entry" "GRUB contract present: $entry" "GRUB contract missing: $entry"; done
if [ -s "$ISO" ] && command -v unsquashfs >/dev/null 2>&1; then
  TMP=$(mktemp -d)
  trap 'chmod -R u+rwx "$TMP" 2>/dev/null || true; rm -rf "$TMP" 2>/dev/null || true' EXIT
  if xorriso -osirrox on -indev "$ISO" -extract / "$TMP/iso" >/dev/null 2>&1; then
    for p in "$TMP/iso/boot/vmlinuz-maclite" "$TMP/iso/boot/initrd-maclite.img" "$TMP/iso/boot/g1os-boot-manifest.txt" "$TMP/iso/EFI/BOOT/BOOTX64.EFI"; do
      if [ -s "$p" ]; then pass "ISO boot artifact present: $p"; else fail "ISO boot artifact missing/empty: $p"; fi
    done
    if unsquashfs -cat "$TMP/iso/live/maclite-base.sqfs" usr/bin/mica-installer >/dev/null 2>&1; then pass "ISO contains mica-installer"; else fail "ISO missing mica-installer"; fi
    if unsquashfs -cat "$TMP/iso/live/maclite-base.sqfs" usr/bin/maclite-installer-backend >/dev/null 2>&1; then pass "ISO contains installer backend"; else fail "ISO missing installer backend"; fi
    if unsquashfs -cat "$TMP/iso/live/maclite-base.sqfs" usr/share/maca-lite/runtime-provenance.sha256 >/dev/null 2>&1; then pass "ISO contains runtime provenance"; else fail "ISO missing runtime provenance"; fi
  else fail "could not extract ISO for installation-contract inspection"; fi
fi
# Exercise the complete backend state machine in dry-run mode. This performs
# no disk writes but must traverse the same PREPARING -> INSTALLING ->
# FINALIZING -> VERIFYING -> COMPLETED contract used by a real install.
DRYRUN_LOG=$(mktemp)
cleanup_dryrun() { rm -f "$DRYRUN_LOG"; }
trap cleanup_dryrun EXIT HUP INT TERM
if timeout 45s sh "$BACKEND" --target /dev/g1os-ci-dryrun --dry-run --json >"$DRYRUN_LOG" 2>&1; then
  pass "installer backend dry-run completed"
else
  fail "installer backend dry-run failed or timed out"
fi
for state in PREPARING INSTALLING FINALIZING VERIFYING COMPLETED; do
  if grep -F '"state":"'"$state"'"' "$DRYRUN_LOG" >/dev/null 2>&1 || grep -F "=== STATE: $state ===" "$DRYRUN_LOG" >/dev/null 2>&1; then
    pass "backend dry-run reached state $state"
  else
    fail "backend dry-run did not reach state $state"
  fi
done
if grep -F '"state":"FAILED"' "$DRYRUN_LOG" >/dev/null 2>&1; then
  fail "backend dry-run emitted FAILED state"
else
  pass "backend dry-run completed without FAILED state"
fi
if grep -F '"progress":100' "$DRYRUN_LOG" >/dev/null 2>&1 || grep -F '100%%' "$DRYRUN_LOG" >/dev/null 2>&1; then
  pass "backend dry-run reached 100 percent"
else
  fail "backend dry-run did not reach 100 percent"
fi
rm -f "$DRYRUN_LOG"
trap - EXIT HUP INT TERM

# Negative argument tests: malformed targets must fail closed before any
# installation action is attempted.
if sh "$BACKEND" --target '../escape' --dry-run >/dev/null 2>&1; then
  fail "backend accepted path traversal target"
else
  pass "backend rejects path traversal target"
fi
if sh "$BACKEND" --unknown-option >/dev/null 2>&1; then
  fail "backend accepted unknown option"
else
  pass "backend rejects unknown option"
fi

if [ "$FAIL" -ne 0 ]; then echo "INSTALLATION CONTRACT AUDIT: FAIL" >&2; exit 1; fi
echo "INSTALLATION CONTRACT AUDIT: PASS"
