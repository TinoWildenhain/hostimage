#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_FILE=${1:? "Usage: $0 config.conf build_dir"}
BUILD_DIR=${2:? "build_dir required"}

require_file "${CONFIG_FILE}"
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

IMAGES_DIR="${BUILD_DIR}/images"
VMWARE_DIR="${BUILD_DIR}/vmware"
mkdir -p "${VMWARE_DIR}"

SYSTEM_RAW="${IMAGES_DIR}/systemroot.raw"
SWAP_RAW="${IMAGES_DIR}/swap.raw"
DATA_RAW="${IMAGES_DIR}/data.raw"

# Helper function to convert only if needed
convert_if_newer() {
    local src="$1"
    local dst="$2"
    if [ ! -f "${dst}" ] || [ "${src}" -nt "${dst}" ]; then
        log "Converting ${src} to ${dst}"
        qemu-img convert -f raw -O vmdk -o subformat=streamOptimized "${src}" "${dst}"
    else
        log "Skipping conversion: ${dst} is up to date"
    fi
}


require_file "${SYSTEM_RAW}"
require_file "${SWAP_RAW}"

IMAGE_VERSION_STAMP="${BUILD_DIR}/.image_version"

HAVE_DATA_FOR_EXPORT=0
if [ -f "${IMAGE_VERSION_STAMP}" ] && [ -f "${DATA_RAW}" ]; then
    HAVE_DATA_FOR_EXPORT=1
fi

log "Converting system and swap disks to VMDK"
SYSTEM_VMDK="${VMWARE_DIR}/system-root.vmdk"
SWAP_VMDK="${VMWARE_DIR}/swap.vmdk"

convert_if_newer "${SYSTEM_RAW}" "${SYSTEM_VMDK}"
convert_if_newer "${SWAP_RAW}" "${SWAP_VMDK}"

DATA_VMDK="${VMWARE_DIR}/data-persistent.vmdk"
if [ "${HAVE_DATA_FOR_EXPORT}" -eq 1 ]; then
    log "Fresh data disk in this build, converting data.raw to VMDK"
    convert_if_newer "${DATA_RAW}" "${DATA_VMDK}"
else
    log "No fresh data disk in this build; skipping data-persistent.vmdk export"
fi

SYSTEM_SIZE=$(stat -c%s "${SYSTEM_VMDK}")
SWAP_SIZE=$(stat -c%s "${SWAP_VMDK}")
if [ "${HAVE_DATA_FOR_EXPORT}" -eq 1 ]; then
    DATA_SIZE=$(stat -c%s "${DATA_VMDK}")
fi

NET_NAME_EFFECTIVE="${NET_NAME:-${HOSTNAME}-net}"

# OVF generation (now with VMware EFI firmware hints)
OVF_PATH="${VMWARE_DIR}/${HOSTNAME}.ovf"

cat > "${OVF_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1"
          xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"
          xmlns:cim="http://schemas.dmtf.org/wbem/wscim/1/common"
          xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData"
          xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData"
          xmlns:vmw="http://www.vmware.com/schema/ovf">
  <References>
    <File ovf:href="system-root.vmdk"     ovf:id="file-system" ovf:size="${SYSTEM_SIZE}"/>
    <File ovf:href="swap.vmdk"            ovf:id="file-swap"   ovf:size="${SWAP_SIZE}"/>
EOF

if [ "${HAVE_DATA_FOR_EXPORT}" -eq 1 ]; then
cat >> "${OVF_PATH}" <<EOF
    <File ovf:href="data-persistent.vmdk" ovf:id="file-data"   ovf:size="${DATA_SIZE}"/>
EOF
fi

cat >> "${OVF_PATH}" <<EOF
  </References>

  <NetworkSection>
    <Info>Network information</Info>
    <Network ovf:name="${HOSTNAME}-net">
      <Description>Suggested network for ${HOSTNAME}</Description>
    </Network>
  </NetworkSection>

  <DiskSection>
    <Info>Virtual disk information</Info>
    <Disk ovf:diskId="disk-system" ovf:fileRef="file-system"
          ovf:capacity="${DISK_SIZE_GB}" ovf:capacityAllocationUnits="byte * 2^30"
          ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"/>
    <Disk ovf:diskId="disk-swap" ovf:fileRef="file-swap"
          ovf:capacity="${LV_SWAP_SIZE_GB}" ovf:capacityAllocationUnits="byte * 2^30"
          ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"/>
EOF

if [ "${HAVE_DATA_FOR_EXPORT}" -eq 1 ]; then
cat >> "${OVF_PATH}" <<EOF
    <Disk ovf:diskId="disk-data" ovf:fileRef="file-data"
          ovf:capacity="${DATA_DISK_SIZE_GB}" ovf:capacityAllocationUnits="byte * 2^30"
          ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"/>
EOF
fi

cat >> "${OVF_PATH}" <<EOF
  </DiskSection>

  <VirtualSystem ovf:id="vm">
    <Info>Virtual machine</Info>
    <Name>${HOSTNAME}</Name>

    <OperatingSystemSection ovf:id="94" vmw:osType="ubuntu64Guest">
      <Info>The kind of installed guest operating system</Info>
      <Description>Ubuntu Linux (64-bit)</Description>
    </OperatingSystemSection>


    <VirtualHardwareSection>
      <Info>Virtual hardware</Info>
      <System>
        <vssd:ElementName>Virtual Hardware Family</vssd:ElementName>
        <vssd:InstanceID>0</vssd:InstanceID>
        <vssd:VirtualSystemIdentifier>${HOSTNAME}</vssd:VirtualSystemIdentifier>
        <vssd:VirtualSystemType>vmx-13</vssd:VirtualSystemType>
      </System>

      <!-- SCSI controller -->
      <Item>
        <rasd:Address>0</rasd:Address>
        <rasd:Description>SCSI Controller</rasd:Description>
        <rasd:ElementName>SCSI Controller 0</rasd:ElementName>
        <rasd:InstanceID>3</rasd:InstanceID>
        <rasd:ResourceSubType>lsilogic</rasd:ResourceSubType>
        <rasd:ResourceType>6</rasd:ResourceType>
      </Item>

      <!-- System root disk -->
      <Item>
        <rasd:AddressOnParent>0</rasd:AddressOnParent>
        <rasd:Description>System root disk</rasd:Description>
        <rasd:ElementName>System root disk</rasd:ElementName>
        <rasd:HostResource>ovf:/disk/disk-system</rasd:HostResource>
        <rasd:InstanceID>4</rasd:InstanceID>
        <rasd:Parent>3</rasd:Parent>
        <rasd:ResourceType>17</rasd:ResourceType>
      </Item>

      <!-- Swap disk -->
      <Item>
        <rasd:AddressOnParent>1</rasd:AddressOnParent>
        <rasd:Description>Swap disk</rasd:Description>
        <rasd:ElementName>Swap disk</rasd:ElementName>
        <rasd:HostResource>ovf:/disk/disk-swap</rasd:HostResource>
        <rasd:InstanceID>5</rasd:InstanceID>
        <rasd:Parent>3</rasd:Parent>
        <rasd:ResourceType>17</rasd:ResourceType>
      </Item>
EOF

if [ "${HAVE_DATA_FOR_EXPORT}" -eq 1 ]; then
cat >> "${OVF_PATH}" <<EOF
      <!-- Persistent data disk -->
      <Item>
        <rasd:AddressOnParent>2</rasd:AddressOnParent>
        <rasd:Description>Persistent data disk</rasd:Description>
        <rasd:ElementName>Data disk (persistent)</rasd:ElementName>
        <rasd:HostResource>ovf:/disk/disk-data</rasd:HostResource>
        <rasd:InstanceID>6</rasd:InstanceID>
        <rasd:Parent>3</rasd:Parent>
        <rasd:ResourceType>17</rasd:ResourceType>
      </Item>
EOF
fi

cat >> "${OVF_PATH}" <<EOF
      <!-- Network adapter -->
      <Item>
        <rasd:AddressOnParent>7</rasd:AddressOnParent>
        <rasd:AutomaticAllocation>true</rasd:AutomaticAllocation>
        <rasd:Description>VmxNet3 ethernet adapter</rasd:Description>
        <rasd:ElementName>Network adapter 1</rasd:ElementName>
        <rasd:InstanceID>7</rasd:InstanceID>
        <rasd:ResourceSubType>VmxNet3</rasd:ResourceSubType>
        <rasd:ResourceType>10</rasd:ResourceType>
        <rasd:Connection>${NET_NAME_EFFECTIVE}</rasd:Connection>
      </Item>

      <!-- CPU -->
      <Item>
        <rasd:Description>Number of virtual CPUs</rasd:Description>
        <rasd:ElementName>${VCPUS} virtual CPU(s)</rasd:ElementName>
        <rasd:InstanceID>8</rasd:InstanceID>
        <rasd:ResourceType>3</rasd:ResourceType>
        <rasd:VirtualQuantity>${VCPUS}</rasd:VirtualQuantity>
      </Item>

      <!-- Memory -->
      <Item>
        <rasd:Description>Memory Size</rasd:Description>
        <rasd:ElementName>${MEM_MB} MB of memory</rasd:ElementName>
        <rasd:InstanceID>9</rasd:InstanceID>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:VirtualQuantity>${MEM_MB}</rasd:VirtualQuantity>
      </Item>

      <!-- VMware-specific firmware config -->
      <vmw:ExtraConfig ovf:required="false" vmw:key="firmware" vmw:value="efi"/>
      <vmw:ExtraConfig ovf:required="false" vmw:key="secureBoot.enabled" vmw:value="false"/>

    </VirtualHardwareSection>
  </VirtualSystem>
</Envelope>
EOF

log "Creating OVA archive"
cd "${VMWARE_DIR}"

OVA_FILES=("${HOSTNAME}.ovf" "system-root.vmdk" "swap.vmdk")
if [ "${HAVE_DATA_FOR_EXPORT}" -eq 1 ]; then
    OVA_FILES+=("data-persistent.vmdk")
fi

tar -cf "${HOSTNAME}.ova" "${OVA_FILES[@]}"
log "OVA created: ${VMWARE_DIR}/${HOSTNAME}.ova"

# Clear build-local image-version marker so subsequent 'make ova'
# without a fresh image build will not re-export the data disk
rm -f "${IMAGE_VERSION_STAMP}"