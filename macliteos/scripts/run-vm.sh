#!/bin/sh
# Run MacLiteOS in QEMU (spec §54). NOTE: the development sandbox has no
# /dev/kvm and no qemu binary, so this script is WRITTEN BUT UNTESTED there;
# on a machine with qemu it boots the ISO with virtio-gl off (software path).
set -e
cd "$(dirname "$0")/.."
ISO=${1:-out/G1OS.iso}
[ -f "$ISO" ] || { echo "no ISO at $ISO — run scripts/build.sh or scripts/make-iso.sh first"; exit 1; }
MEM=${MEM:-1024}          # prove the 150-300 MB idle budget with room to spare
command -v qemu-system-x86_64 >/dev/null || { echo "qemu-system-x86_64 not installed"; exit 1; }

echo "===================================================================="
echo "MacLiteOS QEMU Virtual Machine Boot Test"
echo "Environment:        QEMU"
echo "Real iMac hardware: NO"
echo ""
echo "VALIDATED BY THIS TEST (if successful):"
echo "  * ISO boot & El-Torito / EFI bootloader"
echo "  * Kernel decompression & boot"
echo "  * Initramfs mounting & userspace handover"
echo "  * Compositor & shell startup (software rasterizer path)"
echo "  * Filesystem layout integrity"
echo ""
echo "NOT TESTED BY THIS TEST (remains NOT TESTED until run on physical iMac):"
echo "  * Radeon HD 4670/5670 GPU acceleration"
echo "  * Radeon KMS scanout & native panel timings"
echo "  * Display brightness PWM control (radeon_bl0)"
echo "  * ALC889 audio playback & microphone capture"
echo "  * Broadcom AirPort Wi-Fi & tg3 Gigabit Ethernet"
echo "  * Apple Bluetooth, FireWire, SDXC reader, iSight camera"
echo "  * UVD2 hardware video decode (H.264 / MPEG-2)"
echo "===================================================================="
echo

exec qemu-system-x86_64 \
    -machine q35 -cpu host -smp 2 -m "$MEM" \
    -cdrom "$ISO" -boot d \
    -device virtio-gpu-pci -display gtk,gl=off \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -serial mon:stdio
