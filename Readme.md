# VM Image Builder

This project provides a Makefile-driven, modular VM image builder for Ubuntu that creates a debootstrapped system root, split disks (system, data) and exports to both VMware OVA and a KVM/libvirt test VM.

## Overview

The build pipeline is composed of numbered shell scripts in `lib/`, orchestrated by a single `Makefile`. A configuration file in `conf/` defines host-specific settings such as hostname, OS release, disk sizes, network configuration, and user credentials. The pipeline is designed to be incrementally rebuildable: configuration changes only invalidate the stages that actually depend on them.

## Features

- **Split Disk Architecture**
  - `systemroot.raw`: bootable, mostly immutable system disk, containing an EFI system partition and an LVM root filesystem.
  - `data.raw`: persistent data disk backed by LVM, carrying `/var`, `/home`, and swap.
- **Smart Incremental Builds**
  - Tracks `OS_RELEASE` and `EXTRA_PACKAGES` via a cached config file in `build/<hostname>/.config.cache`.
  - Automatically invalidates only the stages that need rebuilding when config changes are detected.
- **Persistent Data Disk**
  - `data.raw` is not overwritten by default, so `/var` and `/home` contents survive repeated builds.
  - A separate `make dataclean` target is provided to explicitly rebuild the data disk.
- **First-Boot Sync**
  - A systemd oneshot service and helper script synchronize selected system files in `/var` from the base image into the persistent data disk on first boot.
  - Critical paths such as live PostgreSQL data directories are excluded from overwrites.
- **Extra APT Repositories**
  - `35-repositories.sh` supports adding third-party APT repositories (e.g. PostgreSQL PGDG) before package installation, driven by `EXTRA_REPOSITORIES` in the config.
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
│   └── example.conf            # Example configuration
├── lib/                        # Build scripts (ordered by stage)
│   ├── common.sh               # Shared helpers (log/fail/require_*)
│   ├── 00-config-check.sh      # Smart config change detection
│   ├── 10-systemroot.sh        # Debootstrap base system into systemroot/
│   ├── 20-userconfig.sh        # Primary user, sudo, SSH keys
│   ├── 30-systemconfig.sh      # SSH hardening, network, first-boot sync
│   ├── 35-repositories.sh      # Extra APT repositories
│   ├── 40-packages.sh          # Kernel, guest tools, extra packages
│   ├── 50-configure.sh         # Placeholder for config management
│   ├── 60-bootable.sh          # initramfs / GRUB config inside chroot
│   ├── 70-create-systemroot-image.sh
│   ├── 72-create-data-image.sh # Data disk (includes swap LV)
│   ├── 80-create-ova.sh        # VMware OVF + OVA packaging
│   └── 90-test-vm.sh           # KVM/libvirt test VM creation
└── build/                      # Output directory (created by Make)
    └── <hostname>/
        ├── systemroot/         # Debootstrapped chroot tree
        ├── images/             # Raw disk images (.raw)
        └── vmware/             # VMDKs and OVA export
```

## Configuration

A configuration file (`conf/<name>.conf`) is a shell fragment sourced by the build scripts and Makefile. Below is a fully annotated example — see `conf/example.conf` for the canonical version.

```bash
# Ubuntu release codename; e.g. jammy (22.04), noble (24.04)
OS_RELEASE=noble
APT_MIRROR=http://archive.ubuntu.com/ubuntu

# VM resources
MEM_MB=4096
VCPUS=2

# Hostname — also used as the build directory name and artifact prefix
HOSTNAME=myserver

# --- System disk ---
DISK_SIZE_GB=20
VG_NAME="${HOSTNAME}-vgsys"
LV_ROOT_SIZE_GB=16

# --- Data disk (persistent: /var, /home, swap) ---
DATA_DISK_SIZE_GB=40
DATA_VG_NAME="${HOSTNAME}-vgdata"
LV_VAR_NAME=var
LV_VAR_SIZE_GB=10
LV_HOME_NAME=home
LV_HOME_SIZE_GB=20
# Swap is now a logical volume on the data disk (no separate swap.raw)
LV_SWAP_NAME=swap
LV_SWAP_SIZE_GB=4

# --- Network ---
NETWORK_IFACE=eth0
# Set to true for DHCP; false for static addressing
NETWORK_USE_DHCP=false
NETWORK_ADDRESS=192.168.1.10/24   # IP with CIDR suffix; ignored when DHCP
NETWORK_GATEWAY=192.168.1.1       # Ignored when DHCP
NETWORK_DNS="192.168.1.1"

# --- Optional: libvirt / OVF network name ---
# NET_NAME="${HOSTNAME}-net"      # defaults to ${HOSTNAME}-net if unset

# --- Primary user ---
PRIMARY_USER=admin
# Password hash for chpasswd -e; generate with: mkpasswd -m sha-512
PRIMARY_USER_PASSWORD_HASH='$6$rounds=4096$...'
# Full SSH public key line installed into ~/.ssh/authorized_keys
PRIMARY_USER_SSH_PUBKEY="ssh-ed25519 AAAA... user@host"

# --- Extra APT repositories (handled by 35-repositories.sh) ---
# Space-separated list of known repository tokens.
# Currently supported: "postgresql" (adds the official PGDG repo).
EXTRA_REPOSITORIES="postgresql"

# --- Extra packages ---
EXTRA_PACKAGES="vim curl jq"

# --- Guest tooling ---
# open-vm-tools is always installed.
# Set to 'true' to also install qemu-guest-agent.
INSTALL_KVM_TOOLS=true
```

### Configuration reference

#### Basic identity

| Variable | Required | Description |
|---|---|---|
| `HOSTNAME` | ✔ | VM hostname; used as build directory name and artifact prefix |
| `OS_RELEASE` | ✔ | Ubuntu release codename (e.g. `noble`) |
| `APT_MIRROR` | ✔ | apt mirror URL for debootstrap |

#### VM sizing

| Variable | Required | Description |
|---|---|---|
| `MEM_MB` | ✔ | Memory in MB; used in OVA metadata and `virt-install` |
| `VCPUS` | ✔ | vCPU count; used in OVA metadata and `virt-install` |

#### User configuration

| Variable | Required | Description |
|---|---|---|
| `PRIMARY_USER` | ✔ | Login name for the main user |
| `PRIMARY_USER_PASSWORD_HASH` | ✔ | Password hash for `chpasswd -e` (generate with `mkpasswd -m sha-512`) |
| `PRIMARY_USER_SSH_PUBKEY` | ✔ | SSH public key line installed into `~/.ssh/authorized_keys` |

#### Network configuration

| Variable | Required | Description |
|---|---|---|
| `NETWORK_IFACE` | ✔ | Interface name inside the guest (e.g. `eth0`) |
| `NETWORK_USE_DHCP` | ✔ | `true` for DHCP; `false` for static addressing |
| `NETWORK_ADDRESS` | static only | IP with CIDR suffix (e.g. `192.168.100.10/24`) |
| `NETWORK_GATEWAY` | static only | Default gateway address |
| `NETWORK_DNS` | ✗ | Space-separated DNS server list |
| `NET_NAME` | ✗ | libvirt and OVF network name; defaults to `${HOSTNAME}-net` |

#### Disk and LVM layout

| Variable | Required | Description |
|---|---|---|
| `DISK_SIZE_GB` | ✔ | Size of `systemroot.raw` |
| `VG_NAME` | ✔ | Volume group name for the root LV on the system disk |
| `LV_ROOT_SIZE_GB` | ✔ | Size of the root LV on the system disk |
| `DATA_DISK_SIZE_GB` | ✔ | Size of `data.raw` |
| `DATA_VG_NAME` | ✔ | Volume group name for the data disk |
| `LV_VAR_NAME` / `LV_HOME_NAME` | ✔ | LV names for `/var` and `/home` |
| `LV_VAR_SIZE_GB` / `LV_HOME_SIZE_GB` | ✔ | Sizes for the above LVs |
| `LV_SWAP_NAME` | ✔ | LV name for the swap volume on the data disk |
| `LV_SWAP_SIZE_GB` | ✔ | Size of the swap LV on the data disk |

#### Packages and repositories

| Variable | Required | Description |
|---|---|---|
| `EXTRA_REPOSITORIES` | ✗ | Space-separated list of repository tokens (e.g. `postgresql`) |
| `EXTRA_PACKAGES` | ✗ | Space-separated list of additional packages to install in the chroot |
| `INSTALL_KVM_TOOLS` | ✗ | Set to `true` to also install `qemu-guest-agent` alongside `open-vm-tools` |

## Build Stages

The Makefile implements a staged pipeline, with each major step having a corresponding target and script. Stages are ordered and state is tracked via stamp files inside `build/<hostname>/systemroot` and the config cache.

### Config cache and change detection

- **Script**: `lib/00-config-check.sh`
- **Make artifact**: `build/<hostname>/.config.cache`

When `CONFIG` changes, the Makefile regenerates `.config.cache` by first calling `00-config-check.sh`. This script compares the old and new config values for `OS_RELEASE` and `EXTRA_PACKAGES` and may:

- Delete the entire `systemroot/` (forcing a full debootstrap) if `OS_RELEASE` changed or packages were removed.
- Delete only the package-related stamps and bootloader output if packages were only added.

### Stage 1: systemroot (debootstrap)

- **Script**: `lib/10-systemroot.sh`
- **Target**: `build/<hostname>/systemroot/bin/bash`
- **Invocation**: `make systemroot`

Runs `debootstrap` using the configured Ubuntu release and mirror to create a minimal filesystem under `build/<hostname>/systemroot`. Also sets the hostname and basic APT/locale defaults. If a populated `systemroot` already exists (indicated by `bin/bash`), the script exits early to avoid redundant work.

### Stage 2: userconfig

- **Script**: `lib/20-userconfig.sh`
- **Target**: `systemroot/home/$PRIMARY_USER/.ssh/authorized_keys`
- **Invocation**: `make userconfig`

Ensures `sudo` is installed in the chroot, creates the primary user (if missing), sets the password hash, and populates `~/.ssh/authorized_keys` with the configured public key. Ownership and permissions in the home directory are normalized using the UID/GID retrieved from the chroot's passwd database.

### Stage 3: systemconfig

- **Script**: `lib/30-systemconfig.sh`
- **Target**: `systemroot/etc/systemd/network/10-eth0.link`
- **Invocation**: `make systemconfig`

Applies system-level configuration inside the chroot:

- SSH hardening: disables root login and password authentication, configures a minimal `sshd_config`.
- Interface naming: installs a `.link` file to force the primary interface to be named `eth0`.
- Network configuration: creates a `.network` file for `systemd-networkd` based on the configured address/gateway (static) or DHCP, then enables `systemd-networkd`.
- First-boot sync: installs `/usr/local/sbin/sync-var-home.sh` and a corresponding `sync-var-home.service` unit, which refreshes `/var` from a pristine tarball on boot while preserving selected paths.
- Writes a basic `/etc/hosts` to the chroot.

### Stage 3a: repositories

- **Script**: `lib/35-repositories.sh`
- **Target**: `systemroot/.stage_repositories`
- **Invocation**: `make repositories`

Adds any third-party APT repositories listed in `EXTRA_REPOSITORIES` into the chroot before the package installation stage. Each token in the list maps to a known repository definition (GPG key, sources list entry). Currently the following tokens are supported:

- `postgresql` — adds the official PGDG apt repository for the configured OS release.

### Stage 4: packages

- **Script**: `lib/40-packages.sh`
- **Target**: `systemroot/.stage_packages`
- **Invocation**: `make packages`

Installs the kernel, guest tools, and any configured extra packages into the chroot. It bind-mounts `/proc`, `/sys` and `/dev` from the host, runs `apt-get update`, and then:

- Installs a base set: `linux-image-generic`, `linux-modules-extra-$(uname -r)`, `sudo`, `curl`, `wget`, `openssh-server`.
- Installs `open-vm-tools`, and optionally `qemu-guest-agent` if `INSTALL_KVM_TOOLS=true`.
- Installs packages from `EXTRA_PACKAGES`.

On success, writes the stamp file `.stage_packages`.

### Stage 5: configure

- **Script**: `lib/50-configure.sh`
- **Target**: `systemroot/.stage_configure`
- **Invocation**: `make configure`

Placeholder stage for integration with configuration management (e.g. cloning a git repo and overlaying configuration into `/etc` and other locations). Currently logs entry/exit and writes the configure stamp; safe to extend with custom logic.

### Stage 6: bootable

- **Script**: `lib/60-bootable.sh`
- **Target**: `systemroot/.stage_bootable`
- **Invocation**: `make bootable`

Prepares the chroot for later EFI bootloader installation:

- Ensures `/boot/efi` exists.
- Bind-mounts `/dev`, `/proc`, `/sys` into the chroot.
- Adjusts `/etc/default/grub` to enable serial and VGA consoles and verbose systemd logging.
- Runs `update-initramfs` and `update-grub` inside the chroot.

The actual `grub-install` into a disk image is performed later by the systemroot image creation stage.

## Image Creation

The `images` target builds two raw disk images under `build/<hostname>/images`:

- `systemroot.raw`: bootable system disk.
- `data.raw`: persistent data disk (includes `/var`, `/home`, and swap LV).

### Systemroot disk

- **Script**: `lib/70-create-systemroot-image.sh`
- **Target**: `build/<hostname>/images/systemroot.raw`

Creates the primary system disk:

- Allocates a raw file of size `DISK_SIZE_GB` and attaches it as a loop device.
- Partitions it with GPT, creating an EFI system partition and an LVM PV partition.
- Initializes an LVM VG and root LV of size `LV_ROOT_SIZE_GB`.
- Formats the ESP as FAT32 and the root LV as ext4.
- Mounts the root LV and ESP and copies the chroot contents into the mounted root (excluding any existing EFI files).
- Ensures `/var` and `/home` in the image are empty directories intended to be mount points for the data disk.
- Generates `/etc/fstab` in the image, using `UUID=` entries for root, ESP, `/var`, `/home`, and swap.
- Configures GRUB in the image by creating a device map, running `grub-install` for EFI, and adding a fallback `BOOTX64.EFI` if needed.
- Runs `update-grub` inside the image chroot.
- Writes a marker file `/var/.image_version` inside the image that encodes the build version and metadata.

### Data disk

- **Script**: `lib/72-create-data-image.sh`
- **Target**: `build/<hostname>/images/data.raw`

The data disk hosts persistent `/var`, `/home`, and swap:

- Allocates a raw file of size `DATA_DISK_SIZE_GB`, attaches it as a loop device.
- Creates a single GPT partition, converts it into an LVM PV, and builds a data VG and LVs for `/var`, `/home`, and swap.
- Formats the `/var` and `/home` LVs as ext4; initializes the swap LV with `mkswap`.
- Mounts `/var` and `/home` and populates them from the systemroot chroot using `rsync`.
- Creates an `/var/.image_version` marker on the data disk for the first-boot sync logic.

By default, `data.raw` is only created if it does not already exist, so subsequent `make images` runs preserve existing data. Use `make dataclean` to force recreation.

## OVA Export

- **Script**: `lib/80-create-ova.sh`
- **Target**: `build/<hostname>/vmware/<hostname>.ova`
- **Invocation**: `make vmware`

Produces a VMware-compatible OVA:

- Converts `systemroot.raw` to a streamOptimized VMDK.
- Optionally converts `data.raw` to `data-persistent.vmdk` if a fresh image build marker is present.
- Constructs an OVF descriptor with VM hardware (CPU, memory), virtual disks, and network configuration.
- Packages the OVF and VMDKs into a single `.ova` tarball.
- Clears the image-version stamp used to decide whether to re-export the data disk on subsequent runs.

## KVM/Libvirt Test VM

- **Script**: `lib/90-test-vm.sh`
- **Target**: `make test`

Spins up a local KVM/libvirt VM using the generated images:

- Converts the two `.raw` images into `.qcow2` files under `/var/lib/libvirt/images/<hostname>-test`.
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
- Execute all stages up to and including image creation.
- Produce `systemroot.raw` and `data.raw` under `build/<hostname>/images`.

### Build OVA

```sh
make vmware CONFIG=conf/myvm.conf
```

Requires that the image stage has completed. Produces `build/<hostname>/vmware/<hostname>.ova`.

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
  - Removes the chroot (`systemroot/`), the system raw image, OVA and VMDKs, and the config cache for that host.
  - Leaves `data.raw` intact.
- `make dataclean CONFIG=conf/myvm.conf`
  - Removes `data.raw` only.
- `make distclean CONFIG=conf/myvm.conf`
  - Removes the entire `build/<hostname>` directory for that host.
- `make clean-all`
  - Removes the entire `build/` tree for all hosts.

## Extending the Pipeline

The numbered scripts are intentionally modular and small. Suggested extension points include:

- Enhancing `50-configure.sh` to pull configuration from git or another source of truth.
- Adding additional service configuration to `30-systemconfig.sh` (e.g., enabling monitoring agents).
- Adding new repository definitions to `35-repositories.sh` by extending the `EXTRA_REPOSITORIES` token list.
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
