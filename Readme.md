

# VM Image Builder

This project provides a Makefile-driven, modular VM image builder for Ubuntu that creates a debootstrapped system root, split disks (system, swap, data) and exports to both VMware OVA and a KVM/libvirt test VM.

## Overview

The build pipeline is composed of numbered shell scripts in `lib/`, orchestrated by a single `Makefile`. A configuration file in `conf/` defines host-specific settings such as hostname, OS release, disk sizes, network configuration, and user credentials. The pipeline is designed to be incrementally rebuildable: configuration changes only invalidate the stages that actually depend on them.

## Features

- **Split Disk Architecture**
  - `systemroot.raw`: bootable, mostly immutable system disk, containing EFI system partition and an LVM root filesystem.
  - `swap.raw`: dedicated swap disk with GPT and a linux-swap partition.
  - `data.raw`: persistent data disk backed by LVM, carrying `/var` and `/home`.
- **Smart Incremental Builds**
  - Tracks `OS_RELEASE` and `EXTRA_PACKAGES` via a cached config file in `build/&lt;hostname&gt;/.config.cache`.
  - Automatically invalidates only the stages that need rebuilding when config changes are detected.
- **Persistent Data Disk**
  - `data.raw` is not overwritten by default, so `/var` and `/home` contents can survive repeated builds.
  - A separate `make dataclean` target is provided to explicitly rebuild the data disk.
- **First-Boot Sync**
  - A systemd oneshot service and helper script synchronize selected system files in `/var` from the base image into the persistent data disk on first boot.
  - Critical paths such as live PostgreSQL data directories are excluded from overwrites.
- **Multi-Hypervisor Support**
  - Generates a VMware-compatible OVA (`.ova`) with streamOptimized VMDKs and an OVF descriptor.
  - Provides a `make test` path that spins up a KVM/libvirt VM using qcow2 images and an automatically defined NAT network.
- **Multi-Config Support**
  - Multiple host configurations can be placed in `conf/`.
  - `make all-configs` iterates over all `*.conf` files.

## Directory Layout

```text
.
├── Makefile                    # Main build orchestration
├── Readme.md                   # Documentation (this file)
├── conf/                       # Per-VM configuration files
│   └── example.conf            # Example configuration (user-provided)
├── lib/                        # Build scripts (ordered by stage)
│   ├── common.sh               # Shared helpers (log/fail/require_*)
│   ├── 00-config-check.sh      # Smart config change detection
│   ├── 10-systemroot.sh        # Debootstrap base system into systemroot/
│   ├── 20-userconfig.sh        # Primary user, sudo, SSH keys
│   ├── 30-systemconfig.sh      # SSH hardening, network, first-boot sync
│   ├── 40-packages.sh          # Kernel, guest tools, extra packages
│   ├── 50-configure.sh         # Placeholder for config management
│   ├── 60-bootable.sh          # initramfs / GRUB config inside chroot
│   ├── 70-create-systemroot-image.sh
│   ├── 71-create-swap-image.sh
│   ├── 72-create-data-image.sh
│   ├── 80-create-ova.sh        # VMware OVF + OVA packaging
│   └── 90-test-vm.sh           # KVM/libvirt test VM creation
└── build/                      # Output directory (created by Make)
    └── &lt;hostname&gt;/
        ├── systemroot/         # Debootstrapped chroot tree
        ├── images/             # Raw disk images (.raw)
        └── vmware/             # VMDKs and OVA export
```

## Configuration

A configuration file (`conf/&lt;name&gt;.conf`) is a shell fragment that is sourced by the build scripts and Makefile. At minimum it should define:

- **Basic identity**
  - `HOSTNAME`: VM hostname, used for build directory name and for exported artifacts.
  - `OS_RELEASE`: Ubuntu release codename (e.g. `noble`).
  - `APT_MIRROR`: apt mirror URL for debootstrap.
- **User configuration**
  - `PRIMARY_USER`: login name for the main user.
  - `PRIMARY_USER_PASSWORD_HASH`: password hash (for `chpasswd -e` inside the chroot).
  - `PRIMARY_USER_SSH_PUBKEY`: SSH public key line to install into `~/.ssh/authorized_keys`.
- **Network configuration**
  - `NETWORK_IFACE`: interface name inside the guest (e.g. `eth0`).
  - `NETWORK_ADDRESS`: IP with CIDR suffix (e.g. `192.168.100.10/24`).
  - `NETWORK_GATEWAY`: default gateway address.
  - `NET_NAME` (optional): libvirt and OVF network name; defaults to `${HOSTNAME}-net` if unset.
- **Disk and LVM layout**
  - `DISK_SIZE_GB`: size of `systemroot.raw`.
  - `VG_NAME`: volume group name for the root LV on the system disk.
  - `LV_ROOT_SIZE_GB`: size of the root LV on the system disk.
  - `DATA_DISK_SIZE_GB`: size of `data.raw`.
  - `DATA_VG_NAME`: volume group name for the data disk.
  - `LV_VAR_NAME`, `LV_HOME_NAME`: LV names for `/var` and `/home`.
  - `LV_VAR_SIZE_GB`, `LV_HOME_SIZE_GB`: sizes for those LVs.
  - `LV_SWAP_SIZE_GB`: size of the swap disk (`swap.raw`).
- **Packages**
  - `EXTRA_PACKAGES`: space-separated list of additional packages to install in the chroot.
  - `INSTALL_KVM_TOOLS`: set to `true` to also install `qemu-guest-agent` in addition to `open-vm-tools`.
- **VM sizing**
  - `MEM_MB`: memory size of the VM (in MB); used by both OVA metadata and `virt-install`.
  - `VCPUS`: number of virtual CPUs; used by both OVA metadata and `virt-install`.

You may also define additional variables consumed by your own extensions in the configure stage.

## Build Stages

The Makefile implements a staged pipeline, with each major step having a corresponding target and script. Stages are ordered and state is tracked via stamp files inside `build/&lt;hostname&gt;/systemroot` and the config cache.

### Config cache and change detection

- **Script**: `lib/00-config-check.sh`
- **Make artifact**: `build/&lt;hostname&gt;/.config.cache`

When `CONFIG` changes, the Makefile regenerates `.config.cache` by first calling `00-config-check.sh`. This script compares the old and new config values for `OS_RELEASE` and `EXTRA_PACKAGES` and may:

- Delete the entire `systemroot/` (forcing a full debootstrap) if `OS_RELEASE` changed or packages were removed.
- Delete only the package-related stamps and bootloader output if packages were only added.

### Stage 1: systemroot (debootstrap)

- **Script**: `lib/10-systemroot.sh`
- **Target**: `build/&lt;hostname&gt;/systemroot/bin/bash`
- **Invocation**: `make systemroot`

This stage runs `debootstrap` using the configured Ubuntu release and mirror to create a minimal filesystem under `build/&lt;hostname&gt;/systemroot`. It also sets the hostname and basic APT/locale defaults. If a populated `systemroot` already exists (indicated by `bin/bash`), the script exits early to avoid redundant work.

### Stage 2: userconfig

- **Script**: `lib/20-userconfig.sh`
- **Target**: `systemroot/home/$PRIMARY_USER/.ssh/authorized_keys`
- **Invocation**: `make userconfig`

This stage ensures `sudo` is installed in the chroot, creates the primary user (if missing), sets the password hash, and populates `~/.ssh/authorized_keys` with the configured public key. Ownership and permissions in the home directory are normalized using the UID/GID retrieved from the chroot's passwd database.

### Stage 3: systemconfig

- **Script**: `lib/30-systemconfig.sh`
- **Target**: `systemroot/etc/systemd/network/10-eth0.link`
- **Invocation**: `make systemconfig`

This stage applies system-level configuration inside the chroot:

- SSH hardening: disables root login and password authentication, configures a minimal `sshd_config`.
- Interface naming: installs a `.link` file to force the primary interface to be named `eth0`.
- Network configuration: creates a `.network` file for `systemd-networkd` based on the configured address and gateway, then enables `systemd-networkd`.
- First-boot sync: installs `/usr/local/sbin/sync-var-home.sh` and a corresponding `sync-var-home.service` unit, which can refresh `/var` from a pristine tarball on boot while preserving selected paths.
- Writes a basic `/etc/hosts` to the chroot.

### Stage 4: packages

- **Script**: `lib/40-packages.sh`
- **Target**: `systemroot/.stage_packages`
- **Invocation**: `make packages`

This stage installs the kernel, guest tools, and any configured extra packages into the chroot. It bind-mounts `/proc`, `/sys` and `/dev` from the host, runs `apt-get update`, and then:

- Installs a base set: `linux-image-generic`, `linux-modules-extra-$(uname -r)`, `sudo`, `curl`, `wget`, `openssh-server`.
- Installs `open-vm-tools`, and optionally `qemu-guest-agent` if requested by config.
- Installs packages from `EXTRA_PACKAGES`.

On success, it writes the stamp file `.stage_packages`.

### Stage 5: configure

- **Script**: `lib/50-configure.sh`
- **Target**: `systemroot/.stage_configure`
- **Invocation**: `make configure`

This is a placeholder stage meant for integration with configuration management (e.g. cloning a git repo and overlaying configuration into `/etc` and other locations). Currently it logs entry and exit and writes the configure stamp; it is safe to extend with custom logic.

### Stage 6: bootable

- **Script**: `lib/60-bootable.sh`
- **Target**: `systemroot/.stage_bootable`
- **Invocation**: `make bootable`

This stage prepares the chroot for later EFI bootloader installation:

- Ensures `/boot/efi` exists.
- Bind-mounts `/dev`, `/proc`, `/sys` into the chroot.
- Adjusts `/etc/default/grub` to enable serial and VGA consoles and verbose systemd logging.
- Runs `update-initramfs` and `update-grub` inside the chroot.

The actual `grub-install` into a disk image is performed later by the systemroot image creation stage.

## Image Creation

The `images` target builds three raw disk images under `build/&lt;hostname&gt;/images`:

- `systemroot.raw`: bootable system disk.
- `swap.raw`: swap disk.
- `data.raw`: persistent data disk.

### Systemroot disk

- **Script**: `lib/70-create-systemroot-image.sh`
- **Target**: `build/&lt;hostname&gt;/images/systemroot.raw`

This script creates the primary system disk:

- Allocates a raw file of size `DISK_SIZE_GB` and attaches it as a loop device.
- Partitions it with GPT, creating an EFI system partition and an LVM PV partition.
- Initializes an LVM VG and root LV of size `LV_ROOT_SIZE_GB`.
- Formats the ESP as FAT32 and the root LV as ext4.
- Mounts the root LV and ESP and copies the chroot contents into the mounted root (excluding any existing EFI files).
- Ensures `/var` and `/home` in the image are empty directories intended to be mount points for the data disk.
- Generates `/etc/fstab` in the image, using `UUID=` entries for root, ESP, `/var`, `/home`, and swap (referencing the corresponding volumes and partitions).
- Configures GRUB in the image by creating a device map, running `grub-install` for EFI, and adding a fallback `BOOTX64.EFI` if needed.
- Runs `update-grub` inside the image chroot.
- Writes a marker file `/var/.image_version` inside the image that encodes the build version and metadata.

### Swap disk

- **Script**: `lib/71-create-swap-image.sh`
- **Target**: `build/&lt;hostname&gt;/images/swap.raw`

This script creates a swap disk of size `LV_SWAP_SIZE_GB`:

- Allocates a raw file and attaches it as a loop device.
- Partitions it with GPT and a single linux-swap partition.
- Initializes the partition with `mkswap`.

### Data disk

- **Script**: `lib/72-create-data-image.sh`
- **Target**: `build/&lt;hostname&gt;/images/data.raw`

The data disk hosts persistent `/var` and `/home`:

- Allocates a raw file of size `DATA_DISK_SIZE_GB`, attaches it as a loop device.
- Creates a single GPT partition, converts it into an LVM PV, and builds a data VG and LVs for `/var` and `/home`.
- Formats both LVs as ext4 and mounts them under `build/&lt;hostname&gt;/mnt_data/var` and `.../home`.
- Copies the current `/var` and `/home` content from the systemroot into these LVs using `rsync`.
- Creates an `/var/.image_version` marker on the data disk for the first-boot sync logic.

By default, `data.raw` is only created if it does not already exist, so subsequent `make images` runs preserve existing data. Use `make dataclean` if you want to force recreation of the data disk.

## OVA Export

- **Script**: `lib/80-create-ova.sh`
- **Target**: `build/&lt;hostname&gt;/vmware/&lt;hostname&gt;.ova`
- **Invocation**: `make vmware`

This stage produces a VMware-compatible OVA:

- Converts `systemroot.raw` and `swap.raw` to streamOptimized VMDKs.
- Optionally converts `data.raw` to `data-persistent.vmdk` if a fresh image build marker is present.
- Constructs an OVF descriptor with VM hardware (CPU, memory), virtual disks, and network configuration.
- Packages the OVF and VMDKs into a single `.ova` tarball.
- Clears the image-version stamp used to decide whether to re-export the data disk on subsequent runs.

## KVM/Libvirt Test VM

- **Script**: `lib/90-test-vm.sh`
- **Target**: `make test`

The test stage spins up a local KVM/libvirt VM using the generated images:

- Converts the three `.raw` images into `.qcow2` files under `/var/lib/libvirt/images/&lt;hostname&gt;-test`.
- Defines (if needed) and starts a libvirt NAT network using the configured gateway, CIDR and DHCP range.
- Creates a guest with virtio disks, virtio network interface, EFI firmware (Secure Boot disabled), and the configured CPU and memory.
- Starts the VM and attaches a serial console for interactive testing.

## Usage

### Basic build

```sh
make images CONFIG=conf/myvm.conf
```

This will:

- Run config change detection and update the config cache.
- Execute all stages up to and including the image creation.
- Produce `systemroot.raw`, `swap.raw`, and `data.raw` under `build/&lt;hostname&gt;/images`.

### Build OVA

```sh
make vmware CONFIG=conf/myvm.conf
```

Requires that the image stage has completed. Produces `build/&lt;hostname&gt;/vmware/&lt;hostname&gt;.ova`.

### Run in KVM/libvirt

```sh
sudo make test CONFIG=conf/myvm.conf
```

Converts the raw images to qcow2, sets up a libvirt network, defines a VM and drops you into the serial console. Root privileges are typically required for libvirt image and network management.

### Multiple configs

```sh
make all-configs
```

Iterates over all `conf/*.conf` and runs `make images` for each config.

## Cleaning

- `make clean CONFIG=conf/myvm.conf`
  - Removes the chroot (`systemroot/`), system and swap raw images, OVA and VMDKs, and the config cache for that host.
  - Leaves `data.raw` intact.
- `make dataclean CONFIG=conf/myvm.conf`
  - Removes `data.raw` only.
- `make distclean CONFIG=conf/myvm.conf`
  - Removes the entire `build/&lt;hostname&gt;` directory for that host.
- `make clean-all`
  - Removes the entire `build/` tree for all hosts.

## Extending the Pipeline

The numbered scripts are intentionally modular and small. Suggested extension points include:

- Enhancing `50-configure.sh` to pull configuration from git or another source of truth.
- Adding additional service configuration to `30-systemconfig.sh` (e.g., enabling monitoring agents).
- Extending the OVA generator to support additional virtual hardware or metadata fields.
- Adding new stages (e.g., for application deployment) with corresponding Makefile targets and stamp files.

## Requirements

The build host must provide at least:

- `bash`, `debootstrap`, `parted`, `losetup`, `qemu-img`
- LVM tools: `pvcreate`, `vgcreate`, `lvcreate`, `vgchange`
- Filesystem tools: `mkfs.ext4`, `mkfs.vfat`, `mkswap`, `rsync`
- GRUB/EFI tools: `grub-install`, `update-grub`, `update-initramfs`
- For VMware export: `tar`
- For KVM testing: `qemu-img`, `virt-install`, `virsh`, and a working libvirt setup

Most operations require root privileges (particularly loop device, partition, and LVM handling).

