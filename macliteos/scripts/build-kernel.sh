#!/bin/sh
# Reproducible upstream Linux kernel build for G1OS x86_64.
# Outputs: out/vmlinuz-maclite and out/kernel-modules/.
set -eu
cd "$(dirname "$0")/.."

KVER=${G1OS_KERNEL_VERSION:-6.12.101}
KURL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KVER}.tar.xz"
KSHA="0d21cd11933f49f7151b7c9dbb8cc3fddc8c8abe506434b850feecf41fc28a76"
OUT="$PWD/out"
SRC="$OUT/kernel-src"
TARBALL="$OUT/linux-${KVER}.tar.xz"
JOBS=${G1OS_JOBS:-$(nproc 2>/dev/null || echo 2)}

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required kernel-build tool missing: $1" >&2; exit 2; }; }
for tool in curl sha256sum tar xz make gcc bison flex bc perl dd grep cut wc tr; do need "$tool"; done

mkdir -p "$OUT"
if [ ! -s "$TARBALL" ]; then
  echo "== downloading Linux ${KVER}"
  curl -fL --retry 3 --retry-delay 2 -o "$TARBALL" "$KURL"
fi
printf '%s  %s\n' "$KSHA" "$TARBALL" | sha256sum -c -

rm -rf "$SRC" "$OUT/kernel-build" "$OUT/kernel-modules"
mkdir -p "$SRC"
tar -xJf "$TARBALL" -C "$SRC" --strip-components=1

make -C "$SRC" O="$OUT/kernel-build" x86_64_defconfig
"$SRC/scripts/kconfig/merge_config.sh" -O "$OUT/kernel-build" -m "$OUT/kernel-build/.config" "$PWD/kernel/g1os-x86_64.fragment"
make -C "$SRC" O="$OUT/kernel-build" olddefconfig

for setting in \
  CONFIG_BLK_DEV_INITRD=y CONFIG_DEVTMPFS=y CONFIG_DEVTMPFS_MOUNT=y \
  CONFIG_EFI=y CONFIG_EFI_STUB=y CONFIG_EFI_PARTITION=y \
  CONFIG_FB_EFI=y CONFIG_FRAMEBUFFER_CONSOLE=y CONFIG_DRM=y \
  CONFIG_ISO9660_FS=y CONFIG_SQUASHFS=y CONFIG_EXT4_FS=y \
  CONFIG_SQUASHFS_ZSTD=y CONFIG_BLK_DEV_LOOP=y \
  CONFIG_SATA_AHCI=y CONFIG_USB_STORAGE=y CONFIG_FB_EFI=y; do
  grep -qx "$setting" "$OUT/kernel-build/.config" || { echo "ERROR: kernel configuration missing $setting" >&2; exit 3; }
done

# Kconfig may promote a module to built-in when dependency resolution requires
# it. For iMac hardware, y and m are both valid; only n is unacceptable.
for driver in CONFIG_DRM_RADEON CONFIG_HID_APPLE CONFIG_TIGON3 CONFIG_B43 CONFIG_SND_HDA_INTEL; do
  grep -Eq "^$driver=(y|m)$" "$OUT/kernel-build/.config" || {
    echo "ERROR: required iMac hardware driver is disabled: $driver" >&2
    exit 3
  }
done

make -C "$SRC" O="$OUT/kernel-build" -j"$JOBS" bzImage modules
make -C "$SRC" O="$OUT/kernel-build" modules_install INSTALL_MOD_PATH="$OUT/kernel-modules"

KERNEL_ARTIFACT="$OUT/vmlinuz-maclite"
cp "$OUT/kernel-build/arch/x86/boot/bzImage" "$KERNEL_ARTIFACT"
[ -s "$KERNEL_ARTIFACT" ] || { echo "ERROR: kernel artifact missing or empty" >&2; exit 4; }
[ -d "$OUT/kernel-modules/lib/modules" ] || { echo "ERROR: kernel modules staging missing" >&2; exit 4; }

printf '%s\n' "$KVER" > "$OUT/kernel-version.txt"
printf '%s  %s\n' "$KSHA" "linux-${KVER}.tar.xz" > "$OUT/kernel-source.sha256"
KERNEL_SHA256=$(sha256sum "$KERNEL_ARTIFACT" | cut -d' ' -f1)
KERNEL_SIZE=$(wc -c < "$KERNEL_ARTIFACT" | tr -d ' ')
CONFIG_SHA256=$(sha256sum "$OUT/kernel-build/.config" | cut -d' ' -f1)
[ "$(dd if="$KERNEL_ARTIFACT" bs=1 skip=514 count=4 2>/dev/null | grep -aFc 'HdrS' || true)" -eq 1 ] || {
  echo "ERROR: generated kernel is not a valid x86 bzImage (missing HdrS)" >&2
  exit 5
}
grep -qx 'CONFIG_EFI_STUB=y' "$OUT/kernel-build/.config" || { echo "ERROR: final kernel config does not enable EFI_STUB" >&2; exit 5; }
cat > "$OUT/g1os-kernel-manifest.txt" <<EOF
G1OS_KERNEL_MANIFEST=1
artifact_path=out/vmlinuz-maclite
artifact_filename=vmlinuz-maclite
artifact_format=x86_64-bzImage
artifact_arch=x86_64
artifact_sha256=$KERNEL_SHA256
artifact_size=$KERNEL_SIZE
kernel_version=$KVER
source_sha256=$KSHA
config_sha256=$CONFIG_SHA256
efi_stub=CONFIG_EFI_STUB=y
EOF
printf '%s  %s\n' "$KERNEL_SHA256" "$KERNEL_ARTIFACT" > "$OUT/g1os-kernel.sha256"
echo "KERNEL CONFIG: EFI_STUB=Y FB_EFI=Y DRM_RADEON=M USB_STORAGE=Y APPLE_HID=M TG3=M B43=M HDA=M SQUASHFS_ZSTD=Y LOOP=Y"
echo "KERNEL STATUS: PASS"
echo "KERNEL ARTIFACT: $KERNEL_ARTIFACT"
echo "KERNEL SHA256: $KERNEL_SHA256"
echo "KERNEL SIZE: $KERNEL_SIZE"
echo "KERNEL MANIFEST: $OUT/g1os-kernel-manifest.txt"
echo "MODULES: $OUT/kernel-modules/lib/modules"
