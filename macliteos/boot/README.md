# boot/

Boot chain for MacLiteOS on EFI and BIOS machines, including the Apple EFI 1.1
found in iMac11,2 / iMac11,3 (Mid-2010).

Status: **assembled and validated by the G1OS build workflow.**
The EFI image, initramfs, live root, graphical installer, real-disk install and
installed-disk boot are checked with UEFI QEMU; see `docs/testing.md` for the
validation gates.

Files:
- `grub-efi.cfg`   GRUB config for EFI boot (Apple EFI 1.1 accepts EFI-x86_64
                   GRUB; keep the kernel and initrd in the ESP-friendly layout).
- `grub-bios.cfg`  legacy/CSM boot config (some iMacs fall back to CSM).
- `initrd.list`    the exact file list the initramfs must contain. Principle:
                   the initrd carries only what mounts the read-only base and
                   starts `mica-comp --session`; everything else is on-disk.
- `kernel-cmdline.txt` documented cmdline, including the quirks that matter on
                   this hardware (b43 firmware, radeon UVD, tg3).

The boot target is a Linux 6.x LTS kernel configured from `kernel/configs/`,
not a custom kernel: MacLiteOS is a userspace OS (compositor, shell, apps,
tools) plus a curated kernel config and boot chain. That choice is deliberate
(spec §2: small, reliable, fast over feature-rich) and is documented in
docs/architecture.md.

## Runtime Progress and Device Discovery

PID 1 is `g1os-init`; G1OS does not start `udevd` or systemd. Device nodes are
created from devtmpfs and rescanned with BusyBox `mdev`. Do not wait on
`udevadm settle` in the guest. Boot milestones are written to `/dev/kmsg` so
kernel and userspace output remain serialized on the QEMU serial console.
Successful graphical boots emit `G1OS_READY` only after the compositor and
installer surface health checks pass.

The installer must use real util-linux `blkid`/`sfdisk` and real
dosfstools/e2fsprogs formatters from the initramfs. BusyBox compatibility
aliases are not substitutes for those command-line interfaces. Keep the ext4
retry variables local to `format_ext4_partition`: partition-node discovery
also uses shell globals, and sharing its `attempt` variable previously reset
the formatter retry on each nested device refresh. That left the install loop
repeatedly formatting the same partition while serial output was hidden.

FAT volume labels are limited to 11 characters; the EFI filesystem uses
`MACLITEBOOT` while its GPT partition name remains `MACLITE_BOOT`. Kernel
`used greatest stack depth` reports name the userspace process whose stack
high-water mark was sampled; the observed findmnt/udevadm reports left more
than 12 KiB on a 16 KiB task stack and did not indicate recursive G1OS shell
execution. The udevadm process was an unnecessary bounded queue wait, not the
boot blocker.
