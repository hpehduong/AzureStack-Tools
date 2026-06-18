#!/bin/bash
#
# Copyright (c) Microsoft Corporation. All rights reserved.
#
# Description:
# Script to set up an overlay filesystem for /etc to allow runtime modifications
# 
set -e

# Load overlay module
modprobe overlay

# Create tmpfs for overlay
mkdir -p /run/etc-overlay
mount -t tmpfs -o size=128M tmpfs /run/etc-overlay
mkdir -p /run/etc-overlay/upper /run/etc-overlay/work

# Mount overlay over /etc
mount -t overlay overlay \
    -o lowerdir=/etc,upperdir=/run/etc-overlay/upper,workdir=/run/etc-overlay/work \
    /etc

# Copy seed files from rootfs-overlay's /etc into the runtime overlay
if [[ -d /usr/local/etc-overlay-seed ]]; then
    echo "Copying /etc overlay seed files..."
    cp -a /usr/local/etc-overlay-seed/* /etc/ 2>/dev/null || true
fi

echo "/etc overlay configured successfully"
