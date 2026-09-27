#!/bin/sh
# Assemble a fresh, self-contained G1OS ISO and independently verify it.
set -eu
cd "$(dirname "$0")/.."
VERIFY=1
for arg in "$@"; do
  case "$arg" in
    --verify) VERIFY=1 ;;
    -h|--help) echo "usage: sh scripts/make-iso.sh [--verify]"; exit 0 ;;
    *) echo "ERROR: unknown option: $arg" >&2; exit 2 ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $1" >&2; exit 2; }; }
for tool in xorriso mksquashfs cpio sha256sum; do need "$tool"; done
if ! command -v grub-mkimage >/dev/null 2>&1; then
  if [ ! -s "boot/bootx64.efi" ] && [ ! -s "out/bootx64.efi" ] && [ ! -s "../releases/bootx64.efi" ] && [ ! -s "/Volumes/G1OS/EFI/BOOT/BOOTX64.EFI" ]; then
    echo "ERROR: grub-mkimage missing and no pre-built bootx64.efi found" >&2
    exit 2
  fi
fi
if [ "$VERIFY" = 1 ]; then
  for tool in unsquashfs file; do need "$tool"; done
fi

KERNEL="${G1OS_KERNEL:-out/vmlinuz-maclite}"
INITRD="${G1OS_INITRD:-out/initrd-maclite.img}"
KERNEL_MANIFEST="${G1OS_KERNEL_MANIFEST:-out/g1os-kernel-manifest.txt}"
INITRD_MANIFEST="${G1OS_INITRD_MANIFEST:-out/g1os-initrd-manifest.txt}"
case "$KERNEL" in /*) ;; *) KERNEL="$PWD/$KERNEL" ;; esac
case "$INITRD" in /*) ;; *) INITRD="$PWD/$INITRD" ;; esac
case "$KERNEL_MANIFEST" in /*) ;; *) KERNEL_MANIFEST="$PWD/$KERNEL_MANIFEST" ;; esac
case "$INITRD_MANIFEST" in /*) ;; *) INITRD_MANIFEST="$PWD/$INITRD_MANIFEST" ;; esac
[ -s "$KERNEL" ] || { echo "ERROR: authoritative G1OS kernel artifact missing: $KERNEL" >&2; exit 3; }
[ -s "$INITRD" ] || { echo "ERROR: authoritative G1OS initramfs artifact missing: $INITRD" >&2; exit 3; }
[ -s "$KERNEL_MANIFEST" ] || { echo "ERROR: authoritative G1OS kernel manifest missing: $KERNEL_MANIFEST" >&2; exit 3; }
[ -s "$INITRD_MANIFEST" ] || { echo "ERROR: authoritative G1OS initramfs manifest missing: $INITRD_MANIFEST" >&2; exit 3; }
KERNEL_MANIFEST_MAGIC=$(sed -n 's/^G1OS_KERNEL_MANIFEST=//p' "$KERNEL_MANIFEST")
INITRD_MANIFEST_MAGIC=$(sed -n 's/^G1OS_INITRD_MANIFEST=//p' "$INITRD_MANIFEST")
[ "$KERNEL_MANIFEST_MAGIC" = "1" ] || { echo "ERROR: invalid G1OS kernel manifest" >&2; exit 3; }
[ "$INITRD_MANIFEST_MAGIC" = "1" ] || { echo "ERROR: invalid G1OS initramfs manifest" >&2; exit 3; }
EXPECTED_KERNEL_SHA=$(sed -n 's/^artifact_sha256=//p' "$KERNEL_MANIFEST")
EXPECTED_KERNEL_SIZE=$(sed -n 's/^artifact_size=//p' "$KERNEL_MANIFEST")
EXPECTED_KERNEL_ARCH=$(sed -n 's/^artifact_arch=//p' "$KERNEL_MANIFEST")
EXPECTED_KERNEL_FORMAT=$(sed -n 's/^artifact_format=//p' "$KERNEL_MANIFEST")
EXPECTED_INITRD_SHA=$(sed -n 's/^artifact_sha256=//p' "$INITRD_MANIFEST")
EXPECTED_INITRD_SIZE=$(sed -n 's/^artifact_size=//p' "$INITRD_MANIFEST")
[ "$EXPECTED_KERNEL_ARCH" = "x86_64" ] || { echo "ERROR: kernel manifest architecture is not x86_64" >&2; exit 3; }
[ "$EXPECTED_KERNEL_FORMAT" = "x86_64-bzImage" ] || { echo "ERROR: kernel manifest format is not x86_64-bzImage" >&2; exit 3; }
[ "$(wc -c < "$KERNEL" | tr -d ' ')" = "$EXPECTED_KERNEL_SIZE" ] || { echo "ERROR: kernel artifact size differs from authoritative manifest" >&2; exit 3; }
[ "$(sha256sum "$KERNEL" | cut -d' ' -f1)" = "$EXPECTED_KERNEL_SHA" ] || { echo "ERROR: kernel artifact checksum differs from authoritative manifest" >&2; exit 3; }
[ "$(wc -c < "$INITRD" | tr -d ' ')" = "$EXPECTED_INITRD_SIZE" ] || { echo "ERROR: initramfs artifact size differs from authoritative manifest" >&2; exit 3; }
[ "$(sha256sum "$INITRD" | cut -d' ' -f1)" = "$EXPECTED_INITRD_SHA" ] || { echo "ERROR: initramfs artifact checksum differs from authoritative manifest" >&2; exit 3; }
[ "$(dd if="$KERNEL" bs=1 skip=514 count=4 2>/dev/null | grep -aFc 'HdrS' || true)" -eq 1 ] || { echo "ERROR: authoritative kernel is not a valid x86 bzImage" >&2; exit 3; }

# Required runtime binaries MUST come from the current build output. Never
# silently replace a fresh binary with a tracked/rootfs copy later in staging.
REQUIRED_BINS="mica-comp mica-shell mica-finder mica-terminal mica-viewer mica-settings mica-sysinfo mica-textedit mica-player mica-music mica-pdf maclite-browser maclite-video mica-installer"
ST=out/iso-stage
BASE_ST=out/base-stage
rm -rf "$ST" "$BASE_ST"
mkdir -p "$ST/boot" "$ST/live" "$BASE_ST/usr/bin" "$BASE_ST/usr/share/maca-lite/scripts" "$BASE_ST/usr/share/maca-lite/catalog"
for b in $REQUIRED_BINS; do
  src="out/$b"
  [ -x "$src" ] || { echo "ERROR: current build output missing required binary: $src" >&2; exit 4; }
  cp "$src" "$BASE_ST/usr/bin/"
done

# Static installer helpers/resources are sourced from version-controlled files.
cp installer/maclite-install "$BASE_ST/usr/bin/"
cp installer/maclite-installer-backend "$BASE_ST/usr/bin/"
chmod +x "$BASE_ST/usr/bin/maclite-install" "$BASE_ST/usr/bin/maclite-installer-backend"
cp scripts/hardware-check.sh "$BASE_ST/usr/share/maca-lite/scripts/"
chmod +x "$BASE_ST/usr/share/maca-lite/scripts/hardware-check.sh"
[ -f drivers/catalog/maclite-offline.cat ] && cp drivers/catalog/maclite-offline.cat "$BASE_ST/usr/share/maca-lite/catalog/"

# Copy static rootfs configuration/data first. Binary paths are restored from
# the current out/ build afterwards so rootfs cannot overwrite fresh binaries.
[ -d rootfs/etc ] && cp -rf rootfs/etc "$BASE_ST/"
[ -d rootfs/usr/share ] && cp -rf rootfs/usr/share "$BASE_ST/usr/"
# The live SquashFS must use the exact runtime libraries from the initrd
# produced in this build. Never depend on a stale /tmp extraction from an older
# build, another machine, or another kernel/userspace combination.
INITRD_RUNTIME=$(mktemp -d)
cleanup_initrd_runtime() { chmod -R u+rwx "$INITRD_RUNTIME" 2>/dev/null || true; rm -rf "$INITRD_RUNTIME" 2>/dev/null || true; }
trap cleanup_initrd_runtime EXIT HUP INT TERM
if [ ! -f "$INITRD" ] || [ ! -s "$INITRD" ]; then
  echo "ERROR: exact initramfs artifact disappeared before live-base assembly: $INITRD" >&2
  ls -la out/initrd-maclite* 2>/dev/null || true
  exit 4
fi
# Feed the exact artifact through stdin so gzip cannot perform filename
# fallback (for example, appending .gz to a missing path). This makes the
# assembly contract deterministic and fails closed if the artifact changes.
if ! (cd "$INITRD_RUNTIME" && gzip -cd < "$INITRD" | cpio -idm --no-absolute-filenames >/dev/null 2>&1); then
  echo "ERROR: cannot extract the exact initrd runtime while assembling the live base" >&2
  file "$INITRD" >&2 || true
  exit 4
fi
for libdir in lib lib64 usr/lib usr/lib64; do
  if [ -d "$INITRD_RUNTIME/$libdir" ]; then
    mkdir -p "$BASE_ST/$libdir"
    cp -a "$INITRD_RUNTIME/$libdir/." "$BASE_ST/$libdir/"
  fi
done
if [ -s "$INITRD_RUNTIME/bin/busybox" ]; then
  mkdir -p "$BASE_ST/bin" "$BASE_ST/sbin"
  cp -a "$INITRD_RUNTIME/bin/busybox" "$BASE_ST/bin/busybox"
  chmod +x "$BASE_ST/bin/busybox"
  for applet in sh bash cat ls cp mv rm mount umount mkdir grep sed awk sleep; do
    ln -sf /bin/busybox "$BASE_ST/bin/$applet"
  done
fi
cleanup_initrd_runtime
trap - EXIT HUP INT TERM


# Re-apply the current build outputs after rootfs/usr was copied.
for b in $REQUIRED_BINS; do
  cp "out/$b" "$BASE_ST/usr/bin/$b"
done

# Build a deterministic manifest of the exact input files without relying on
# unquoted word splitting. This is both ShellCheck-clean and robust to paths
# containing whitespace in future build environments.
BUILD_INPUT_LIST=$(mktemp)
cleanup_build_input_list() { rm -f "$BUILD_INPUT_LIST"; }
trap cleanup_build_input_list EXIT
printf '%s\n' "$KERNEL" "$INITRD" > "$BUILD_INPUT_LIST"
for b in $REQUIRED_BINS; do
  printf '%s\n' "out/$b" >> "$BUILD_INPUT_LIST"
done
BUILD_INPUT_HASH="$(while IFS= read -r input; do sha256sum "$input"; done < "$BUILD_INPUT_LIST" | sha256sum | cut -d' ' -f1 | cut -c1-16)"
BUILD_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$BUILD_INPUT_HASH"
KERNEL_BASENAME=$(basename "$KERNEL")
INITRD_BASENAME=$(basename "$INITRD")
KERNEL_SHA256=$(sha256sum "$KERNEL" | cut -d' ' -f1)
INITRD_SHA256=$(sha256sum "$INITRD" | cut -d' ' -f1)
KERNEL_SIZE=$(wc -c < "$KERNEL" | tr -d ' ')
INITRD_SIZE=$(wc -c < "$INITRD" | tr -d ' ')
KERNEL_VERSION=$(cat out/kernel-version.txt 2>/dev/null || true)
[ -n "$KERNEL_VERSION" ] || { echo "ERROR: kernel version metadata missing: out/kernel-version.txt" >&2; exit 4; }
printf '%s\n' "$BUILD_ID" > "$ST/.g1os-build-id"
cat > "$ST/boot/g1os-boot-manifest.txt" <<EOF
G1OS_BOOT_MANIFEST=1
build_id=$BUILD_ID
kernel_filename=$KERNEL_BASENAME
kernel_install_filename=vmlinuz-g1os
kernel_manifest_filename=g1os-kernel-manifest.txt
kernel_sha256=$KERNEL_SHA256
kernel_size=$KERNEL_SIZE
kernel_arch=x86_64
kernel_version=$KERNEL_VERSION
initrd_filename=$INITRD_BASENAME
initrd_install_filename=initrd-g1os.img
initrd_manifest_filename=g1os-initrd-manifest.txt
initrd_sha256=$INITRD_SHA256
initrd_size=$INITRD_SIZE
EOF

# Record the exact binaries used to assemble this image. This makes stale ISO
# provenance detectable from the extracted filesystem rather than by filename.
{
  echo "G1OS runtime binary provenance"
  for b in $REQUIRED_BINS; do
    printf '%s  %s\n' "$(sha256sum "out/$b" | cut -d' ' -f1)" "$b"
  done
} > "$BASE_ST/usr/share/maca-lite/runtime-provenance.sha256"

mksquashfs "$BASE_ST" "$ST/live/maclite-base.sqfs" -comp zstd -Xcompression-level 12 -no-progress
rm -rf "$BASE_ST"
[ ! -e "$BASE_ST" ] || { echo "ERROR: rootfs staging leaked into ISO build tree" >&2; exit 6; }
cp "$KERNEL" "$ST/boot/vmlinuz-maclite"
cp "$INITRD" "$ST/boot/initrd-maclite.img"
cp "$KERNEL_MANIFEST" "$ST/boot/g1os-kernel-manifest.txt"
cp "$INITRD_MANIFEST" "$ST/boot/g1os-initrd-manifest.txt"

cp boot/grub-efi.cfg "$ST/boot/grub.cfg"
mkdir -p "$ST/EFI/BOOT" "$ST/boot/grub"
if command -v grub-mkimage >/dev/null 2>&1; then
  grub-mkimage -O x86_64-efi -o "$ST/boot/bootx64.efi" -p /boot part_gpt part_msdos fat iso9660 linux search normal
else
  found_loader=0
  for cand in "boot/bootx64.efi" "out/bootx64.efi" "/Volumes/G1OS/EFI/BOOT/BOOTX64.EFI" "../releases/bootx64.efi"; do
    if [ -s "$cand" ]; then cp "$cand" "$ST/boot/bootx64.efi"; found_loader=1; break; fi
  done
  [ "$found_loader" = 1 ] || { echo "ERROR: no usable EFI loader found" >&2; exit 5; }
fi
[ -s "$ST/boot/bootx64.efi" ] || { echo "ERROR: bootx64.efi missing or empty" >&2; exit 5; }
cp "$ST/boot/bootx64.efi" "$ST/EFI/BOOT/BOOTX64.EFI"
cp "$ST/boot/bootx64.efi" "$ST/EFI/BOOT/bootx64.efi"
cp "$ST/boot/grub.cfg" "$ST/EFI/BOOT/grub.cfg"
cp "$ST/boot/grub.cfg" "$ST/boot/grub/grub.cfg"

need mmd
need mcopy
need mkfs.vfat
EFI_CATALOG="boot/efi.img"
EFI_IMG="$ST/$EFI_CATALOG"
dd if=/dev/zero of="$EFI_IMG" bs=1k count=4096 status=none 2>/dev/null || dd if=/dev/zero of="$EFI_IMG" bs=1k count=4096
mkfs.vfat -F 12 -n "ESP" "$EFI_IMG" >/dev/null 2>&1
mmd -i "$EFI_IMG" ::EFI ::EFI/BOOT
mcopy -o -i "$EFI_IMG" "$ST/boot/bootx64.efi" ::EFI/BOOT/BOOTX64.EFI
mcopy -o -i "$EFI_IMG" "$ST/boot/grub.cfg" ::EFI/BOOT/grub.cfg

xorriso -as mkisofs -r -V "G1OS" -J -joliet-long -e "$EFI_CATALOG" -no-emul-boot -isohybrid-gpt-basdat -o out/G1OS.iso "$ST"
[ -s out/G1OS.iso ] || { echo "ERROR: ISO missing or empty" >&2; exit 6; }
sha256sum out/G1OS.iso > out/G1OS.iso.sha256
{
  echo "G1OS ISO Build Manifest"
  echo "Build ID: $BUILD_ID"
  echo "Build Date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "Kernel: $(basename "$KERNEL")"
  echo "Initramfs: $(basename "$INITRD")"
  echo "Base: live/maclite-base.sqfs"
  echo "ISO: out/G1OS.iso"
  echo "SHA256: $(cat out/G1OS.iso.sha256)"
} > out/iso-manifest.txt

[ -s "$ST/boot/vmlinuz-maclite" ] || { echo "ERROR: staged kernel missing" >&2; exit 7; }
[ -s "$ST/boot/initrd-maclite.img" ] || { echo "ERROR: staged initramfs missing" >&2; exit 7; }
[ -s "$ST/live/maclite-base.sqfs" ] || { echo "ERROR: staged live base missing" >&2; exit 7; }
[ -s "$ST/boot/bootx64.efi" ] || { echo "ERROR: staged EFI loader missing" >&2; exit 7; }
[ -s "$ST/boot/grub.cfg" ] || { echo "ERROR: staged GRUB configuration missing" >&2; exit 7; }

if [ "$VERIFY" = 1 ]; then
  echo "== independent ISO verification"
  sha256sum -c out/G1OS.iso.sha256 >/dev/null || { echo "VERIFY = FAIL: ISO checksum mismatch" >&2; exit 8; }
  xorriso -indev out/G1OS.iso -find / -exec report_lba > out/iso-file-list.txt 2>/dev/null || { echo "VERIFY = FAIL: cannot inspect ISO file list" >&2; exit 9; }
  for required in boot/vmlinuz-maclite boot/initrd-maclite.img boot/g1os-kernel-manifest.txt boot/g1os-initrd-manifest.txt boot/g1os-boot-manifest.txt boot/bootx64.efi boot/grub.cfg live/maclite-base.sqfs EFI/BOOT/BOOTX64.EFI .g1os-build-id; do
    grep -Fi "$required" out/iso-file-list.txt >/dev/null || { echo "VERIFY = FAIL: ISO missing $required" >&2; exit 10; }
  done
  EXTRACT=$(mktemp -d)
  clean_extract() { chmod -R u+rwx "$EXTRACT" 2>/dev/null || true; rm -rf "$EXTRACT" 2>/dev/null || true; }
  trap clean_extract EXIT
  xorriso -osirrox on -indev out/G1OS.iso -extract / "$EXTRACT" >/dev/null 2>&1 || { echo "VERIFY = FAIL: ISO cannot be extracted" >&2; exit 11; }
  [ -s "$EXTRACT/boot/vmlinuz-maclite" ] || { echo "VERIFY = FAIL: extracted kernel empty" >&2; exit 12; }
  [ -s "$EXTRACT/boot/initrd-maclite.img" ] || { echo "VERIFY = FAIL: extracted initramfs empty" >&2; exit 12; }
  [ -s "$EXTRACT/boot/g1os-boot-manifest.txt" ] || { echo "VERIFY = FAIL: boot manifest missing" >&2; exit 12; }
  grep -F "G1OS_BOOT_MANIFEST=1" "$EXTRACT/boot/g1os-boot-manifest.txt" >/dev/null || { echo "VERIFY = FAIL: invalid boot manifest" >&2; exit 13; }
  grep -F "build_id=$BUILD_ID" "$EXTRACT/boot/g1os-boot-manifest.txt" >/dev/null || { echo "VERIFY = FAIL: boot manifest build ID mismatch" >&2; exit 13; }
  grep -F "G1OS_KERNEL_MANIFEST=1" "$EXTRACT/boot/g1os-kernel-manifest.txt" >/dev/null || { echo "VERIFY = FAIL: kernel artifact manifest missing" >&2; exit 13; }
  grep -F "G1OS_INITRD_MANIFEST=1" "$EXTRACT/boot/g1os-initrd-manifest.txt" >/dev/null || { echo "VERIFY = FAIL: initramfs artifact manifest missing" >&2; exit 13; }
  grep -F "artifact_sha256=$EXPECTED_KERNEL_SHA" "$EXTRACT/boot/g1os-kernel-manifest.txt" >/dev/null || { echo "VERIFY = FAIL: kernel artifact manifest checksum mismatch" >&2; exit 13; }
  grep -F "artifact_sha256=$EXPECTED_INITRD_SHA" "$EXTRACT/boot/g1os-initrd-manifest.txt" >/dev/null || { echo "VERIFY = FAIL: initramfs artifact manifest checksum mismatch" >&2; exit 13; }
  manifest_kernel_sha=$(sed -n 's/^kernel_sha256=//p' "$EXTRACT/boot/g1os-boot-manifest.txt")
  manifest_initrd_sha=$(sed -n 's/^initrd_sha256=//p' "$EXTRACT/boot/g1os-boot-manifest.txt")
  [ "$manifest_kernel_sha" = "$KERNEL_SHA256" ] || { echo "VERIFY = FAIL: boot manifest kernel checksum mismatch" >&2; exit 13; }
  [ "$manifest_initrd_sha" = "$INITRD_SHA256" ] || { echo "VERIFY = FAIL: boot manifest initrd checksum mismatch" >&2; exit 13; }
  [ "$(sha256sum "$EXTRACT/boot/vmlinuz-maclite" | cut -d' ' -f1)" = "$manifest_kernel_sha" ] || { echo "VERIFY = FAIL: ISO kernel checksum mismatch" >&2; exit 13; }
  [ "$(sha256sum "$EXTRACT/boot/initrd-maclite.img" | cut -d' ' -f1)" = "$manifest_initrd_sha" ] || { echo "VERIFY = FAIL: ISO initramfs checksum mismatch" >&2; exit 13; }
  [ -s "$EXTRACT/boot/bootx64.efi" ] || { echo "VERIFY = FAIL: extracted EFI loader empty" >&2; exit 12; }
  [ -s "$EXTRACT/live/maclite-base.sqfs" ] || { echo "VERIFY = FAIL: extracted base filesystem empty" >&2; exit 12; }
  file "$EXTRACT/boot/vmlinuz-maclite" | grep -Eiq 'Linux kernel|boot executable|PE32' || { echo "VERIFY = FAIL: kernel is not recognized" >&2; exit 13; }
  unsquashfs -s "$EXTRACT/live/maclite-base.sqfs" >/dev/null || { echo "VERIFY = FAIL: base SquashFS is invalid" >&2; exit 14; }
  xorriso -indev out/G1OS.iso -report_el_torito as_mkisofs 2>/dev/null | grep -Eiq 'boot|efi|iso' || { echo "VERIFY = FAIL: EFI El Torito boot record not detected" >&2; exit 15; }
  grep -F "Build ID: $BUILD_ID" out/iso-manifest.txt >/dev/null || { echo "VERIFY = FAIL: build ID missing from manifest" >&2; exit 16; }
  unsquashfs -cat "$EXTRACT/live/maclite-base.sqfs" "usr/share/maca-lite/runtime-provenance.sha256" > "$EXTRACT/runtime-provenance.sha256" 2>/dev/null || { echo "VERIFY = FAIL: runtime provenance missing from SquashFS" >&2; exit 17; }
  for b in $REQUIRED_BINS; do
    expected=$(sha256sum "out/$b" | cut -d' ' -f1)
    grep -F "$expected  $b" "$EXTRACT/runtime-provenance.sha256" >/dev/null || { echo "VERIFY = FAIL: stale/mismatched runtime binary provenance for $b" >&2; exit 18; }
  done
  clean_extract
  trap - EXIT
  echo "VERIFY = PASS: ISO checksum, EFI boot record, kernel, initramfs, SquashFS, runtime provenance and required paths verified"
fi

REL_DIR="../releases"
mkdir -p "$REL_DIR"
rm -f "$REL_DIR"/*.iso "$REL_DIR"/*.img "$REL_DIR"/vmlinuz* "$REL_DIR"/*.sha256 "$REL_DIR"/iso-manifest.txt "$REL_DIR"/iso-file-list.txt
cp out/G1OS.iso "$REL_DIR/"
cp out/G1OS.iso.sha256 "$REL_DIR/"
cp out/iso-manifest.txt "$REL_DIR/"
[ ! -f out/iso-file-list.txt ] || cp out/iso-file-list.txt "$REL_DIR/"
cp "$KERNEL" "$REL_DIR/"
cp "$INITRD" "$REL_DIR/"

echo "SUCCESS: fresh G1OS ISO assembled and stored in releases/: out/G1OS.iso -> releases/G1OS.iso"
echo "BUILD ID: $BUILD_ID"

# In GitHub Actions CI runners, provide a UEFI pflash compatibility wrapper
# in /usr/local/bin so QEMU can boot 4MB OVMF firmware without mutating /usr/bin.
if [ -n "${GITHUB_ACTIONS:-}" ] && command -v qemu-system-x86_64 >/dev/null 2>&1; then
  cat <<'SHIM_EOF' > /tmp/qemu-system-x86_64
#!/usr/bin/env python3
import sys, os, shutil

real_qemu = "/usr/bin/qemu-system-x86_64"
if not os.path.isfile(real_qemu):
    for p in os.environ.get("PATH", "").split(os.pathsep):
        candidate = os.path.join(p, "qemu-system-x86_64")
        if candidate != sys.argv[0] and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            real_qemu = candidate
            break

vars_candidates = [
    "/usr/share/OVMF/OVMF_VARS_4M.fd",
    "/usr/share/OVMF/OVMF_VARS.fd",
    "/usr/share/ovmf/OVMF_VARS.fd"
]
vars_template = next((c for c in vars_candidates if os.path.isfile(c)), None)
vars_dst = "/tmp/ovmf_vars.fd"
if vars_template and not os.path.isfile(vars_dst):
    try:
        shutil.copyfile(vars_template, vars_dst)
    except Exception:
        pass

args = sys.argv[1:]
new_args = []
i = 0
while i < len(args):
    if args[i] == "-bios" and i + 1 < len(args):
        bios_file = args[i + 1]
        if os.path.isfile(vars_dst) and os.path.isfile(bios_file):
            new_args.extend([
                "-drive", f"if=pflash,format=raw,readonly=on,file={bios_file}",
                "-drive", f"if=pflash,format=raw,file={vars_dst}"
            ])
        else:
            new_args.extend(["-bios", bios_file])
        i += 2
    else:
        new_args.append(args[i])
        i += 1

os.execv(real_qemu, [real_qemu] + new_args)
SHIM_EOF
  chmod 0755 /tmp/qemu-system-x86_64
  if [ -w /usr/local/bin ]; then
    cp /tmp/qemu-system-x86_64 /usr/local/bin/qemu-system-x86_64
  elif command -v sudo >/dev/null 2>&1; then
    sudo cp /tmp/qemu-system-x86_64 /usr/local/bin/qemu-system-x86_64
  fi
fi
