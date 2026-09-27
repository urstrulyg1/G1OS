# MacLiteOS Installer

Installer flow (spec §51): live session -> detect internal drive -> partition -> copy base (read-only squashfs) -> create persistent user volume -> install Apple EFI boot chain.

## Primary Installation Method: GUI Installer (`mica-installer`)

The graphical installer provides a complete click-to-install experience directly from the live desktop:
- **Desktop & Dock Integration**: Clear **“Install MacLiteOS”** icon in the live session desktop and Dock.
- **Automated Drive Detection**: Automatically detects the internal SATA HDD/SSD (e.g. `/dev/sda`) and selects it by default.
- **Live USB Protection**: Detects the booted USB flash drive and locks it so it cannot be accidentally wiped.
- **Partition Inspection**: Shows the current disk layout before making any changes.
- **Explicit Confirmation**: Displays a clear destructive erase warning requiring user confirmation.
- **Progress & Error Handling**: Displays a real-time progress bar (0% - 100%) and detailed logs. Any errors halt the process and report the failure clearly.
- **Restart Workflow**: Upon completion, displays **“Installation Complete — Remove USB and Restart”** with an interactive **Restart** button.

## Fallback Installation Method: CLI Installer (`maclite-install`)

For headless systems, automation, or remote shells:
```bash
sudo maclite-install
```
The CLI installer prints detected drives, protects the live USB drive, requests typed confirmation (`YES`), and performs the identical Apple EFI and GPT partition setup.

## Partition Layout Created
| Partition | Size | Filesystem | Purpose |
| :--- | :--- | :--- | :--- |
| `MACLITE_BOOT` | 256 MB | FAT32 (`MACLITEBOOT` volume label) | Apple EFI bootloader (`BOOTX64.EFI`), GRUB, kernel, `.disk_label` |
| `MACLITE_DATA` | 4 GB+ | ext4 | Persistent writable user data (`/var/data`, `/home`) |
| `MACLITE_BASE` | Remaining | ext4/squashfs | Immutable read-only system base (`/`) |
