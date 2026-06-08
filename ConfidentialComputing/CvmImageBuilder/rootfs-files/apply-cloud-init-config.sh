#!/bin/bash
#
# Copyright (c) Microsoft Corporation. All rights reserved.
#
# Description:
# This script checks for cloud-init configuration on a mounted disk
# and copies it to the EFI system partition for persistent use across reboots.
#

# Ensure log directory exists (may not exist early in boot)
mkdir -p /var/log

LOGFILE="/var/log/apply-cloud-init-config.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "=== $(date) - Starting cloud-init config application ==="

set -e

EFI_MOUNT="/run/efi"
CLOUD_INIT_EFI="$EFI_MOUNT/EFI/cloud-init"
CLOUD_INIT_SEED="/var/lib/cloud/seed/nocloud-net"
CLOUD_INIT_MOUNT="/run/cloud-init-source"

echo "Looking for cloud-init source device..."

# Start by mounting the EFI partition - we will either copy the cloud-init config there
# or read existing config from there so it must always be mounted.
EFI_PARTITION=$(blkid -t TYPE=vfat -o device 2>/dev/null | head -1)
if [[ -n "$EFI_PARTITION" ]]; then
    echo "Mounting EFI partition: $EFI_PARTITION at $EFI_MOUNT"
    mkdir -p "$EFI_MOUNT"
    if mount "$EFI_PARTITION" "$EFI_MOUNT" 2>&1; then
        echo "Successfully mounted EFI partition"
    else
        echo "Failed to mount EFI partition"
        exit 0
    fi
else
    echo "No EFI partition found"
    exit 0
fi

# Check for devices with CIDATA label. If this is the first boot then this should be present
# and contain the cloud-init configuration files.
for device in $(blkid -t LABEL=CIDATA -o device 2>/dev/null) $(blkid -t LABEL=cidata -o device 2>/dev/null); do
    if [[ -b "$device" ]]; then
        echo "Found cloud-init device with CIDATA label: $device (first boot). Copying cloud-init config to EFI system partition"

        mkdir -p "$CLOUD_INIT_MOUNT"
        if ! mount -o ro "$device" "$CLOUD_INIT_MOUNT" 2>&1; then
            echo "Failed to mount cloud-init device"
            umount "$EFI_MOUNT" 2>&1 || true
            exit 1
        fi

        echo "Copying configs from source to EFI system partition"
        # Copy meta-data and network-config (user-data blocked for security)
        if [[ -f "$CLOUD_INIT_MOUNT"/meta-data ]] && mountpoint -q "$EFI_MOUNT"; then
            echo "Copying cloud-init configs to EFI partition"
            mkdir -p "$CLOUD_INIT_EFI"
            cp "$CLOUD_INIT_MOUNT"/meta-data "$CLOUD_INIT_EFI/" 2>&1 || true
            cp "$CLOUD_INIT_MOUNT"/network-config "$CLOUD_INIT_EFI/" 2>&1 || true
            sync
            echo "Cloud-init configuration copied to EFI partition"
        fi

        umount "$CLOUD_INIT_MOUNT" 2>&1 || echo "Failed to unmount cloud-init source"
        break
    fi
done

# Here, we should have a mounted EFI partition that may contain cloud-init configs.
# Copy these files if found to the cloud-init seed directory.
echo "Attempting to apply cloud-init config from EFI partition to seed directory"
if [[ -d "$CLOUD_INIT_EFI" ]]; then
    EFI_CONFIG_FILES=$(ls "$CLOUD_INIT_EFI"/meta-data 2>/dev/null || true)
    if [[ -n "$EFI_CONFIG_FILES" ]]; then
        echo "Found cloud-init configs on EFI, copying to seed directory"
        
        # Clear old cloud-init state to force re-run
        rm -rf /var/lib/cloud/instances /var/lib/cloud/instance
        
        # Copy configs to cloud-init seed directory
        mkdir -p "$CLOUD_INIT_SEED"
        cp "$CLOUD_INIT_EFI"/meta-data "$CLOUD_INIT_SEED/" 2>&1 || true
        cp "$CLOUD_INIT_EFI"/network-config "$CLOUD_INIT_SEED/" 2>&1 || true
        # Create an empty user-data. Do not attempt to copy one from the EFI
        # system partition as that is not a trusted location.
        echo "#cloud-config" > "$CLOUD_INIT_SEED/user-data"
        
        # Enable cloud-init
        rm -f /etc/cloud/cloud-init.disabled
        touch /run/cloud-init-enabled
        
        echo "Cloud-init configuration applied and enabled"
    else
        echo "No cloud-init config files found on EFI partition"
    fi
else
    echo "cloud-init directory does not exist on EFI system partition"
fi

echo "Unmounting EFI partition"
umount "$EFI_MOUNT" 2>&1 || echo "Failed to unmount EFI partition"

# Eject and remove all CD/DVD devices to ensure no CDs remain attached
echo "Ejecting and removing all CD/DVD devices..."
for sr_dev in /sys/block/sr*; do
    [[ -e "$sr_dev" ]] || continue
    DEVICE_NAME=$(basename "$sr_dev")
    echo "Ejecting /dev/$DEVICE_NAME"
    eject "/dev/$DEVICE_NAME" 2>&1 || echo "Failed to eject /dev/$DEVICE_NAME"
    if [[ -e "$sr_dev/device/delete" ]]; then
        echo "Removing /dev/$DEVICE_NAME from system"
        echo 1 > "$sr_dev/device/delete" 2>&1 || echo "Could not delete /dev/$DEVICE_NAME"
    fi
done

echo "=== Finished cloud-init config application ==="
