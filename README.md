# Ubuntu ZFS Installer

This repository contains a Bash installer for a single-disk Ubuntu root-on-ZFS install, derived from the OpenZFS Ubuntu 22.04 guide and adapted for a fully automated UEFI workflow without zsys.

## Scope

Supported in the current implementation:

- Single disk only
- UEFI boot only
- Ubuntu live environment execution
- Configurable swap partition size
- Optional LUKS encryption for the root pool
- No zsys installation or dataset metadata

Explicitly out of scope for now:

- BIOS boot
- Mirror or raidz topologies
- Dual boot
- Hibernation tuning
- ZFS native encryption mode

## Requirements

- Ubuntu live environment booted in UEFI mode
- Network access for `apt` and `debootstrap`
- Target disk exposed under `/dev/disk/by-id`
- Root shell

## Usage

Example unencrypted install:

```bash
sudo ./install-ubuntu-zfs.sh \
  --disk /dev/disk/by-id/ata-example-disk \
  --hostname zfs-host \
  --username alice \
  --swap-size 4G \
  --ubuntu-codename resolute
```

Example LUKS install:

```bash
sudo ./install-ubuntu-zfs.sh \
  --disk /dev/disk/by-id/ata-example-disk \
  --hostname zfs-host \
  --username alice \
  --encryption luks \
  --swap-size 8G \
  --ubuntu-codename resolute
```

To review actions without executing them:

```bash
sudo ./install-ubuntu-zfs.sh ... --dry-run
```

Dry-run mode prints the commands it would execute, skips destructive confirmation,
and does not require root, UEFI, network access, or a real block device.

Environment-style config files can be loaded with `--config`. Values from
explicit CLI flags override values from the config file.

Reset installer state and wipe the target disk before starting over:

```bash
sudo ./reset-ubuntu-zfs.sh \
  --disk /dev/disk/by-id/ata-example-disk
```

The reset utility also supports `--dry-run` and `--start-phase` with these
phases: `teardown-installer-state`, `wipe-disk`, and `finalize-reset`.

## Notes

- The installer is destructive and wipes the target disk.
- The reset script is also destructive and will wipe the selected disk signatures and partition table.
- The boot pool name is intentionally fixed to `bpool`.
- Unknown resume phases are rejected before any phase runs.
- The first implementation targets maintainability over maximum configurability.
- Review `install.log` after a run.
- Review `reset.log` after a reset run.

## Layout

- `install-ubuntu-zfs.sh`: top-level orchestration and argument parsing
- `reset-ubuntu-zfs.sh`: teardown and disk reset utility for clean reruns
- `lib/common.sh`: logging, safety checks, helpers, and cleanup
- `lib/partition.sh`: partitioning and disk wipe logic
- `lib/pools.sh`: LUKS, zpools, and dataset creation
- `lib/chroot.sh`: target system configuration and bootloader setup
- `examples/config.env.example`: environment-style configuration template
