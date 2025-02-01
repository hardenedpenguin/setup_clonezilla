#!/bin/sh
#
# Download and setup Clonezilla, then install a backup if requested.
# Copyright (C) 2025 Jory A. Pratt - W5GLE
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/gpl-2.0.html>.

set -e  # Exit on any error

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

# Dependencies check
for cmd in parted unzip curl lsblk blkid mkfs.vfat shred; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: $cmd is not installed. Please install it using: apt-get install $cmd"
        exit 1
    fi
done

# Variables
CLONEZILLA_URL="https://sourceforge.net/projects/clonezilla/files/clonezilla_live_stable/3.2.0-5/clonezilla-live-3.2.0-5-amd64.zip"
ZIP_NAME="clonezilla-live.zip"
MOUNT_POINT="/mnt/usb"
BACKUP_NAME="backup.zip"
CLONEZILLA_PART_SIZE=513M

# Function to check command success
check_success() {
    if [ $? -ne 0 ]; then
        echo "Error: $1"
        exit 1
    fi
}

# Function to clean up before exiting
cleanup() {
    if mount | grep -q "$MOUNT_POINT"; then
        echo "Unmounting $MOUNT_POINT..."
        umount "$MOUNT_POINT" || echo "Warning: Failed to unmount $MOUNT_POINT."
    fi
    if [ -d "$MOUNT_POINT" ]; then
        echo "Removing mount point $MOUNT_POINT..."
        rmdir "$MOUNT_POINT" || echo "Warning: Failed to remove $MOUNT_POINT."
    fi
}

# Function to check internet connectivity
check_internet() {
    echo "Checking internet connectivity..."
    if ! curl -s --head --request GET https://www.google.com | grep "200" >/dev/null; then
        echo "No internet connection detected."
        exit 1
    fi
}

# Ask for USB device
while :; do
    echo "Available block devices:"
    lsblk -d -o NAME,SIZE,TYPE | grep "disk"
    
    echo "Enter the device you want to use (e.g., sdX or mmcblkX):"
    read -r USB_DEVICE
    USB_DEVICE="/dev/$USB_DEVICE"
    
    if [ -b "$USB_DEVICE" ]; then
        break
    else
        echo "$USB_DEVICE is not a valid block device."
    fi
done

# Check USB device size (in bytes)
DEVICE_SIZE=$(lsblk -b -o SIZE -n -d "$USB_DEVICE")

# Check if the device size is at least 8GB (8 * 1024 * 1024 * 1024 bytes)
if [ "$DEVICE_SIZE" -lt $((8 * 1024 * 1024 * 1024)) ]; then
    echo "The device must be at least 8GB."
    exit 1
fi

# Confirm USB wipe
echo "WARNING: This will erase all data on $USB_DEVICE. Continue? (yes/no) [no]:"
read -r CONFIRM
CONFIRM=${CONFIRM:-no}
if [ "$CONFIRM" != "yes" ]; then
    echo "Operation canceled."
    exit 1
fi

# Unmount any existing partitions
umount "$USB_DEVICE"* > /dev/null 2>&1 || true

# Shred the first 1MB of the USB device
echo "Shredding the first 1MB of $USB_DEVICE..."
shred -n 1 -z -s 1M "$USB_DEVICE" || check_success "Failed to shred the device."

# Partition the USB drive
echo "Partitioning the USB drive..."
parted -s "$USB_DEVICE" mklabel gpt || check_success "Failed to create GPT label."
parted -s "$USB_DEVICE" mkpart primary fat32 1MiB "$CLONEZILLA_PART_SIZE" || check_success "Failed to create partition."
parted -s "$USB_DEVICE" mkpart primary fat32 "$CLONEZILLA_PART_SIZE" 100% || check_success "Failed to create second partition."
parted -s "$USB_DEVICE" set 1 boot on || check_success "Failed to set boot flag on first partition."
partprobe "$USB_DEVICE" || check_success "Failed to update partition table."

# Wait for the system to update partition table
sleep 3

# Determine partition names dynamically
PART1=$(lsblk -lnpo NAME,TYPE "$USB_DEVICE" | awk '$2=="part"{print $1}' | sed -n '1p')
PART2=$(lsblk -lnpo NAME,TYPE "$USB_DEVICE" | awk '$2=="part"{print $1}' | sed -n '2p')

if [ -z "$PART1" ] || [ -z "$PART2" ]; then
    echo "Could not determine partition names."
    exit 1
fi

# Create filesystems
mkfs.vfat -F 32 "$PART1" > /dev/null 2>&1 || check_success "Failed to create file system on Clonezilla partition."
mkfs.vfat -F 32 "$PART2" > /dev/null 2>&1 || check_success "Failed to create file system on second partition."

# Create the mount point if it doesn't exist
if [ ! -d "$MOUNT_POINT" ]; then
    echo "Creating mount point $MOUNT_POINT..."
    mkdir -p "$MOUNT_POINT" || check_success "Failed to create mount point."
fi

# Mount Clonezilla partition
mount "$PART1" "$MOUNT_POINT" || check_success "Failed to mount Clonezilla partition."

# Check internet connectivity before downloading
check_internet

# Download and extract Clonezilla
echo "Downloading Clonezilla..."
curl -s -L -o "$ZIP_NAME" "$CLONEZILLA_URL" || check_success "Failed to download Clonezilla."
echo "Extracting Clonezilla..."
unzip "$ZIP_NAME" -d "$MOUNT_POINT" > /dev/null 2>&1 || check_success "Failed to extract Clonezilla zip file."

# Clean up Clonezilla
umount "$MOUNT_POINT" || check_success "Failed to unmount Clonezilla partition."
rm -f "$ZIP_NAME"

# Ask if the user wants to add a backup
echo "Would you like to add a backup from a zip online? (yes/no) [yes]:"
read -r SKIP_BACKUP
SKIP_BACKUP=${SKIP_BACKUP:-yes}

if [ "$SKIP_BACKUP" = "yes" ]; then
    echo "Enter the URL of the backup file to download and extract to the second partition:"
    read -r BACKUP_URL

    mount "$PART2" "$MOUNT_POINT" || check_success "Failed to mount second partition."

    # Download and extract the backup file
    echo "Downloading the backup file..."
    curl -s -L -o "$BACKUP_NAME" "$BACKUP_URL" || check_success "Failed to download the backup file."
    echo "Extracting backup..."
    unzip "$BACKUP_NAME" -d "$MOUNT_POINT" > /dev/null 2>&1 || check_success "Failed to extract the backup file."

    umount "$MOUNT_POINT" || check_success "Failed to unmount backup partition."
    rm -f "$BACKUP_NAME"
fi

echo "Setup completed successfully!"
