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

# Check if the script is being run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

# Variables
CLONEZILLA_URL="https://sourceforge.net/projects/clonezilla/files/clonezilla_live_stable/3.2.0-5/clonezilla-live-3.2.0-5-amd64.zip"  # URL to the Clonezilla zip file
ZIP_NAME="clonezilla-live-3.2.0-5-amd64.zip"
USB_DEVICE=""
MOUNT_POINT=""
CLONEZILLA_PART_SIZE=512M
BACKUP_NAME="backup.zip"

# Function to check command success
check_success() {
    if [ $? -ne 0 ]; then
        echo "Error: $1"
        exit 1
    fi
}

# Ask for USB device and mount point
echo "Enter the USB device (e.g., /dev/sdX):"
read USB_DEVICE
echo "Enter the mount point (e.g., /mnt/usb):"
read MOUNT_POINT

# Validate inputs
if [ ! -b "$USB_DEVICE" ]; then
    echo "Error: $USB_DEVICE is not a valid block device."
    exit 1
fi

if [ ! -d "$MOUNT_POINT" ]; then
    echo "Creating mount point $MOUNT_POINT..."
    mkdir -p "$MOUNT_POINT"
    check_success "Failed to create mount point."
fi

# Confirm the USB device
echo "WARNING: This will erase all data on $USB_DEVICE. Continue? (yes/no)"
read CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Operation canceled."
    exit 1
fi

# Partition the USB drive
echo "Partitioning the USB drive..."
parted "$USB_DEVICE" mklabel gpt || check_success "Failed to create GPT label."
parted "$USB_DEVICE" mkpart primary fat32 1MiB "$CLONEZILLA_PART_SIZE" || check_success "Failed to create Clonezilla partition."
parted "$USB_DEVICE" mkpart primary fat32 "$CLONEZILLA_PART_SIZE" 100% || check_success "Failed to create second FAT32 partition."

# Inform the system to re-read the partition table
partprobe "$USB_DEVICE" || check_success "Failed to update partition table."

# Create filesystems
echo "Creating file system on the Clonezilla partition (FAT32)..."
mkfs.vfat -F 32 "${USB_DEVICE}1" > /dev/null 2>&1 || check_success "Failed to create file system on Clonezilla partition."
echo "Creating file system on the second partition (FAT32)..."
mkfs.vfat -F 32 "${USB_DEVICE}2" > /dev/null 2>&1 || check_success "Failed to create file system on second partition."

# Mount the partitions for Clonezilla
echo "Mounting $USB_DEVICE..."
mount "${USB_DEVICE}1" "$MOUNT_POINT" || check_success "Failed to mount the first partition."

# Download Clonezilla Zip file
echo "Downloading Clonezilla Zip file..."
wget -O "$ZIP_NAME" "$CLONEZILLA_URL" > /dev/null 2>&1 || curl -s -o "$ZIP_NAME" "$CLONEZILLA_URL"
check_success "Failed to download Clonezilla."

# Extract Clonezilla Zip file to the first partition
echo "Extracting Clonezilla Zip file to the first partition..."
unzip "$ZIP_NAME" -d "$MOUNT_POINT" > /dev/null 2>&1 || check_success "Failed to extract Clonezilla zip file."

# Clean up and unmount Clonezilla partition
echo "Unmounting Clonezilla partition..."
umount "$MOUNT_POINT" || check_success "Failed to unmount the first partition."
rm -f "$ZIP_NAME"

# Ask if the user wants to skip the backup process
echo "Do you want to skip the backup process? (yes/no)"
read SKIP_BACKUP

if [ "$SKIP_BACKUP" != "yes" ]; then
    # Ask for backup file URL and name
    echo "Enter the URL of the backup file to download and extract to the second partition:"
    read BACKUP_URL

    # Mount the second partition
    echo "Mounting the second partition..."
    mount "${USB_DEVICE}2" "$MOUNT_POINT" || check_success "Failed to mount the second partition."

    # Download and extract the backup file
    echo "Downloading the backup file..."
    wget -O "$BACKUP_NAME" "$BACKUP_URL" > /dev/null 2>&1 || curl -s -o "$BACKUP_NAME" "$BACKUP_URL"
    check_success "Failed to download the backup file."

    echo "Extracting the backup file to the second partition..."
    unzip "$BACKUP_NAME" -d "$MOUNT_POINT" > /dev/null 2>&1 || check_success "Failed to extract the backup file."

    # Clean up and unmount second partition
    echo "Unmounting the second partition..."
    umount "$MOUNT_POINT" || check_success "Failed to unmount the second partition."
    rm -f "$BACKUP_NAME"
else
    echo "Skipping the backup process as per user request."
fi

echo "Setup completed successfully!"
