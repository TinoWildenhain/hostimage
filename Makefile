# VM Image Builder Makefile

# Usage: make [target] CONFIG=conf/svapl159.conf
# make all-configs

SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

# Default to first .conf found in conf/ directory if not specified
CONFIG ?= $(firstword $(wildcard conf/*.conf))

ifeq ($(CONFIG),)
  $(error No configuration file found or specified. Usage: make CONFIG=conf/myvm.conf)
endif

# Load config to get HOSTNAME
include $(CONFIG)

# Build directories
BUILD_BASE ?= build
BUILD_DIR  := $(BUILD_BASE)/$(HOSTNAME)
SYSTEMROOT := $(BUILD_DIR)/systemroot
IMAGES_DIR := $(BUILD_DIR)/images
VMWARE_DIR := $(BUILD_DIR)/vmware
LIB_DIR    := lib
CONFIG_CACHE := $(BUILD_DIR)/.config.cache

# Output artifacts
SYSTEMROOT_RAW := $(IMAGES_DIR)/systemroot.raw
SWAP_RAW       := $(IMAGES_DIR)/swap.raw
DATA_RAW       := $(IMAGES_DIR)/data.raw
OVA            := $(VMWARE_DIR)/$(HOSTNAME).ova

# Lib script shortcuts (for dependency tracking)
LIB_10 := $(LIB_DIR)/10-systemroot.sh
LIB_20 := $(LIB_DIR)/20-userconfig.sh
LIB_30 := $(LIB_DIR)/30-systemconfig.sh
LIB_35 := $(LIB_DIR)/35-repositories.sh
LIB_40 := $(LIB_DIR)/40-packages.sh
LIB_50 := $(LIB_DIR)/50-configure.sh
LIB_60 := $(LIB_DIR)/60-bootable.sh
LIB_70 := $(LIB_DIR)/70-create-systemroot-image.sh
LIB_72 := $(LIB_DIR)/72-create-data-image.sh
LIB_80 := $(LIB_DIR)/80-create-ova.sh
LIB_90 := $(LIB_DIR)/90-test-vm.sh
LIB_CFGCHECK := $(LIB_DIR)/00-config-check.sh

# Phony targets
.PHONY: all clean dataclean distclean systemroot userconfig systemconfig \
        packages configure bootable images vmware test help all-configs clean-all

all: images

# Iterate over all .conf files in conf/ directory
all-configs:
	@for conf in conf/*.conf; do \
	  $(MAKE) images CONFIG=$$conf || exit 1; \
	done

help:
	@echo "VM Image Builder (Smart Dependency Mode)"
	@echo "Config: $(CONFIG) -> $(HOSTNAME)"
	@echo "Build Dir: $(BUILD_DIR)"

# --- Smart Config Change Detection ---

$(CONFIG_CACHE): $(CONFIG) $(LIB_CFGCHECK)
	@mkdir -p $(BUILD_DIR)
	@if [ -f $@ ]; then \
	  echo "Config changed. Analyzing impact..."; \
	  $(LIB_CFGCHECK) "$(CONFIG)" "$(BUILD_DIR)"; \
	fi
	@cp "$(CONFIG)" "$@"

# --- Build Stages ---

# Stage 1: systemroot (debootstrap)
$(SYSTEMROOT)/bin/bash: $(CONFIG_CACHE) $(LIB_10)
	@echo "=== Stage: systemroot ==="
	$(LIB_10) "$(CONFIG)" "$(BUILD_DIR)"
	@touch $@

systemroot: $(SYSTEMROOT)/bin/bash

# Stage 2: userconfig (user, SSH)
$(SYSTEMROOT)/home/$(PRIMARY_USER)/.ssh/authorized_keys: \
		$(SYSTEMROOT)/bin/bash $(CONFIG_CACHE) $(LIB_20)
	@echo "=== Stage: userconfig ==="
	$(LIB_20) "$(CONFIG)" "$(BUILD_DIR)"
	@touch $@

userconfig: $(SYSTEMROOT)/home/$(PRIMARY_USER)/.ssh/authorized_keys

# Stage 3: systemconfig (network, sync unit)
$(SYSTEMROOT)/etc/systemd/network/10-eth0.link: \
		$(SYSTEMROOT)/home/$(PRIMARY_USER)/.ssh/authorized_keys \
		$(CONFIG_CACHE) $(LIB_30)
	@echo "=== Stage: systemconfig ==="
	$(LIB_30) "$(CONFIG)" "$(BUILD_DIR)"
	@touch $@

systemconfig: $(SYSTEMROOT)/etc/systemd/network/10-eth0.link

# Stage 3.5: repositories
$(SYSTEMROOT)/.stage_repositories: \
		$(SYSTEMROOT)/etc/systemd/network/10-eth0.link \
		$(CONFIG_CACHE) $(LIB_35)
	@echo "=== Stage: repositories ==="
	$(LIB_35) "$(CONFIG)" "$(BUILD_DIR)"
	@touch $@

# Stage 4: packages (kernel, extras)
$(SYSTEMROOT)/.stage_packages: \
		$(SYSTEMROOT)/.stage_repositories \
		$(CONFIG_CACHE) $(LIB_40)
	@echo "=== Stage: packages ==="
	$(LIB_40) "$(CONFIG)" "$(BUILD_DIR)"
	@touch $@

packages: $(SYSTEMROOT)/.stage_packages

# Stage 5: configure (git etc.)
$(SYSTEMROOT)/.stage_configure: \
		$(SYSTEMROOT)/.stage_packages \
		$(CONFIG_CACHE) $(LIB_50)
	@echo "=== Stage: configure ==="
	$(LIB_50) "$(CONFIG)" "$(BUILD_DIR)"
	@touch $@

configure: $(SYSTEMROOT)/.stage_configure

# Stage 6: bootable (files only, no grub-install)
$(SYSTEMROOT)/.stage_bootable: \
		$(SYSTEMROOT)/.stage_configure \
		$(CONFIG_CACHE) $(LIB_60)
	@echo "=== Stage: bootable ==="
	$(LIB_60) "$(CONFIG)" "$(BUILD_DIR)"
	@touch $@

bootable: $(SYSTEMROOT)/.stage_bootable

# Images: systemroot.raw, swap.raw, data.raw
images: $(SYSTEMROOT_RAW) $(SWAP_RAW) $(DATA_RAW)

$(SYSTEMROOT_RAW): $(SYSTEMROOT)/.stage_bootable $(CONFIG_CACHE) $(LIB_70)
	@echo "=== Creating systemroot.raw (and swap.raw) ==="
	mkdir -p $(IMAGES_DIR)
	$(LIB_70) "$(CONFIG)" "$(BUILD_DIR)"

# swap.raw is created as a side-effect of 70-create-systemroot-image.sh
$(SWAP_RAW): $(SYSTEMROOT_RAW)
	@true
$(DATA_RAW): $(CONFIG_CACHE) $(LIB_72)
	@echo "=== Creating data.raw (if missing) ==="
	mkdir -p $(IMAGES_DIR)
	if [ ! -f "$(DATA_RAW)" ]; then \
	  $(LIB_72) "$(CONFIG)" "$(BUILD_DIR)"; \
	fi
	
# VMware: OVA
vmware: $(OVA)

$(OVA): $(SYSTEMROOT_RAW) $(SWAP_RAW) $(DATA_RAW) $(CONFIG_CACHE) $(LIB_80)
	@echo "=== Creating OVA ==="
	mkdir -p $(VMWARE_DIR)
	$(LIB_80) "$(CONFIG)" "$(BUILD_DIR)"

# Test in KVM/libvirt
test: $(SYSTEMROOT_RAW) $(SWAP_RAW) $(DATA_RAW) $(LIB_90)
	@echo "=== Testing VM ==="
	$(LIB_90) "$(CONFIG)" "$(BUILD_DIR)"

# Cleaning
clean:
	rm -rf $(BUILD_DIR)/systemroot
	rm -f $(SYSTEMROOT_RAW) $(SWAP_RAW)
	rm -f $(OVA) $(VMWARE_DIR)/*.vmdk
	rm -f $(CONFIG_CACHE)

dataclean:
	rm -f $(DATA_RAW)

distclean:
	rm -rf $(BUILD_DIR)

clean-all:
	rm -rf $(BUILD_BASE)
