#!/bin/bash
#
# Download and setup Clonezilla, then install a backup if requested.
# Copyright (C) 2025 Jory A. Pratt - W5GLE
# Enhanced version with improved robustness and error handling
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

# Configuration
set -euo pipefail  # Exit on error, undefined vars, pipe failures
IFS=$'\n\t'        # Internal field separator

# Script configuration
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOG_FILE="/tmp/${SCRIPT_NAME}.log"
LOCK_FILE="/tmp/${SCRIPT_NAME}.lock"

# Variables
CLONEZILLA_URL="https://sourceforge.net/projects/clonezilla/files/clonezilla_live_stable/3.2.0-5/clonezilla-live-3.2.0-5-amd64.zip"
ZIP_NAME="clonezilla-live.zip"
MOUNT_POINT="/mnt/usb"
BACKUP_NAME="backup.zip"
CLONEZILLA_PART_SIZE=513M
MIN_DEVICE_SIZE=$((8 * 1024 * 1024 * 1024))  # 8GB in bytes
MAX_RETRIES=3
DOWNLOAD_TIMEOUT=300  # 5 minutes

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

# Global variables
USB_DEVICE=""
PART1=""
PART2=""
VERBOSE=false
DRY_RUN=false
BACKUP_ONLY=false

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Function to ensure mount point exists
ensure_mount_point() {
    if [ ! -d "$MOUNT_POINT" ]; then
        print_status "INFO" "Creating mount point $MOUNT_POINT..."
        mkdir -p "$MOUNT_POINT" || {
            print_status "ERROR" "Failed to create mount point $MOUNT_POINT"
            return 1
        }
    fi
}

# Function to cleanup mount point
cleanup_mount_point() {
    if [ -d "$MOUNT_POINT" ]; then
        print_status "INFO" "Removing mount point $MOUNT_POINT..."
        rmdir "$MOUNT_POINT" 2>/dev/null || print_status "WARNING" "Failed to remove $MOUNT_POINT"
    fi
}

# Function to print colored output
print_status() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        "INFO")
            echo -e "${BLUE}[INFO]${NC} $message"
            ;;
        "SUCCESS")
            echo -e "${GREEN}[SUCCESS]${NC} $message"
            ;;
        "WARNING")
            echo -e "${YELLOW}[WARNING]${NC} $message"
            ;;
        "ERROR")
            echo -e "${RED}[ERROR]${NC} $message"
            ;;
    esac
    
    # Log to file
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

# Function to log verbose messages
log_verbose() {
    if [ "$VERBOSE" = true ]; then
        print_status "INFO" "$1"
    fi
}

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

# Function to check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_status "ERROR" "This script must be run as root."
        exit 1
    fi
}

# Function to check dependencies
check_dependencies() {
    local missing_deps=()
    local required_cmds=("parted" "unzip" "curl" "lsblk" "blkid" "mkfs.vfat" "shred" "wget")
    
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        print_status "ERROR" "Missing dependencies: ${missing_deps[*]}"
        print_status "INFO" "Install them using: apt-get install parted unzip curl util-linux dosfstools secure-delete wget"
        exit 1
    fi
}

# Function to check internet connectivity with retry
check_internet() {
    print_status "INFO" "Checking internet connectivity..."
    
    for i in $(seq 1 $MAX_RETRIES); do
        if curl -s --max-time 10 --head --request GET https://www.google.com | grep -q "200"; then
            print_status "SUCCESS" "Internet connection verified"
            return 0
        fi
        
        if [ $i -lt $MAX_RETRIES ]; then
            print_status "WARNING" "Internet check failed, retrying in 3 seconds... (attempt $i/$MAX_RETRIES)"
            sleep 3
        fi
    done
    
    print_status "ERROR" "No internet connection detected after $MAX_RETRIES attempts"
    return 1
}

# =============================================================================
# LOCK FILE MANAGEMENT
# =============================================================================

# Function to create lock file
create_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            print_status "ERROR" "Another instance is already running (PID: $pid)"
            exit 1
        else
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

# Function to remove lock file
remove_lock() {
    rm -f "$LOCK_FILE"
}

# =============================================================================
# SIGNAL HANDLING AND CLEANUP
# =============================================================================

# Function to setup signal handlers
setup_signal_handlers() {
    trap 'cleanup_and_exit 1' INT TERM
    trap 'cleanup_and_exit 0' EXIT
}

# Function to cleanup and exit
cleanup_and_exit() {
    local exit_code=$1
    print_status "INFO" "Cleaning up..."
    
    # Unmount any mounted partitions
    if mount | grep -q "$MOUNT_POINT"; then
        print_status "INFO" "Unmounting $MOUNT_POINT..."
        umount "$MOUNT_POINT" 2>/dev/null || print_status "WARNING" "Failed to unmount $MOUNT_POINT"
    fi
    
    # Clean up mount point
    cleanup_mount_point
    
    # Clean up temporary files
    rm -f "$ZIP_NAME" "$BACKUP_NAME"
    
    # Remove lock file
    remove_lock
    
    if [ $exit_code -eq 0 ]; then
        print_status "SUCCESS" "Setup completed successfully!"
    else
        print_status "ERROR" "Setup failed with exit code $exit_code"
    fi
    
    exit $exit_code
}

# =============================================================================
# NETWORK OPERATIONS
# =============================================================================

# Function to download file with progress and retry
download_file() {
    local url="$1"
    local output="$2"
    local description="$3"
    
    print_status "INFO" "Downloading $description..."
    
    for i in $(seq 1 $MAX_RETRIES); do
        if curl -L -o "$output" --progress-bar --max-time $DOWNLOAD_TIMEOUT "$url"; then
            print_status "SUCCESS" "$description downloaded successfully"
            return 0
        fi
        
        if [ $i -lt $MAX_RETRIES ]; then
            print_status "WARNING" "Download failed, retrying in 5 seconds... (attempt $i/$MAX_RETRIES)"
            sleep 5
        fi
    done
    
    print_status "ERROR" "Failed to download $description after $MAX_RETRIES attempts"
    return 1
}

# =============================================================================
# DEVICE MANAGEMENT
# =============================================================================

# Function to detect existing Clonezilla drive
detect_clonezilla_drive() {
    local device="$1"
    
    # Check if device exists and is a block device
    if [ ! -b "$device" ]; then
        print_status "ERROR" "Device $device does not exist or is not a block device"
        return 1
    fi
    
    # Get partition names
    local partitions
    partitions=$(lsblk -lnpo NAME,TYPE "$device" | awk '$2=="part"{print $1}')
    
    if [ -z "$partitions" ]; then
        print_status "ERROR" "No partitions found on device $device"
        return 1
    fi
    
    # Check if it has at least 2 partitions
    local partition_count=$(echo "$partitions" | wc -l)
    if [ "$partition_count" -lt 2 ]; then
        print_status "ERROR" "Device $device does not have enough partitions (found $partition_count, need at least 2)"
        return 1
    fi
    
    # Get the second partition (backup partition)
    PART2=$(echo "$partitions" | sed -n '2p')
    
    # Check if second partition is FAT32
    local fs_type
    fs_type=$(blkid -s TYPE -o value "$PART2" 2>/dev/null || echo "")
    
    if [ "$fs_type" != "vfat" ] && [ "$fs_type" != "fat32" ]; then
        print_status "ERROR" "Second partition on $device is not FAT32 (found: $fs_type)"
        return 1
    fi
    
    # Get device info
    local device_info
    device_info=$(lsblk -d -o NAME,SIZE,MODEL,VENDOR "$device" 2>/dev/null || echo "Unknown")
    
    print_status "INFO" "Detected Clonezilla drive: $device"
    print_status "INFO" "Device info: $device_info"
    print_status "INFO" "Backup partition: $PART2"
    
    return 0
}

# Function to safely get device information
get_device_info() {
    local device="$1"
    
    # Check if device exists and is a block device
    if [ ! -b "$device" ]; then
        print_status "ERROR" "Device $device does not exist or is not a block device"
        return 1
    fi
    
    # Check if device is mounted
    if mount | grep -q "$device"; then
        print_status "ERROR" "Device $device is currently mounted. Please unmount it first."
        return 1
    fi
    
    # Get device size
    local device_size
    device_size=$(lsblk -b -o SIZE -n -d "$device" 2>/dev/null || echo "0")
    
    if [ "$device_size" -lt $MIN_DEVICE_SIZE ]; then
        print_status "ERROR" "Device $device is too small. Minimum size required: 8GB"
        return 1
    fi
    
    # Get device model and vendor
    local device_info
    device_info=$(lsblk -d -o NAME,SIZE,MODEL,VENDOR "$device" 2>/dev/null || echo "Unknown")
    
    print_status "INFO" "Selected device: $device"
    print_status "INFO" "Device info: $device_info"
    
    return 0
}

# Function to list available devices
list_devices() {
    print_status "INFO" "Available block devices:"
    echo
    lsblk -d -o NAME,SIZE,TYPE,MODEL | grep "disk" | while read -r line; do
        echo "  $line"
    done
    echo
}

# Function to get user device selection
get_device_selection() {
    while true; do
        list_devices
        
        if [ "$BACKUP_ONLY" = true ]; then
            echo -n "Enter the existing Clonezilla USB device (e.g., sda, sdb, mmcblk0): "
        else
            echo -n "Enter the device you want to use (e.g., sda, sdb, mmcblk0): "
        fi
        read -r device_input
        
        # Remove /dev/ prefix if user included it
        device_input=${device_input#/dev/}
        USB_DEVICE="/dev/$device_input"
        
        if [ "$BACKUP_ONLY" = true ]; then
            if detect_clonezilla_drive "$USB_DEVICE"; then
                break
            fi
        else
            if get_device_info "$USB_DEVICE"; then
                break
            fi
        fi
        
        echo
        print_status "WARNING" "Please select a valid device"
        echo
    done
}

# Function to confirm device wipe
confirm_device_wipe() {
    echo
    print_status "WARNING" "This operation will ERASE ALL DATA on $USB_DEVICE"
    print_status "WARNING" "This action cannot be undone!"
    echo
    
    echo -n "Type 'YES' (in uppercase) to confirm: "
    read -r confirm
    
    if [ "$confirm" != "YES" ]; then
        print_status "INFO" "Operation canceled by user"
        exit 0
    fi
}

# =============================================================================
# PARTITIONING AND FILESYSTEM OPERATIONS
# =============================================================================

# Function to safely partition device
partition_device() {
    print_status "INFO" "Partitioning $USB_DEVICE..."
    
    # Unmount any existing partitions
    umount "$USB_DEVICE"* 2>/dev/null || true
    
    # Shred the first 1MB of the device
    print_status "INFO" "Securely erasing the first 1MB of $USB_DEVICE..."
    shred -n 1 -z -s 1M "$USB_DEVICE" || {
        print_status "ERROR" "Failed to shred device"
        return 1
    }
    
    # Create GPT partition table
    print_status "INFO" "Creating GPT partition table..."
    parted -s "$USB_DEVICE" mklabel gpt || {
        print_status "ERROR" "Failed to create GPT label"
        return 1
    }
    
    # Create partitions
    print_status "INFO" "Creating partitions..."
    parted -s "$USB_DEVICE" mkpart primary fat32 1MiB "$CLONEZILLA_PART_SIZE" || {
        print_status "ERROR" "Failed to create first partition"
        return 1
    }
    
    parted -s "$USB_DEVICE" mkpart primary fat32 "$CLONEZILLA_PART_SIZE" 100% || {
        print_status "ERROR" "Failed to create second partition"
        return 1
    }
    
    # Set boot flag on first partition
    parted -s "$USB_DEVICE" set 1 boot on || {
        print_status "ERROR" "Failed to set boot flag"
        return 1
    }
    
    # Update partition table
    partprobe "$USB_DEVICE" || {
        print_status "ERROR" "Failed to update partition table"
        return 1
    }
    
    # Wait for system to recognize new partitions
    sleep 5
    
    # Get partition names
    PART1=$(lsblk -lnpo NAME,TYPE "$USB_DEVICE" | awk '$2=="part"{print $1}' | sed -n '1p')
    PART2=$(lsblk -lnpo NAME,TYPE "$USB_DEVICE" | awk '$2=="part"{print $1}' | sed -n '2p')
    
    if [ -z "$PART1" ] || [ -z "$PART2" ]; then
        print_status "ERROR" "Could not determine partition names"
        return 1
    fi
    
    print_status "SUCCESS" "Partitioning completed"
    print_status "INFO" "Partition 1: $PART1"
    print_status "INFO" "Partition 2: $PART2"
}

# Function to create filesystems
create_filesystems() {
    print_status "INFO" "Creating filesystems..."
    
    # Create filesystem on first partition
    print_status "INFO" "Creating filesystem on Clonezilla partition..."
    mkfs.vfat -F 32 "$PART1" >/dev/null 2>&1 || {
        print_status "ERROR" "Failed to create filesystem on first partition"
        return 1
    }
    
    # Create filesystem on second partition
    print_status "INFO" "Creating filesystem on second partition..."
    mkfs.vfat -F 32 "$PART2" >/dev/null 2>&1 || {
        print_status "ERROR" "Failed to create filesystem on second partition"
        return 1
    }
    
    print_status "SUCCESS" "Filesystems created successfully"
}

# =============================================================================
# CLONEZILLA SETUP
# =============================================================================

# Function to setup Clonezilla
setup_clonezilla() {
    print_status "INFO" "Setting up Clonezilla..."
    
    # Ensure mount point exists
    ensure_mount_point || return 1
    
    # Mount first partition
    mount "$PART1" "$MOUNT_POINT" || {
        print_status "ERROR" "Failed to mount Clonezilla partition"
        return 1
    }
    
    # Download Clonezilla
    download_file "$CLONEZILLA_URL" "$ZIP_NAME" "Clonezilla Live" || return 1
    
    # Extract Clonezilla
    print_status "INFO" "Extracting Clonezilla..."
    unzip -q "$ZIP_NAME" -d "$MOUNT_POINT" || {
        print_status "ERROR" "Failed to extract Clonezilla"
        return 1
    }
    
    # Unmount and cleanup
    umount "$MOUNT_POINT" || {
        print_status "ERROR" "Failed to unmount Clonezilla partition"
        return 1
    }
    
    rm -f "$ZIP_NAME"
    print_status "SUCCESS" "Clonezilla setup completed"
}

# =============================================================================
# BACKUP SETUP
# =============================================================================

# Function to setup backup
setup_backup() {
    local force_backup=false
    
    if [ "$BACKUP_ONLY" = true ]; then
        force_backup=true
    else
        echo
        echo -n "Would you like to add a backup from a zip file? (yes/no) [no]: "
        read -r add_backup
        add_backup=${add_backup:-no}
        
        if [ "$add_backup" != "yes" ]; then
            print_status "INFO" "Skipping backup setup"
            return 0
        fi
        force_backup=true
    fi
    
    if [ "$force_backup" = true ]; then
        echo -n "Enter the URL of the backup file: "
        read -r backup_url
        
        if [ -z "$backup_url" ]; then
            print_status "WARNING" "No backup URL provided, skipping backup setup"
            return 0
        fi
        
        print_status "INFO" "Setting up backup..."
        
        # Ensure mount point exists
        ensure_mount_point || return 1
        
        # Mount second partition
        mount "$PART2" "$MOUNT_POINT" || {
            print_status "ERROR" "Failed to mount backup partition"
            return 1
        }
        
        # Download backup
        download_file "$backup_url" "$BACKUP_NAME" "backup file" || return 1
        
        # Extract backup
        print_status "INFO" "Extracting backup..."
        unzip -q "$BACKUP_NAME" -d "$MOUNT_POINT" || {
            print_status "ERROR" "Failed to extract backup"
            return 1
        }
        
        # Unmount and cleanup
        umount "$MOUNT_POINT" || {
            print_status "ERROR" "Failed to unmount backup partition"
            return 1
        }
        
        rm -f "$BACKUP_NAME"
        print_status "SUCCESS" "Backup setup completed"
    fi
}

# =============================================================================
# COMMAND LINE INTERFACE
# =============================================================================

# Function to display usage
show_usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Options:
    -h, --help          Show this help message
    -v, --verbose       Enable verbose output
    -d, --dry-run       Show what would be done without making changes
    -l, --log-file      Specify log file (default: $LOG_FILE)
    -b, --backup-only   Only add a backup to existing Clonezilla USB drive

Description:
    This script downloads and sets up Clonezilla Live on a USB device.
    It creates two partitions: one for Clonezilla and one for backups.

Examples:
    $SCRIPT_NAME                    # Run with default settings
    $SCRIPT_NAME -v                 # Run with verbose output
    $SCRIPT_NAME --dry-run          # Show what would be done
    $SCRIPT_NAME --backup-only      # Only add backup to existing drive

EOF
}

# Function to parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -b|--backup-only)
                BACKUP_ONLY=true
                shift
                ;;
            -l|--log-file)
                LOG_FILE="$2"
                shift 2
                ;;
            *)
                print_status "ERROR" "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# =============================================================================
# MAIN FUNCTION
# =============================================================================

# Main function
main() {
    print_status "INFO" "Starting Clonezilla setup script"
    print_status "INFO" "Log file: $LOG_FILE"
    
    # Parse command line arguments
    parse_arguments "$@"
    
    # Setup
    check_root
    check_dependencies
    create_lock
    setup_signal_handlers
    
    if [ "$DRY_RUN" = true ]; then
        print_status "INFO" "DRY RUN MODE - No changes will be made"
    fi
    
    if [ "$BACKUP_ONLY" = true ]; then
        print_status "INFO" "BACKUP ONLY MODE - Will only add backup to existing drive"
    fi
    
    # Check internet connectivity
    check_internet || exit 1
    
    # Get device selection
    get_device_selection
    
    if [ "$BACKUP_ONLY" = true ]; then
        # Backup-only mode: skip partitioning and Clonezilla setup
        if [ "$DRY_RUN" = true ]; then
            print_status "INFO" "DRY RUN: Would add backup to $USB_DEVICE"
            exit 0
        fi
        
        # Perform backup setup only
        setup_backup || exit 1
    else
        # Full setup mode: confirm device wipe
        confirm_device_wipe
        
        if [ "$DRY_RUN" = true ]; then
            print_status "INFO" "DRY RUN: Would partition $USB_DEVICE"
            print_status "INFO" "DRY RUN: Would setup Clonezilla"
            print_status "INFO" "DRY RUN: Would setup backup if requested"
            exit 0
        fi
        
        # Perform full operations
        partition_device || exit 1
        create_filesystems || exit 1
        setup_clonezilla || exit 1
        setup_backup || exit 1
    fi
    
    print_status "SUCCESS" "All operations completed successfully!"
}

# Run main function with all arguments
main "$@"
