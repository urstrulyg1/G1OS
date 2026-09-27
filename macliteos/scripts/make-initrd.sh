#!/bin/sh
# Build a verifiable G1OS initramfs from repository files and explicit build outputs.
set -eu
OUT=${1:?usage: make-initrd.sh out.img}
cd "$(dirname "$0")/.."
BUSYBOX=${G1OS_BUSYBOX:-out/busybox}
MODULES=${G1OS_KERNEL_MODULES:-out/kernel-modules}
W=$(mktemp -d)
trap 'chmod -R u+rwx "$W" 2>/dev/null || true; rm -rf "$W" 2>/dev/null || true' EXIT

mkdir -p "$W/bin" "$W/sbin" "$W/usr/bin" "$W/usr/share/maca-lite" \
  "$W/lib/firmware" "$W/lib/modules" "$W/etc/maca-lite" "$W/etc/modprobe.d" \
  "$W/dev" "$W/proc" "$W/sys" "$W/mnt" "$W/run/live" "$W/run/maclite-base" "$W/tmp"

[ -s "$BUSYBOX" ] || { echo "ERROR: static BusyBox missing: $BUSYBOX" >&2; exit 2; }
[ -d "$MODULES/lib/modules" ] || { echo "ERROR: kernel module staging missing: $MODULES/lib/modules" >&2; exit 3; }
command -v file >/dev/null 2>&1 || { echo "ERROR: file is required to validate ELF runtime dependencies" >&2; exit 3; }

for req in out/mica-comp out/mica-installer out/mica-shell out/g1os-ui-health out/g1os-failure-ui; do
    if [ ! -x "$req" ]; then
        echo "ERROR: required build output missing: $req" >&2
        exit 2
    fi
done

cp "$BUSYBOX" "$W/bin/busybox"
chmod 0755 "$W/bin/busybox"
"$W/bin/busybox" --install -s "$W/bin" 2>/dev/null || true
for applet in mount umount mkdir cat grep sed sh modprobe switch_root chroot \
              losetup dd partprobe blockdev sync awk sleep dmesg ls cp mv rm touch chmod ln \
              mktemp mkfs.ext2 find which head tail wc tr cut \
              sort uniq uname ip ifconfig ping udhcpc wget reboot poweroff halt env expr dirname basename \
              readlink realpath date id ps kill setsid cttyhack sha256sum; do
    ln -sf /bin/busybox "$W/bin/$applet" 2>/dev/null || true
    ln -sf /bin/busybox "$W/sbin/$applet" 2>/dev/null || true
done

# Do not let a missing BusyBox applet become a runtime-only boot failure.
for applet in mount umount mkdir cat grep sed sh modprobe switch_root chroot \
              losetup dd partprobe blockdev sync awk sleep dmesg ls cp mv rm touch chmod ln \
              mktemp mkfs.ext2 find which head tail wc tr cut \
              sort uniq uname ip ifconfig ping udhcpc wget reboot poweroff halt env expr dirname basename \
              readlink realpath date id ps kill setsid cttyhack sha256sum; do
    "$W/bin/busybox" --list 2>/dev/null | grep -qx "$applet" || {
        echo "ERROR: configured BusyBox does not implement required applet: $applet" >&2
        exit 3
    }
    [ -e "$W/bin/$applet" ] || [ -e "$W/sbin/$applet" ] || {
        echo "ERROR: BusyBox applet missing from initramfs build: $applet" >&2
        exit 3
    }
done
if ! "$W/bin/busybox" sha256sum /dev/null >/dev/null 2>&1; then
    echo "ERROR: BusyBox sha256sum applet is required for installer boot-manifest verification" >&2
    exit 3
fi

# The installer feeds util-linux sfdisk syntax to the partitioner. BusyBox's
# fdisk/sfdisk applets are not compatible with that scripted interface.
for partition_tool in blkid fdisk sfdisk; do
    rm -f "$W/bin/$partition_tool" "$W/sbin/$partition_tool" "$W/usr/bin/$partition_tool"
    tool_path=$(command -v "$partition_tool" 2>/dev/null || true)
    if [ -n "$tool_path" ] && [ -x "$tool_path" ]; then
        cp -L "$tool_path" "$W/usr/bin/$partition_tool"
        chmod 0755 "$W/usr/bin/$partition_tool"
    fi
done
[ -x "$W/usr/bin/sfdisk" ] || {
    echo "ERROR: util-linux sfdisk is required to build an installable G1OS initramfs" >&2
    exit 3
}
"$W/usr/bin/sfdisk" --version >/dev/null 2>&1 || {
    echo "ERROR: staged sfdisk is not a runnable util-linux executable" >&2
    exit 3
}
[ -x "$W/usr/bin/blkid" ] || {
    echo "ERROR: util-linux blkid is required for reliable UUID/PARTUUID lookup" >&2
    exit 3
}
"$W/usr/bin/blkid" --version >/dev/null 2>&1 || {
    echo "ERROR: staged blkid is not a runnable util-linux executable" >&2
    exit 3
}

for filesystem_tool in mkfs.vfat mkdosfs mkfs.ext4 mke2fs; do
    rm -f "$W/bin/$filesystem_tool" "$W/sbin/$filesystem_tool" "$W/usr/bin/$filesystem_tool"
    tool_path=$(command -v "$filesystem_tool" 2>/dev/null || true)
    if [ -n "$tool_path" ] && [ -x "$tool_path" ]; then
        cp -L "$tool_path" "$W/usr/bin/$filesystem_tool"
        chmod 0755 "$W/usr/bin/$filesystem_tool"
    fi
done
[ -x "$W/usr/bin/mkfs.vfat" ] || [ -x "$W/usr/bin/mkdosfs" ] || {
    echo "ERROR: dosfstools mkfs.vfat/mkdosfs is required to build an installable G1OS initramfs" >&2
    exit 3
}
[ -x "$W/usr/bin/mkfs.ext4" ] || [ -x "$W/usr/bin/mke2fs" ] || {
    echo "ERROR: e2fsprogs mkfs.ext4/mke2fs is required to build an installable G1OS initramfs" >&2
    exit 3
}
if [ -x "$W/usr/bin/mkfs.ext4" ]; then
    "$W/usr/bin/mkfs.ext4" -V >/dev/null 2>&1 || {
        echo "ERROR: staged mkfs.ext4 is not a runnable e2fsprogs executable" >&2
        exit 3
    }
else
    "$W/usr/bin/mke2fs" -V >/dev/null 2>&1 || {
        echo "ERROR: staged mke2fs is not a runnable e2fsprogs executable" >&2
        exit 3
    }
fi

while read -r pat; do
    case "$pat" in \#*|"") continue ;; esac
    found=0
    for f in $pat; do
        src=""
        base=$(basename "$f")
        case "$f" in
            /usr/bin/mica-comp|/usr/bin/mica-shell|/usr/bin/mica-finder|/usr/bin/mica-terminal|\
            /usr/bin/mica-viewer|/usr/bin/mica-settings|/usr/bin/mica-sysinfo|/usr/bin/mica-textedit|\
            /usr/bin/mica-player|/usr/bin/mica-music|/usr/bin/mica-pdf|/usr/bin/maclite-browser|\
            /usr/bin/maclite-video|/usr/bin/mica-installer|/usr/bin/g1os-ui-health|/usr/bin/g1os-failure-ui|\
            /usr/bin/g1os-splash|/usr/bin/maclite-hardware|/usr/bin/maclite-gpu|/usr/bin/maclite-display|\
            /usr/bin/maclite-brightness|/usr/bin/maclite-audio|/usr/bin/maclite-video-test|/usr/bin/maclite-network|\
            /usr/bin/maclite-usb|/usr/bin/maclite-storage|/usr/bin/maclite-power|/usr/bin/maclite-cpu|\
            /usr/bin/maclite-drivers|/usr/bin/maclite-fan|/usr/bin/maclite-gpu-benchmark)
                if [ -x "out/$base" ]; then src="out/$base"; fi
                ;;
            *)
                for candidate in \
                    "out/$base" \
                    "installer/$base" \
                    "rootfs$f" \
                    "rootfs/${f#/}" \
                    "${f#/}" \
                    "recovery/$base" \
                    "drivers/catalog/$base" \
                    "$f"; do
                    if [ -e "$candidate" ]; then src="$candidate"; break; fi
                done
                ;;
        esac
        [ -n "$src" ] || continue
        found=1
        d="$W/$(dirname "$f")"
        mkdir -p "$d"
        cp -a "$src" "$d/"
        [ -x "$W$f" ] || chmod +x "$W$f" 2>/dev/null || true
    done
    [ "$found" = 1 ] || { echo "ERROR: initrd.list entry has no matching source: $pat" >&2; exit 4; }
done < boot/initrd.list

for opt_applet in mknod mdev partx findfs blockdev sync; do
    if "$W/bin/busybox" --list 2>/dev/null | grep -qx "$opt_applet"; then
        ln -sf /bin/busybox "$W/bin/$opt_applet" 2>/dev/null || true
        ln -sf /bin/busybox "$W/sbin/$opt_applet" 2>/dev/null || true
    fi
done

for extra_tool in findmnt lsblk sfdisk sgdisk parted partprobe mknod partx wipefs findfs blkid blockdev sync; do
    for tool_path in "/usr/sbin/$extra_tool" "/sbin/$extra_tool" "/usr/bin/$extra_tool" "/bin/$extra_tool"; do
        if [ -x "$tool_path" ] && [ ! -e "$W/usr/bin/$extra_tool" ] && [ ! -e "$W/bin/$extra_tool" ] && [ ! -e "$W/sbin/$extra_tool" ]; then
            dest_dir="$W/usr/bin"
            case "$tool_path" in */sbin/*) dest_dir="$W/sbin" ;; esac
            cp -a "$tool_path" "$dest_dir/$extra_tool"
            chmod 0755 "$dest_dir/$extra_tool"
            break
        fi
    done
done

cp -a "$MODULES/lib/modules/." "$W/lib/modules/"
if [ -n "${G1OS_FIRMWARE_DIR:-}" ]; then
    [ -d "$G1OS_FIRMWARE_DIR" ] || { echo "ERROR: G1OS_FIRMWARE_DIR is not a directory" >&2; exit 5; }
    cp -a "$G1OS_FIRMWARE_DIR/." "$W/lib/firmware/"
fi

copy_lib() {
    lib="$1"
    [ -f "$lib" ] || return 0
    dest="$W$lib"
    if [ -f "$dest" ]; then return 0; fi
    mkdir -p "$(dirname "$dest")"
    cp -L "$lib" "$dest"
}

for ld in /lib64/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /usr/lib64/ld-linux-x86-64.so.2; do
    [ -f "$ld" ] && copy_lib "$ld"
done

scan_deps() {
    target="$1"
    [ -f "$target" ] || return 0
    case "$target" in *.ko|*.ko.*|*/lib/modules/*) return 0 ;; esac
    if ! file "$target" | grep -Eiq 'dynamically linked|shared object'; then
        return 0
    fi
    deps_file="$W/.ldd-deps"
    if ! ldd "$target" >"$deps_file" 2>&1; then
        echo "ERROR: cannot inspect ELF dependencies: $target" >&2
        cat "$deps_file" >&2
        return 1
    fi
    if grep -F "not found" "$deps_file" >/dev/null 2>&1; then
        echo "ERROR: unresolved ELF dependency for $target" >&2
        cat "$deps_file" >&2
        return 1
    fi
    sed -n \
      -e 's/.*=> \(\/[^ ]*\).*/\1/p' \
      -e 's/^[[:space:]]*\(\/[^ ]*\) (0x.*/\1/p' "$deps_file" > "$W/.ldd-paths"
    while read -r lib; do
        [ -n "$lib" ] || continue
        [ -f "$lib" ] || { echo "ERROR: ELF dependency path does not exist: $lib (from $target)" >&2; return 1; }
        copy_lib "$lib"
    done < "$W/.ldd-paths"
}

iteration=0
while :; do
    iteration=$((iteration + 1))
    before=$(find "$W/lib" "$W/lib64" "$W/usr/lib" "$W/usr/lib64" -path "*/lib/modules" -prune -o -type f -print 2>/dev/null | wc -l | tr -d ' ')
    for exe in "$W"/usr/bin/* "$W"/sbin/* "$W"/bin/*; do
        [ -f "$exe" ] || continue
        scan_deps "$exe"
    done
    for libdir in "$W/lib" "$W/lib64" "$W/usr/lib" "$W/usr/lib64"; do
        [ -d "$libdir" ] || continue
        find "$libdir" -path "*/lib/modules" -prune -o -type f -print > "$W/.libs-to-scan"
        while read -r lib; do scan_deps "$lib"; done < "$W/.libs-to-scan"
    done
    after=$(find "$W/lib" "$W/lib64" "$W/usr/lib" "$W/usr/lib64" -path "*/lib/modules" -prune -o -type f -print 2>/dev/null | wc -l | tr -d ' ')
    [ "$after" -eq "$before" ] && break
    [ "$iteration" -lt 20 ] || { echo "ERROR: ELF dependency closure did not converge" >&2; exit 7; }
done

cp boot/g1os-init "$W/init"
chmod 0755 "$W/init"

mkdir -p "$(dirname "$OUT")"
( cd "$W" && find . -print | cpio -o -H newc 2>/dev/null | gzip -9 > "$OUT" )
[ -s "$OUT" ] || { echo "ERROR: initramfs output is empty" >&2; exit 6; }
INITRD_SHA256=$(sha256sum "$OUT" | cut -d' ' -f1)
INITRD_SIZE=$(wc -c < "$OUT" | tr -d ' ')
KERNEL_SHA256=""
if [ -s "$PWD/out/g1os-kernel-manifest.txt" ]; then
  KERNEL_SHA256=$(sed -n 's/^artifact_sha256=//p' "$PWD/out/g1os-kernel-manifest.txt")
fi
cat > "$PWD/out/g1os-initrd-manifest.txt" <<EOF
G1OS_INITRD_MANIFEST=1
artifact_path=out/$(basename "$OUT")
artifact_filename=$(basename "$OUT")
artifact_format=gzip-cpio
artifact_sha256=$INITRD_SHA256
artifact_size=$INITRD_SIZE
kernel_sha256=$KERNEL_SHA256
EOF
printf '%s  %s\n' "$INITRD_SHA256" "$OUT" > "${OUT}.sha256"
echo "INITRAMFS STATUS: PASS"
echo "INITRAMFS: $OUT"
echo "INITRAMFS SHA256: $(cut -d' ' -f1 "${OUT}.sha256")"
