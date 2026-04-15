# VM Image Builder

This project provides a Makefile-driven, modular VM image builder for Ubuntu that creates a debootstrapped system root, three disk images (system, swap, data) and exports to both a VMware OVA and a KVM/libvirt test VM.

## Overview

The build pipeline is composed of numbered shell scripts in `lib/`, orchestrated by a single `Makefile`. A configuration file in `conf/` defines host-specific settings such as hostname, OS release, disk sizes, network configuration, and user credentials. The pipeline is designed to be incrementally rebuildable: configuration changes only invalidate the stages that actually depend on them.

## Design Philosophy

The architecture separates concerns across three disk images with very different lifecycles:

- **`systemroot.raw`** — the immutable system image. It is mounted read-only (`/`) at runtime. Because it carries no persistent state, it can be replaced wholesale on every deployment without touching user data. `/tmp` is backed by a tmpfs.
- **`swap.raw`** — a throwaway disk. It is recreated on every build so that its UUID is known at image-build time and can be written into the system image's `/etc/fstab`. Since swap holds no durable state, recreating it is safe and cheap.
- **`data.raw`** — the one disk that matters operationally. Created once and preserved across all subsequent builds and deployments. It backs `/var` and `/home` via LVM and is the **only disk that needs to be backed up** in production.

To reconcile the read-only system image with the live `/var` on the data disk, a **first-boot sync** service runs early in the boot sequence. It unpacks a `pristine-var.tgz` tarball (embedded in the system image at build time) into the live `/var`, using `--keep-newer-files` so it only fills in missing entries or overwrites files that are older. Paths such as live database directories (e.g. PostgreSQL data) are explicitly excluded from overwrite.

## Features

- **Split Disk Architecture**
  - `systemroot.raw`: read-only system disk with EFI system partition and LVM root filesystem.
  - `swap.raw`: dedicated swap disk; recreated each build to keep its UUID in sync with fstab.
  - `data.raw`: persistent data disk (LVM `/var` + `/home`); created once, preserved and backed up.
- **Smart Incremental Builds**
  - Tracks `OS_RELEASE` and `EXTRA_PACKAGES` via a cached config file in `build/<hostname>/.config.cache`.
  - Automatically invalidates only the stages that need rebuilding when config changes are detected.
- **First-Boot Sync**
  - A systemd oneshot service (`sync-var-home.service`) runs before `network-pre.target`.
  - It unpacks `/usr/local/share/pristine-var.tgz` into `/var` with `--keep-newer-files`, refreshing package-installed state without overwriting live data.
  - Explicitly excludes critical paths (e.g. `./lib/postgresql`) from any overwrite.
- **Extra APT Repositories**
  - `35-repositories.sh` supports adding third-party APT repositories (e.g. PostgreSQL PGDG) before package installation, driven by `EXTRA_REPOSITORIES` in the config.
- **Multi-Hypervisor Support**
  - Generates a VMware-compatible OVA (`.ova`) with streamOptimized VMDKs and an OVF descriptor.
  - OVA always includes `system-root.vmdk` and `swap.vmdk`; `data-persistent.vmdk` is included only when the data disk was freshly built in the same run.
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
│   ├── 70-create-systemroot-image.sh  # System disk + swap.raw + fstab
│   ├── 72-create-data-image.sh        # Data disk (/var + /home LVs)
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

# --- Swap disk ---
# swap.raw is a separate, throwaway disk image created inside 70-create-systemroot-image.sh.
# It is always recreated so its partition UUID can be embedded in fstab at image-build time.
# No LVM; a single GPT linux-swap partition is initialized with mkswap.
LV_SWAP_SIZE_GB=4

# --- Data disk (/var + /home only; no swap) ---
# Created once and preserved across deployments. This is the only disk to back up.
DATA_DISK_SIZE_GB=40
DATA_VG_NAME="${HOSTNAME}-vgdata"
LV_VAR_NAME=var
LV_VAR_SIZE_GB=10
LV_HOME_NAME=home
LV_HOME_SIZE_GB=20
# Optional: override filesystem type for /var and /home (default: ext4)
# FS_VAR_TYPE=ext4    # ext4, xfs, or btrfs
# FS_HOME_TYPE=ext4

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

#### Disk layout

| Variable | Required | Description |
|---|---|---|
| `DISK_SIZE_GB` | ✔ | Total size of `systemroot.raw` |
| `VG_NAME` | ✔ | Volume group name on the system disk |
| `LV_ROOT_SIZE_GB` | ✔ | Root LV size on the system disk |
| `LV_SWAP_SIZE_GB` | ✔ | Size of `swap.raw` (single GPT linux-swap partition, no LVM) |
| `DATA_DISK_SIZE_GB` | ✔ | Total size of `data.raw` |
| `DATA_VG_NAME` | ✔ | Volume group name on the data disk |
| `LV_VAR_NAME` / `LV_HOME_NAME` | ✔ | LV names for `/var` and `/home` on the data disk |
| `LV_VAR_SIZE_GB` / `LV_HOME_SIZE_GB` | ✔ | Sizes for the above LVs |
| `FS_VAR_TYPE` / `FS_HOME_TYPE` | ✗ | Filesystem type for `/var` / `/home`; `ext4` (default), `xfs`, or `btrfs` |

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

- **SSH hardening**: disables root login and password authentication, configures a minimal `sshd_config`.
- **Interface naming**: installs a `.link` file to force the primary interface to be named `eth0`.
- **Network**: creates a `.network` file for `systemd-networkd` — either DHCP or static address/gateway/DNS — and enables `systemd-networkd` and `systemd-resolved`.
- **tmpfs for `/tmp`**: enables `tmp.mount` (required for read-only root operation).
- **First-boot sync**: installs `/usr/local/sbin/sync-var-home.sh` and `sync-var-home.service`. On first boot after a new image is deployed, the service unpacks `/usr/local/share/pristine-var.tgz` into the live `/var` using `--keep-newer-files`, filling in any missing package-installed state without overwriting existing data. Paths such as `./lib/postgresql` are explicitly excluded.
- **`/etc/hosts`**: writes a basic hosts file with the configured hostname.

### Stage 3a: repositories

- **Script**: `lib/35-repositories.sh`
- **Target**: `systemroot/.stage_repositories`
- **Invocation**: `make repositories`

Adds any third-party APT repositories listed in `EXTRA_REPOSITORIES` into the chroot before package installation. Each token in the list maps to a known repository definition (GPG key + sources entry). Currently supported tokens:

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

The actual `grub-install` into the disk image is performed in the next stage.

## Image Creation

The `images` target builds three raw disk images under `build/<hostname>/images`:

- `systemroot.raw`: bootable, read-only system disk.
- `swap.raw`: throwaway swap disk (no LVM; single GPT linux-swap partition).
- `data.raw`: persistent data disk with LVM `/var` and `/home`.

### Systemroot and swap disk

- **Script**: `lib/70-create-systemroot-image.sh`
- **Target**: `build/<hostname>/images/systemroot.raw`

This script creates both the system disk and the swap disk in a single pass, so the swap partition UUID is known and can be embedded in fstab before the script exits.

**System disk:**
- Allocates a raw file of `DISK_SIZE_GB` and attaches it as a loop device.
- Partitions with GPT: an EFI system partition and an LVM PV partition.
- Creates LVM VG + root LV; formats ESP as FAT32, root as ext4.
- Copies the chroot into the image root (excluding EFI contents) via `rsync`.
- Empties `/var` and `/home` in the image — these are mount points only; content lives on the data disk.
- Generates `/etc/fstab` with `UUID=` entries for root, ESP, `/var`, `/home`, and swap.
- Runs `grub-install` (EFI) and `update-grub` inside the image chroot.
- Writes `/var/.image_version` as a build metadata marker used by the first-boot sync service and the OVA export logic.

**Swap disk (created in the same script):**
- Allocates a raw file of `LV_SWAP_SIZE_GB`, attaches it as a second loop device.
- Partitions with GPT and a single linux-swap partition; initializes with `mkswap`.
- The resulting partition UUID is appended to the fstab of the system disk image before the image is finalized.
- `swap.raw` is always recreated (it carries no persistent data); only its UUID matters.

### Data disk

- **Script**: `lib/72-create-data-image.sh`
- **Target**: `build/<hostname>/images/data.raw`

The data disk is the single source of persistent state. It holds `/var` and `/home` and is **only created if it does not already exist**, preserving data across subsequent builds.

- Allocates a raw file of `DATA_DISK_SIZE_GB`, attaches it as a loop device.
- Creates a single GPT partition, converts it into an LVM PV, and builds a VG with two LVs: one for `/var` and one for `/home`.
- Formats both LVs (ext4 by default; xfs and btrfs are also supported via `FS_VAR_TYPE` / `FS_HOME_TYPE`).
- Populates `/var` and `/home` from the systemroot chroot using `rsync`.
- Writes `/var/.image_version` as the trigger file for the first-boot sync service.

Use `make dataclean` to explicitly discard and recreate the data disk.

> **Operational note**: `data.raw` is the only disk image that needs to be backed up in production. `systemroot.raw` and `swap.raw` are fully reproducible from the build pipeline.

## OVA Export

- **Script**: `lib/80-create-ova.sh`
- **Target**: `build/<hostname>/vmware/<hostname>.ova`
- **Invocation**: `make vmware`

Produces a VMware-compatible OVA:

- Converts `systemroot.raw` → `system-root.vmdk` and `swap.raw` → `swap.vmdk` (streamOptimized format); skips conversion if the VMDK is already up to date.
- Converts `data.raw` → `data-persistent.vmdk` **only** when the data disk was freshly built in the current run (indicated by the `build/<hostname>/.image_version` stamp). This prevents accidentally overwriting the production data disk VMDK on subsequent system-only rebuilds.
- Generates an OVF descriptor referencing all included VMDKs, EFI firmware hints, and the configured CPU/memory/network.
- Packages everything into a single `.ova` tarball.
- Removes the `.image_version` stamp so subsequent `make vmware` calls without a new image build do not re-export the data disk.

## KVM/Libvirt Test VM

- **Script**: `lib/90-test-vm.sh`
- **Target**: `make test`

Spins up a local KVM/libvirt VM using the generated images:

- Converts `systemroot.raw` and `data.raw` to qcow2 under `/var/lib/libvirt/images/<hostname>-test`.
- Defines (if needed) and starts a libvirt NAT network using the configured gateway, CIDR and DHCP range.
- Creates a guest with virtio disks, virtio network, EFI firmware (Secure Boot disabled), and the configured CPU and memory.
- Starts the VM and attaches a serial console for interactive testing.

## Usage

### Basic build

```sh
make images CONFIG=conf/myvm.conf
```

This will:

- Run config change detection and update the config cache.
- Execute all stages up to and including image creation.
- Produce `systemroot.raw`, `swap.raw`, and `data.raw` under `build/<hostname>/images`.

### Build OVA

```sh
make vmware CONFIG=conf/myvm.conf
```

Requires that the image stage has completed. Produces `build/<hostname>/vmware/<hostname>.ova` containing `system-root.vmdk`, `swap.vmdk`, and (if freshly built) `data-persistent.vmdk`.

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
  - Removes the chroot (`systemroot/`), `systemroot.raw`, `swap.raw`, OVA and VMDKs, and the config cache for that host.
  - Leaves `data.raw` intact.
- `make dataclean CONFIG=conf/myvm.conf`
  - Removes `data.raw` only, forcing a full data disk rebuild on the next `make images`.
- `make distclean CONFIG=conf/myvm.conf`
  - Removes the entire `build/<hostname>` directory for that host.
- `make clean-all`
  - Removes the entire `build/` tree for all hosts.

## Extending the Pipeline

The numbered scripts are intentionally modular and small. Suggested extension points include:

- Enhancing `50-configure.sh` to pull configuration from git or another source of truth.
- Adding additional service configuration to `30-systemconfig.sh` (e.g. monitoring agents, additional systemd units).
- Adding new repository definitions to `35-repositories.sh` by extending the `EXTRA_REPOSITORIES` token list.
- Extending the OVA generator to support additional virtual hardware or metadata fields.
- Adding new stages (e.g. for application deployment) with corresponding Makefile targets and stamp files.

## Requirements

The build host must provide at least:

- `bash`, `debootstrap`, `parted`, `losetup`, `qemu-img`
- LVM tools: `pvcreate`, `vgcreate`, `lvcreate`, `vgchange`
- Filesystem tools: `mkfs.ext4`, `mkfs.vfat`, `mkswap`, `rsync`
- GRUB/EFI tools: `grub-install`, `update-grub`, `update-initramfs`
- For VMware export: `tar`
- For KVM testing: `qemu-img`, `virt-install`, `virsh`, and a working libvirt setup

Most operations require root privileges (particularly loop device, partition, and LVM handling).
