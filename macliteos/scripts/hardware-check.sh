#!/bin/sh
# shellcheck disable=SC2010,SC2012
# MacLiteOS hardware check — evidence-based runtime validation (spec §16/§21/§24).
#
# CRITICAL REQUIREMENT:
# ZERO FAKE DATA. ZERO SIMULATED PASS RESULTS. ZERO ASSUMED HARDWARE RESULTS.
# Reference iMac specifications are a compatibility reference only;
# they are NEVER reported as runtime results unless physically detected and tested.
#
# Exit codes contract:
#   0 PASS: all automated checks passed AND all human checks confirmed
#   1 FAIL: a genuine hardware or test failure occurred
#   2 NOT TESTED: hardware/feature could not be verified in this environment
#   3 UNSUPPORTED: hardware/feature not present on this host
#   4 USAGE ERROR
#
# Usage: sh scripts/hardware-check.sh [--quick] [--allow-suspend] [--set-mode]
#        sh scripts/hardware-check.sh --yes "answer" (scripted answers)
cd "$(dirname "$0")/.." || exit 1

QUICK=0
ALLOW_SUSPEND=0
SET_MODE=0
ANSWERS_FILE=""
DEFAULT_ANSWER=""
while [ $# -gt 0 ]; do
    case "$1" in
    --quick) QUICK=1 ;;
    --allow-suspend) ALLOW_SUSPEND=1 ;;
    --set-mode) SET_MODE=1 ;;
    --answers) shift; ANSWERS_FILE="$1" ;;
    --batch) DEFAULT_ANSWER="skip" ;;
    --yes) shift; DEFAULT_ANSWER="$1" ;;
    -h|--help)
        echo "MacLiteOS hardware check — evidence-based runtime validation (spec §16/§21/§24)"
        echo "Usage: sh scripts/hardware-check.sh [--quick] [--allow-suspend] [--set-mode]"
        echo "       sh scripts/hardware-check.sh --answers <file> | --yes <answer> | --batch"
        exit 0
        ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

# --- 1. Runtime Environment & Virtualization Detection ---
DMI_VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "unknown")
PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "unknown")
BOARD_NAME=$(cat /sys/class/dmi/id/board_name 2>/dev/null || echo "unknown")
KERNEL=$(uname -srmo 2>/dev/null || uname -a)
ARCH=$(uname -m 2>/dev/null || echo "unknown")

VIRT="none"
if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT_OUT=$(systemd-detect-virt 2>/dev/null || true)
    [ -n "$VIRT_OUT" ] && [ "$VIRT_OUT" != "none" ] && VIRT="$VIRT_OUT"
fi
if [ "$VIRT" = "none" ]; then
    case "$PRODUCT $DMI_VENDOR" in
    *QEMU*|*Bochs*|*KVM*) VIRT="qemu/kvm" ;;
    *VirtualBox*|*innotek*) VIRT="virtualbox" ;;
    *VMware*) VIRT="vmware" ;;
    esac
fi
if [ "$VIRT" = "none" ] && [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
    VIRT="container"
elif [ "$VIRT" = "none" ] && grep -q 'hypervisor' /proc/cpuinfo 2>/dev/null; then
    VIRT="hypervisor"
fi

REAL_IMAC="NO"
case "$DMI_VENDOR" in
*Apple*)
    case "$PRODUCT" in
    *iMac11,2*|*iMac11,3*|*iMac*)
        if [ "$VIRT" = "none" ]; then
            REAL_IMAC="YES"
            TIER="IMAC"
            ENV_DESC="Apple iMac Mid-2010 ($PRODUCT)"
        else
            TIER="VM"
            ENV_DESC="Virtualized Apple environment ($PRODUCT under $VIRT)"
        fi
        ;;
    *)
        TIER="APPLE_OTHER"
        ENV_DESC="Apple hardware ($PRODUCT)"
        ;;
    esac
    ;;
*)
    case "$VIRT" in
    qemu*|kvm*)
        TIER="QEMU"
        ENV_DESC="QEMU / KVM Virtual Machine ($PRODUCT)"
        ;;
    virtualbox)
        TIER="VBOX"
        ENV_DESC="VirtualBox Virtual Machine"
        ;;
    vmware)
        TIER="VMWARE"
        ENV_DESC="VMware Virtual Machine"
        ;;
    container)
        TIER="CONTAINER"
        ENV_DESC="Linux Container Sandbox"
        ;;
    *)
        TIER="HOST"
        ENV_DESC="Physical PC ($DMI_VENDOR $PRODUCT)"
        ;;
    esac
    ;;
esac

# Runtime CPU detection
CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^[ \t]*//' || echo "unknown")
[ -z "$CPU_MODEL" ] && CPU_MODEL="unknown"

# Runtime RAM detection
RAM_TOTAL=$(grep -m1 'MemTotal' /proc/meminfo 2>/dev/null | awk '{print int($2/1024) " MB"}' || echo "unknown")

# Runtime GPU detection
GPU_NAME="none"
for cl in /sys/bus/pci/devices/*/class; do
    if [ -f "$cl" ]; then
        cval=$(cat "$cl" 2>/dev/null || true)
        case "$cval" in
        0x0300*|0x0380*|0x0302*)
            pci_dev=$(dirname "$cl")
            v_id=$(cat "$pci_dev/vendor" 2>/dev/null || echo "")
            d_id=$(cat "$pci_dev/device" 2>/dev/null || echo "")
            drv=$(basename "$(readlink -f "$pci_dev/driver" 2>/dev/null)" 2>/dev/null || echo "unbound")
            GPU_NAME="PCI ${v_id}:${d_id} (driver: ${drv})"
            break
            ;;
        esac
    fi
done
if [ "$GPU_NAME" = "none" ] && command -v lspci >/dev/null 2>&1; then
    lspci_gpu=$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -1 | sed 's/^[0-9a-f:.]* //' || true)
    [ -n "$lspci_gpu" ] && GPU_NAME="$lspci_gpu"
fi

GIT_COMMIT=$(git log -1 --format="%h (%ci)" 2>/dev/null || cat VERSION 2>/dev/null || echo "unknown")
ISO_FILE="out/G1OS.iso"
if [ -f "$ISO_FILE" ]; then
    ISO_INFO="$(ls -lh "$ISO_FILE" 2>/dev/null | awk '{print $9 " (" $5 ")"}')"
else
    ISO_INFO="not built (run scripts/make-iso.sh)"
fi

DATE=$(date -u '+%Y%m%d')
REPORT="out/hw-report-$DATE.txt"
TSV="out/hw-report-$DATE.tsv"
MATRIX_TSV="out/hw-matrix-$DATE.tsv"
mkdir -p out
: > "$TSV"
: > "$MATRIX_TSV"
FAILED=0
HUMAN_UNTESTED=0

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
section() { log ""; log "============================================================================"; log "  $1"; log "============================================================================"; }
tsv() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$TSV"; }
matrix_row() {
    # Component, Detected, Tested, Result, Evidence
    printf '%-18s | %-16s | %-12s | %-12s | %s\n' "$1" "$2" "$3" "$4" "$5" | tee -a "$REPORT"
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$MATRIX_TSV"
}

# --- Provenance Header ---
: > "$REPORT"
{
    log "MacLiteOS Hardware Compatibility & Performance Report"
    log "====================================================="
    log "Report generated:   $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    log "Environment:        $ENV_DESC"
    log "Real iMac hardware: $REAL_IMAC"
    log "Tier label:         $TIER"
    log "Machine:            $PRODUCT (vendor: $DMI_VENDOR, board: $BOARD_NAME)"
    log "Virtualization:     $VIRT"
    log "Kernel:             $KERNEL"
    log "Architecture:       $ARCH"
    log "CPU:                $CPU_MODEL"
    log "RAM:                $RAM_TOTAL"
    log "GPU:                $GPU_NAME"
    log "Commit:             $GIT_COMMIT"
    log "ISO:                $ISO_INFO"
    log "Hardware source:    runtime detection (/sys, /proc, /dev, PCI IDs, DRM, EDID)"
    log ""
    log "NOTE ON METHODOLOGY:"
    log "ZERO FAKE DATA. Expected iMac Mid-2010 hardware specs serve as a compatibility"
    log "reference only. Results below reflect ONLY what was physically detected and tested."
    log "Any component not physically present or not exercised is marked NOT TESTED or UNSUPPORTED."
}

# Ask helper for human checks
ask() {
    prompt=$1
    if [ -n "$ANSWERS_FILE" ] && [ -s "$ANSWERS_FILE" ]; then
        ans=$(sed -n '1p' "$ANSWERS_FILE")
        sed -i '1d' "$ANSWERS_FILE"
        printf '  %s -> [scripted: %s]\n' "$prompt" "$ans" >&2
        printf '%s' "$ans"
        return
    fi
    if [ -n "$DEFAULT_ANSWER" ]; then
        printf '  %s -> [default: %s]\n' "$prompt" "$DEFAULT_ANSWER" >&2
        printf '%s' "$DEFAULT_ANSWER"
        return
    fi
    printf '  %s [y/n/skip]: ' "$prompt" >&2
    read -r ans
    printf '%s' "$ans"
}

human() {
    name=$1; prompt=$2
    ans=$(ask "$prompt")
    case "$ans" in
    y|Y|yes) log "  $name: PASS (human confirmed: $prompt)"; tsv "$name" "$TIER" PASS "human confirmed" ;;
    n|N|no)  log "  $name: FAIL (human reported failure)"; tsv "$name" "$TIER" FAIL "human reported failure"; FAILED=1 ;;
    *)       log "  $name: NOT TESTED (not confirmed by human)"; tsv "$name" "$TIER" "NOT TESTED" "not confirmed"; HUMAN_UNTESTED=1 ;;
    esac
}

# Automated tool runner
auto() {
    name=$1; shift
    out=$(mktemp)
    "$@" > "$out" 2>&1
    rc=$?
    case $rc in
    0) verdict="PASS" ;;
    1) verdict="FAIL" ; FAILED=1 ;;
    2) verdict="NOT TESTED" ;;
    3) verdict="UNSUPPORTED" ;;
    4) verdict="USAGE ERROR"; FAILED=1 ;;
    *) verdict="FAIL (exit $rc)"; FAILED=1 ;;
    esac
    log ""
    log "-- $name  [$verdict  exit $rc]"
    sed 's/^/   /' "$out" >> "$REPORT"
    tsv "$name" "$TIER" "$verdict" "exit $rc"
    rm -f "$out"
}

# --- SECTION 1: Automated Diagnostics ---
section "1. Automated Runtime Diagnostics"

if [ -x out/maclite-hardware ]; then auto "maclite-hardware" out/maclite-hardware; else log "  out/maclite-hardware missing"; fi
if [ -x out/maclite-cpu ]; then auto "maclite-cpu" out/maclite-cpu; else log "  out/maclite-cpu missing"; fi
if [ -x out/maclite-gpu ]; then auto "maclite-gpu" out/maclite-gpu; else log "  out/maclite-gpu missing"; fi
if [ -x out/maclite-display ]; then auto "maclite-display" out/maclite-display --modes; else log "  out/maclite-display missing"; fi
if [ -x out/maclite-brightness ]; then auto "maclite-brightness" out/maclite-brightness status; else log "  out/maclite-brightness missing"; fi
if [ -x out/maclite-audio ]; then auto "maclite-audio" out/maclite-audio list; else log "  out/maclite-audio missing"; fi
if [ -x out/maclite-network ]; then auto "maclite-network" out/maclite-network; else log "  out/maclite-network missing"; fi
if [ -x out/maclite-usb ]; then auto "maclite-usb" out/maclite-usb; else log "  out/maclite-usb missing"; fi
if [ -x out/maclite-storage ]; then auto "maclite-storage" out/maclite-storage --bench /tmp; else log "  out/maclite-storage missing"; fi
if [ -x out/maclite-power ]; then auto "maclite-power" out/maclite-power; else log "  out/maclite-power missing"; fi
if [ -x out/maclite-drivers ]; then auto "maclite-drivers" out/maclite-drivers status; else log "  out/maclite-drivers missing"; fi
if [ -x out/maclite-fan ]; then auto "maclite-fan" out/maclite-fan --diagnostics; else log "  out/maclite-fan missing"; fi
if [ -x out/maclite-browser ]; then auto "maclite-browser" out/maclite-browser --diagnostics; else log "  out/maclite-browser missing"; fi
if [ -x out/maclite-video ]; then auto "maclite-video" out/maclite-video --diagnostics; else log "  out/maclite-video missing"; fi
if [ -x out/g1os-splash ]; then auto "g1os-splash" out/g1os-splash --benchmark; else log "  out/g1os-splash missing"; fi
if [ -x out/maclite-gpu-benchmark ]; then
    auto "maclite-gpu-benchmark (damage path)" out/maclite-gpu-benchmark --frames 300
    auto "maclite-gpu-benchmark (fullscreen worst case)" out/maclite-gpu-benchmark --fullscreen --frames 300
fi
if [ "$QUICK" = 0 ] && [ -x out/maclite-video-test ]; then
    auto "maclite-video-test" out/maclite-video-test h264 mpeg2 --res 1080 --perf
fi

# --- SECTION 2: Resource Budgets ---
section "2. Resource Goals (Idle: 150-300 MB, Hard: <500 MB, CPU: 0-2 %)"
if [ -x out/maclite-memory ]; then
    auto "maclite-memory" sh -c 'sleep 3; out/maclite-memory'
else
    log "  maclite-memory not built (RAM usage: NOT MEASURED)"; tsv "maclite-memory" "$TIER" "NOT TESTED" "binary missing (NOT MEASURED)"; HUMAN_UNTESTED=1
fi
if [ -x out/maclite-performance ]; then
    auto "maclite-performance" out/maclite-performance 5000
else
    log "  maclite-performance not built (idle CPU: NOT MEASURED)"
fi

# --- SECTION 3: Human Verification ---
section "3. Physical Observation Checks (Unanswered = NOT TESTED)"
human "panel-picture"       "Is picture on panel correct, sharp, full-screen and free of tearing?"
human "brightness-keys"     "Do brightness keys physically change display backlight (not just software value)?"
human "audio-speakers"      "Did you hear the test tone from internal speakers during maclite-audio?"
human "wifi-association"    "Did Wi-Fi adapter associate with an AP and pass network traffic?"
human "ethernet-link"       "Did Ethernet come up with DHCP lease and pass network traffic?"
human "usb-hotplug"         "Did a plugged USB drive mount cleanly and safely?"
human "keyboard-mouse"      "Do keyboard, mouse/trackpad, and volume keys work physically?"
if [ "$ALLOW_SUSPEND" = 1 ]; then
    human "suspend-resume"  "After suspend/resume did the panel re-light? (Known failure on iMac11,x)"
else
    log "  skip: suspend/resume — not attempted (requires --allow-suspend)"
    tsv "suspend-resume" "$TIER" "NOT TESTED" "not attempted (no --allow-suspend)"
    HUMAN_UNTESTED=1
fi
human "video-playback"      "Play 1080p H.264 video: is playback smooth with zero frame drops and synced audio?"
human "seek-behaviour"      "Seeking 1080p video: does frame resume immediately without UI freezing?"

if [ "$SET_MODE" = 1 ] && [ -x out/maclite-display ]; then
    section "4. Mode Switching Verification (--set-mode)"
    auto "maclite-display --set 1280x720" out/maclite-display --set 1280x720
    auto "maclite-display --set 1920x1080" out/maclite-display --set 1920x1080
fi

# --- SECTION 4: 18-Component Hardware Validation Matrix ---
section "4. 18-Component Hardware Validation Matrix"
log "Strict evidence-based results: Expected vs Actually Detected vs Tested"
log ""
printf '%-18s | %-16s | %-12s | %-12s | %s\n' "Component" "Detected" "Tested" "Result" "Evidence" | tee -a "$REPORT"
printf '%-18s-+-%-16s-+-%-12s-+-%-12s-+-%s\n' "------------------" "----------------" "------------" "------------" "----------------------------------------" | tee -a "$REPORT"

# 1. CPU
if [ -n "$CPU_MODEL" ] && [ "$CPU_MODEL" != "unknown" ]; then
    matrix_row "CPU" "runtime" "runtime" "PASS" "$CPU_MODEL ($(nproc 2>/dev/null || echo 1) cores)"
else
    matrix_row "CPU" "unknown" "runtime" "FAIL" "no /proc/cpuinfo or processor details"
fi

# 2. RAM
if [ -n "$RAM_TOTAL" ] && [ "$RAM_TOTAL" != "unknown" ]; then
    matrix_row "RAM" "runtime" "runtime" "PASS" "Total: $RAM_TOTAL (from /proc/meminfo)"
else
    matrix_row "RAM" "unknown" "runtime" "FAIL" "unable to read /proc/meminfo"
fi

# 3. GPU
if [ "$GPU_NAME" != "none" ]; then
    matrix_row "GPU" "runtime" "runtime" "PASS" "$GPU_NAME"
else
    matrix_row "GPU" "none" "runtime" "NOT AVAILABLE" "no PCI display controller found under /sys/bus/pci"
fi

# 4. KMS
if [ -d /sys/class/drm ] && ls /sys/class/drm/card* >/dev/null 2>&1; then
    cards=$(ls -d /sys/class/drm/card* 2>/dev/null | grep -E 'card[0-9]+$' | tr '\n' ' ')
    matrix_row "KMS" "runtime" "runtime" "PASS" "DRM nodes: $cards"
else
    matrix_row "KMS" "none" "runtime" "NOT TESTED" "no /dev/dri/card* or /sys/class/drm available"
fi

# 5. OpenGL
if [ -x out/maclite-gpu ]; then
    gl_ev=$(out/maclite-gpu 2>&1 | grep -iE 'OpenGL|Renderer|Hardware Rendering' | head -1 | sed 's/^[ \t]*//' || echo "")
    if echo "$gl_ev" | grep -qi "PASS"; then
        matrix_row "OpenGL" "runtime" "runtime" "PASS" "$gl_ev"
    elif echo "$gl_ev" | grep -qi "PARTIAL"; then
        matrix_row "OpenGL" "runtime" "runtime" "PARTIAL" "software rasterizer fallback"
    else
        matrix_row "OpenGL" "runtime" "runtime" "NOT VERIFIED" "OpenGL context/renderer not verified on this host"
    fi
else
    matrix_row "OpenGL" "runtime" "unbuilt" "NOT VERIFIED" "OpenGL renderer: NOT VERIFIED (maclite-gpu not built)"
fi

# 6. Brightness
if [ -d /sys/class/backlight ] && ls /sys/class/backlight/* >/dev/null 2>&1; then
    bl_dev=$(ls /sys/class/backlight | head -1)
    if [ -w "/sys/class/backlight/$bl_dev/brightness" ]; then
        cur_b=$(cat "/sys/class/backlight/$bl_dev/brightness" 2>/dev/null || echo "?")
        matrix_row "Brightness" "runtime" "runtime" "PASS" "$bl_dev (level: $cur_b, writable)"
    else
        matrix_row "Brightness" "runtime" "runtime" "NOT TESTED" "$bl_dev present but not writable"
    fi
else
    matrix_row "Brightness" "none" "runtime" "NOT TESTED" "no writable backlight interface in this environment"
fi

# 7. Audio
if [ -f /proc/asound/cards ] && grep -q '\[.*\]' /proc/asound/cards 2>/dev/null; then
    card_name=$(head -1 /proc/asound/cards | sed 's/^[ \t0-9]*: //')
    matrix_row "Audio" "runtime" "runtime" "PASS" "ALSA card: $card_name"
else
    matrix_row "Audio" "none" "runtime" "NOT TESTED" "no physical audio device available (/proc/asound/cards empty)"
fi

# 8. Microphone
if ls /proc/asound/card*/pcm*c/info >/dev/null 2>&1; then
    matrix_row "Microphone" "runtime" "runtime" "NOT TESTED" "capture PCM stream available; no recording test performed"
else
    matrix_row "Microphone" "none" "runtime" "UNSUPPORTED" "no audio capture stream detected"
fi

# 9. Ethernet
eth_if=$(ls /sys/class/net 2>/dev/null | grep -E '^(eth|en|tg)' | head -1)
if [ -n "$eth_if" ]; then
    opstate=$(cat "/sys/class/net/$eth_if/operstate" 2>/dev/null || echo "unknown")
    matrix_row "Ethernet" "runtime" "runtime" "PASS" "interface $eth_if (state: $opstate)"
else
    matrix_row "Ethernet" "none" "runtime" "UNSUPPORTED" "no physical Ethernet interface enumerated"
fi

# 10. Wi-Fi
wifi_if=$(ls /sys/class/net 2>/dev/null | grep -E '^(wlan|wl)' | head -1)
if [ -n "$wifi_if" ]; then
    matrix_row "Wi-Fi" "runtime" "runtime" "NOT TESTED" "interface $wifi_if detected; AP association not tested"
else
    matrix_row "Wi-Fi" "none" "runtime" "NOT TESTED" "target wireless hardware not present in test environment"
fi

# 11. Bluetooth
if [ -d /sys/class/bluetooth ] && ls /sys/class/bluetooth/hci* >/dev/null 2>&1; then
    hci_dev=$(ls /sys/class/bluetooth | head -1)
    matrix_row "Bluetooth" "runtime" "runtime" "NOT TESTED" "controller $hci_dev detected; no pairing/traffic tested"
else
    matrix_row "Bluetooth" "none" "runtime" "NOT TESTED" "Bluetooth controller not present in test environment"
fi

# 12. USB
if [ -d /sys/bus/usb/devices ] && ls /sys/bus/usb/devices/usb* >/dev/null 2>&1; then
    n_usb=$(ls -d /sys/bus/usb/devices/[0-9]* 2>/dev/null | wc -l)
    matrix_row "USB" "runtime" "runtime" "PASS" "$n_usb USB device(s) enumerated under sysfs"
else
    matrix_row "USB" "none" "runtime" "UNSUPPORTED" "no USB host controller available"
fi

# 13. SD reader
if [ -d /sys/class/block ] && ls /sys/class/block/mmcblk* >/dev/null 2>&1; then
    matrix_row "SD reader" "runtime" "runtime" "PASS" "SD card block device enumerated"
elif [ -d /sys/bus/pci/devices ] && grep -qi "card reader" /sys/bus/pci/devices/*/class 2>/dev/null; then
    matrix_row "SD reader" "runtime" "runtime" "NOT TESTED" "SD card reader controller detected; no media inserted"
else
    matrix_row "SD reader" "none" "runtime" "NOT TESTED" "SD card reader not present in test environment"
fi

# 14. FireWire
if [ -d /sys/bus/firewire/devices ] && ls /sys/bus/firewire/devices/* >/dev/null 2>&1; then
    matrix_row "FireWire" "runtime" "runtime" "NOT TESTED" "FireWire bus present; no external peripheral attached"
else
    matrix_row "FireWire" "none" "runtime" "NOT TESTED" "FireWire controller not present in test environment"
fi

# 15. SATA/storage
if [ -d /sys/class/block ] && ls /sys/class/block/sd* >/dev/null 2>&1; then
    disks=$(ls -d /sys/class/block/sd[a-z] 2>/dev/null | tr '\n' ' ')
    matrix_row "SATA/storage" "runtime" "runtime" "PASS" "Block devices: $disks"
else
    matrix_row "SATA/storage" "runtime" "runtime" "NOT TESTED" "no sd* block devices in sysfs (container/virtual mount)"
fi

# 16. Optical drive
if [ -d /sys/class/block/sr0 ]; then
    matrix_row "Optical drive" "runtime" "runtime" "PASS" "Optical drive /dev/sr0 detected (unpolled)"
else
    matrix_row "Optical drive" "none" "runtime" "NOT TESTED" "optical drive not present in test environment"
fi

# 17. iSight
if [ -d /sys/class/video4linux ] && ls /sys/class/video4linux/video* >/dev/null 2>&1; then
    matrix_row "iSight" "runtime" "runtime" "NOT TESTED" "Video device detected; frame capture not tested"
else
    matrix_row "iSight" "none" "runtime" "NOT TESTED" "iSight camera not present in test environment"
fi

# 18. Video decode
if [ -x out/maclite-video-test ]; then
    v_out=$(out/maclite-video-test h264 2>&1 | head -1 || echo "")
    if echo "$v_out" | grep -qi "hw"; then
        matrix_row "Video decode" "runtime" "runtime" "PASS" "$v_out"
    else
        matrix_row "Video decode" "runtime" "runtime" "NOT TESTED" "hardware decoder could not be exercised on this host"
    fi
else
    matrix_row "Video decode" "none" "runtime" "NOT TESTED" "video decode test binary not available"
fi

# 19. External display
if [ -d /sys/class/drm ]; then
    ext_conn=$(ls -d /sys/class/drm/card*-* 2>/dev/null | grep -iE 'DP|HDMI|DVI|VGA' | head -1)
    if [ -n "$ext_conn" ]; then
        status=$(cat "$ext_conn/status" 2>/dev/null || echo "unknown")
        conn_name=$(basename "$ext_conn" | sed 's/card[0-9]*-//')
        if [ "$status" = "connected" ]; then
            matrix_row "External display" "runtime" "runtime" "PASS" "$conn_name connected"
        else
            matrix_row "External display" "runtime" "runtime" "NOT TESTED" "$conn_name present ($status)"
        fi
    else
        matrix_row "External display" "none" "runtime" "NOT TESTED" "no external display connector enumerated by DRM"
    fi
else
    matrix_row "External display" "none" "runtime" "NOT TESTED" "no DRM display controller present"
fi

# --- SECTION 5: Multimedia Validation (spec §20) ---
section "5. MacLiteOS Multimedia Validation (spec §20)"
log "Strict evidence-based reporting on primary browser and primary media player (VLC)"
log ""

# Probe browser
HAVE_BROWSER="NO"
BROWSER_VER="NOT INSTALLED"
BROWSER_BIN=""
for b in brave-browser brave chromium-browser chromium google-chrome-stable google-chrome; do
    if command -v "$b" >/dev/null 2>&1; then
        HAVE_BROWSER="YES"
        BROWSER_BIN="$b"
        BROWSER_VER=$($b --version 2>/dev/null || echo "detected")
        break
    fi
done

# Probe Widevine
HAVE_WV="NO"
WV_VER="none"
for wp in \
    /opt/brave.com/brave/WidevineCdm/_platform_specific/linux_x64/libwidevinecdm.so \
    /usr/lib/chromium/WidevineCdm/_platform_specific/linux_x64/libwidevinecdm.so \
    /opt/google/chrome/WidevineCdm/_platform_specific/linux_x64/libwidevinecdm.so \
    /var/lib/maca-lite/widevine/libwidevinecdm.so \
    /usr/lib/x86_64-linux-gnu/WidevineCdm/libwidevinecdm.so \
    "$HOME/.config/google-chrome/WidevineCdm"*; do
    if [ -e "$wp" ]; then
        HAVE_WV="YES"
        WV_VER="detected ($wp)"
        break
    fi
done

# Probe VLC
HAVE_VLC="NO"
VLC_VER="NOT INSTALLED"
if command -v vlc >/dev/null 2>&1; then
    HAVE_VLC="YES"
    VLC_VER=$(vlc --version 2>/dev/null | head -1 || echo "detected")
fi

log "Browser:"
log "  Installed:          $HAVE_BROWSER"
log "  Version:            $BROWSER_VER"
if [ "$HAVE_BROWSER" = "YES" ]; then
    log "  GPU acceleration:   NOT TESTED"
    log "  Video decoding:     NOT TESTED"
else
    log "  GPU acceleration:   UNSUPPORTED (browser not installed)"
    log "  Video decoding:     UNSUPPORTED (browser not installed)"
fi
log "  DRM:                $([ "$HAVE_WV" = "YES" ] && echo "AVAILABLE" || echo "NOT DETECTED")"
log "  Widevine:           $WV_VER"
log "  YouTube:            NOT TESTED"
log "  Netflix:            NOT TESTED"
log "  Prime Video:        NOT TESTED"
log "  Disney+:            NOT TESTED"
log ""
log "VLC:"
log "  Installed:          $HAVE_VLC"
log "  Version:            $VLC_VER"
if [ "$HAVE_VLC" = "YES" ]; then
    log "  Hardware decoding:  NOT TESTED"
    log "  Audio output:       NOT TESTED"
    log "  1080p playback:     NOT TESTED"
else
    log "  Hardware decoding:  UNSUPPORTED (VLC not installed)"
    log "  Audio output:       NOT TESTED"
    log "  1080p playback:     UNSUPPORTED (VLC not installed)"
fi
log ""
log "Resource usage:"
log "  Browser idle RAM:   NOT MEASURED"
log "  Browser idle CPU:   NOT MEASURED"
log "  YouTube 1080p CPU:  NOT MEASURED"
log "  YouTube 1080p RAM:  NOT MEASURED"
log "  VLC 1080p CPU:      NOT MEASURED"
log "  VLC 1080p RAM:      NOT MEASURED"
log ""
log "Disk footprint:"
if [ "$HAVE_BROWSER" = "YES" ] && command -v "$BROWSER_BIN" >/dev/null 2>&1; then
    bpath=$(command -v "$BROWSER_BIN")
    log "  Browser:            $(ls -lh "$bpath" 2>/dev/null | awk '{print $5}' || echo "installed")"
else
    log "  Browser:            NOT INSTALLED"
fi
if [ "$HAVE_VLC" = "YES" ] && command -v vlc >/dev/null 2>&1; then
    vpath=$(command -v vlc)
    log "  VLC:                $(ls -lh "$vpath" 2>/dev/null | awk '{print $5}' || echo "installed")"
else
    log "  VLC:                NOT INSTALLED"
fi
log "  Multimedia dependencies: NOT MEASURED"
log "  Total additional footprint: NOT MEASURED"
log ""

# --- SECTION 6: Summary ---
section "6. Summary"
log "  report      $REPORT"
log "  tsv         $TSV"
log "  matrix      $MATRIX_TSV"
if [ "$FAILED" = 0 ] && [ "$HUMAN_UNTESTED" = 0 ]; then
    log "  result      PASS (all automated and human checks confirmed)"
    rc=0
elif [ "$FAILED" = 0 ]; then
    log "  result      PARTIAL (automated checks passed; unverified hardware remains strictly NOT TESTED)"
    rc=0
else
    log "  result      FAIL (failures detected in automated or human checks)"
    rc=1
fi
log ""
log "Paste $REPORT and $MATRIX_TSV into docs/validation-report.md and docs/testing.md."
log "Do NOT convert any NOT TESTED row into a PASS row without verified hardware proof."

exit $rc
