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
CLONEZILLA_BASE_URL="https://sourceforge.net/projects/clonezilla/files/clonezilla_live_stable"
CLONEZILLA_VERSION=""  # Auto-detect if empty, or specify with -V/--version
CLONEZILLA_URL=""
ZIP_NAME="clonezilla-live.zip"
MOUNT_POINT="/mnt/usb"
BACKUP_NAME="backup.zip"
DOWNLOAD_DIR=""  # Default to /tmp, can be set with -D/--download-dir
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
OFFLINE_MODE=false
SKIP_CONFIRM=false

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

# Function to format bytes to human-readable format
# Description: Convert bytes to KB, MB, GB format
# Parameters: bytes (number)
# Returns: Prints formatted string
format_bytes() {
    local bytes=$1
    if [ $bytes -ge $((1024*1024*1024)) ]; then
        echo "$((bytes / 1024 / 1024 / 1024))GB"
    elif [ $bytes -ge $((1024*1024)) ]; then
        echo "$((bytes / 1024 / 1024))MB"
    elif [ $bytes -ge 1024 ]; then
        echo "$((bytes / 1024))KB"
    else
        echo "${bytes}B"
    fi
}

# Function to check disk space
# Description: Check if sufficient disk space is available
# Parameters: required_bytes, check_path (directory to check)
# Returns: 0 if sufficient, 1 if insufficient
check_disk_space() {
    local required=$1
    local check_path="${2:-/tmp}"
    local available
    
    available=$(df -B1 "$check_path" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    
    if [ "$available" -lt "$required" ]; then
        print_status "ERROR" "Insufficient disk space"
        print_status "INFO" "Required: $(format_bytes "$required"), Available: $(format_bytes "$available")"
        print_status "INFO" "Suggested fix: Free up space or use -D/--download-dir to specify different location"
        return 1
    fi
    
    log_verbose "Disk space check passed: $(format_bytes "$available") available"
    return 0
}

# Function to get file size from URL
# Description: Fetch file size from HTTP headers
# Parameters: url
# Returns: Prints file size in bytes, returns 0 on success
get_url_file_size() {
    local url="$1"
    local size
    
    size=$(curl -sI "$url" 2>/dev/null | grep -i "content-length" | awk '{print $2}' | tr -d '\r' || echo "0")
    
    if [ -n "$size" ] && [ "$size" != "0" ]; then
        echo "$size"
        return 0
    fi
    
    return 1
}

# Function: get checksum from URL
# Description: Fetch SHA256 checksum from .sha256 file
# Parameters: url
# Returns: Prints checksum, returns 0 on success
get_checksum_from_url() {
    local url="$1"
    local checksum_url="${url}.sha256"
    local checksum=""
    
    if [ "$OFFLINE_MODE" = true ]; then
        return 1
    fi
    
    checksum=$(curl -sL "$checksum_url" 2>/dev/null | awk '{print $1}' | head -1)
    
    if [ -n "$checksum" ] && [ ${#checksum} -eq 64 ]; then
        echo "$checksum"
        return 0
    fi
    
    return 1
}

# Function: verify checksum
# Description: Verify file SHA256 checksum
# Parameters: file_path, expected_checksum
# Returns: 0 if valid, 1 if invalid
verify_checksum() {
    local file="$1"
    local expected="$2"
    local actual=""
    
    if [ -z "$expected" ]; then
        log_verbose "No checksum provided, skipping verification"
        return 0
    fi
    
    if ! command -v sha256sum >/dev/null 2>&1; then
        print_status "WARNING" "sha256sum not available, skipping checksum verification"
        return 0
    fi
    
    print_status "INFO" "Verifying checksum..."
    actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
    
    if [ "$actual" = "$expected" ]; then
        print_status "SUCCESS" "Checksum verification passed"
        return 0
    else
        print_status "ERROR" "Checksum verification failed"
        print_status "INFO" "Expected: $expected"
        print_status "INFO" "Actual: $actual"
        print_status "INFO" "File may be corrupted. Please re-download."
        return 1
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
    if [ "$OFFLINE_MODE" = true ]; then
        log_verbose "Offline mode enabled, skipping internet check"
        return 0
    fi
    
    print_status "INFO" "Checking internet connectivity..."
    
    for i in $(seq 1 $MAX_RETRIES); do
        if curl -s --max-time 10 --head --request GET https://www.google.com 2>/dev/null | grep -q "200"; then
            print_status "SUCCESS" "Internet connection verified"
            return 0
        fi
        
        if [ $i -lt $MAX_RETRIES ]; then
            print_status "WARNING" "Internet check failed, retrying in 3 seconds... (attempt $i/$MAX_RETRIES)"
            sleep 3
        fi
    done
    
    print_status "ERROR" "No internet connection detected after $MAX_RETRIES attempts"
    print_status "INFO" "Suggested fix: Check network connection or use --offline mode"
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
    if [ -n "$DOWNLOAD_DIR" ]; then
        rm -f "${DOWNLOAD_DIR}/${ZIP_NAME}" "${DOWNLOAD_DIR}/${BACKUP_NAME}"
    else
        rm -f "/tmp/${ZIP_NAME}" "/tmp/${BACKUP_NAME}"
    fi
    
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
# VERSION DETECTION
# =============================================================================

# Function to get latest Clonezilla version
# Description: Fetch latest stable version from SourceForge
# Parameters: None
# Returns: Prints version string, returns 0 on success, 1 on failure
get_latest_clonezilla_version() {
    local url="${CLONEZILLA_BASE_URL}/"
    local version=""
    
    log_verbose "Fetching latest Clonezilla version from SourceForge..."
    
    # Try to parse directory listing from SourceForge
    # SourceForge shows versions in format: clonezilla_live_stable/VERSION/
    version=$(curl -sL "$url" 2>/dev/null | \
        grep -oP 'clonezilla_live_stable/[^/]+/' | \
        head -1 | \
        sed 's|clonezilla_live_stable/||;s|/||' || echo "")
    
    # Alternative: try to match version pattern directly from page
    if [ -z "$version" ]; then
        version=$(curl -sL "$url" 2>/dev/null | \
            grep -oP 'clonezilla-live-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' | \
            head -1 | \
            sed 's/clonezilla-live-//' || echo "")
    fi
    
    if [ -n "$version" ]; then
        echo "$version"
        return 0
    fi
    
    return 1
}

# Function to build Clonezilla URL
# Description: Build download URL from version number
# Parameters: version
# Returns: Prints URL, returns 0 on success
build_clonezilla_url() {
    local version="$1"
    local url="${CLONEZILLA_BASE_URL}/${version}/clonezilla-live-${version}-amd64.zip"
    echo "$url"
}

# =============================================================================
# NETWORK OPERATIONS
# =============================================================================

# Function to check if string is a URL
# Description: Detect if input is a URL or local file path
# Parameters: input_string
# Returns: 0 if URL, 1 if local path
is_url() {
    [[ "$1" =~ ^https?:// ]] || [[ "$1" =~ ^ftp:// ]] || [[ "$1" =~ ^file:// ]]
}

# Function to check if string is a local file path
# Description: Verify if input is a valid local file path
# Parameters: file_path
# Returns: 0 if valid file, 1 if not
is_local_file() {
    local file_path="$1"
    
    # Expand ~ and resolve relative paths
    file_path="${file_path/#\~/$HOME}"
    if [[ "$file_path" != /* ]]; then
        file_path="$(pwd)/$file_path"
    fi
    
    [ -f "$file_path" ] && [ -r "$file_path" ]
}

# Function to copy local file
# Description: Copy local file to destination
# Parameters: source_path, dest_path, description
# Returns: 0 on success, 1 on failure
copy_local_file() {
    local source="$1"
    local dest="$2"
    local description="$3"
    local dest_dir
    dest_dir=$(dirname "$dest")
    local file_size=0
    
    # Expand ~ and resolve relative paths
    source="${source/#\~/$HOME}"
    if [[ "$source" != /* ]]; then
        source="$(pwd)/$source"
    fi
    
    if [ ! -f "$source" ]; then
        print_status "ERROR" "Local file not found: $source"
        return 1
    fi
    
    if [ ! -r "$source" ]; then
        print_status "ERROR" "Cannot read file: $source"
        return 1
    fi
    
    # Check disk space before copying
    print_status "INFO" "Checking disk space..."
    file_size=$(stat -f%z "$source" 2>/dev/null || stat -c%s "$source" 2>/dev/null || echo "0")
    
    if [ "$file_size" -gt 0 ]; then
        log_verbose "File size: $(format_bytes "$file_size")"
        check_disk_space "$file_size" "$dest_dir" || return 1
    fi
    
    print_status "INFO" "Copying $description..."
    
    cp "$source" "$dest" || {
        print_status "ERROR" "Failed to copy $description"
        return 1
    }
    
    print_status "SUCCESS" "$description copied successfully"
    return 0
}

# Function to download file with progress, retry, and resume support
download_file() {
    local url="$1"
    local output="$2"
    local description="$3"
    local expected_checksum="${4:-}"  # Optional checksum for verification
    local output_dir
    output_dir=$(dirname "$output")
    local resume_flag=""
    
    # Check if partial download exists and can resume
    if [ -f "$output" ] && [ -s "$output" ]; then
        if curl -s --head --range 0-0 "$url" >/dev/null 2>&1; then
            resume_flag="-C -"
            print_status "INFO" "Resuming partial download..."
        fi
    fi
    
    # Check disk space before downloading
    print_status "INFO" "Checking disk space..."
    local file_size=0
    file_size=$(get_url_file_size "$url" || echo "0")
    
    if [ "$file_size" -gt 0 ]; then
        log_verbose "File size: $(format_bytes "$file_size")"
        check_disk_space "$file_size" "$output_dir" || return 1
    else
        # If we can't get size, estimate 1GB for safety (Clonezilla is typically 400-800MB)
        log_verbose "Could not determine file size, checking for 1GB minimum"
        check_disk_space $((1024*1024*1024)) "$output_dir" || return 1
    fi
    
    print_status "INFO" "Downloading $description..."
    
    for i in $(seq 1 $MAX_RETRIES); do
        if curl -L -o "$output" $resume_flag --progress-bar --max-time $DOWNLOAD_TIMEOUT "$url" 2>&1; then
            print_status "SUCCESS" "$description downloaded successfully"
            
            # Verify checksum if provided
            if [ -n "$expected_checksum" ]; then
                verify_checksum "$output" "$expected_checksum" || return 1
            fi
            
            return 0
        fi
        
        if [ $i -lt $MAX_RETRIES ]; then
            print_status "WARNING" "Download failed, retrying in 5 seconds... (attempt $i/$MAX_RETRIES)"
            sleep 5
            resume_flag="-C -"  # Try to resume on retry
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

# Function to check if device is removable
# Description: Check if device is a USB/SD card (removable)
# Parameters: device_path
# Returns: 0 if removable, 1 if not
is_removable_device() {
    local device="$1"
    local sys_path="/sys/block/$(basename "$device")/removable"
    
    if [ -f "$sys_path" ]; then
        local removable=$(cat "$sys_path" 2>/dev/null || echo "0")
        [ "$removable" = "1" ]
        return $?
    fi
    
    return 1
}

# Function to check if device is system disk
# Description: Check if device appears to be system/root disk
# Parameters: device_path
# Returns: 0 if system disk, 1 if not
is_system_disk() {
    local device="$1"
    local device_name=$(basename "$device")
    
    # Check if device contains root filesystem
    if mount | grep -q "^/dev/${device_name}" && mount | grep -q " on / "; then
        return 0
    fi
    
    # Check if it's typically a system disk (could be, but not always)
    case "$device_name" in
        sda|nvme0n1|mmcblk0)
            # Could be system disk, but not always - return uncertain
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to safely get device information
get_device_info() {
    local device="$1"
    
    # Check if device exists and is a block device
    if [ ! -b "$device" ]; then
        print_status "ERROR" "Device $device does not exist or is not a block device"
        print_status "INFO" "Suggested fix: Check device name with 'lsblk' command"
        return 1
    fi
    
    # Check if device is mounted
    if mount | grep -q "$device"; then
        print_status "ERROR" "Device $device is currently mounted. Please unmount it first."
        print_status "INFO" "Suggested fix: Run 'umount ${device}*' to unmount all partitions"
        return 1
    fi
    
    # Warn if system disk
    if is_system_disk "$device"; then
        print_status "WARNING" "Device $device may be the system disk!"
        print_status "WARNING" "Continuing may cause data loss!"
        if [ "$SKIP_CONFIRM" != true ]; then
            echo -n "Continue anyway? (yes/no) [no]: "
            read -r confirm
            if [ "$confirm" != "yes" ]; then
                return 1
            fi
        else
            print_status "WARNING" "Skipping confirmation (--yes flag used)"
        fi
    fi
    
    # Get device size
    local device_size
    device_size=$(lsblk -b -o SIZE -n -d "$device" 2>/dev/null || echo "0")
    
    if [ "$device_size" -lt $MIN_DEVICE_SIZE ]; then
        print_status "ERROR" "Device $device is too small. Minimum size required: $(format_bytes "$MIN_DEVICE_SIZE")"
        print_status "INFO" "Device size: $(format_bytes "$device_size")"
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
    printf "%-10s %-10s %-15s %-20s %-10s %s\n" "DEVICE" "SIZE" "TYPE" "MODEL" "MOUNTED" "NOTES"
    echo "---------------------------------------------------------------------------"
    
    lsblk -d -o NAME,SIZE,TYPE,MODEL | grep "disk" | while read -r name size type model; do
        local device="/dev/$name"
        local mounted=""
        local notes=""
        
        if mount | grep -q "^$device"; then
            mounted="YES"
        else
            mounted="NO"
        fi
        
        if is_removable_device "$device"; then
            notes="[USB/SD]"
        fi
        
        if is_system_disk "$device"; then
            notes="${notes}[SYSTEM]"
        fi
        
        printf "%-10s %-10s %-15s %-20s %-10s %s\n" "$name" "$size" "$type" "$model" "$mounted" "$notes"
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
    if [ "$SKIP_CONFIRM" = true ]; then
        print_status "WARNING" "Skipping confirmation (--yes flag used)"
        print_status "WARNING" "This operation will ERASE ALL DATA on $USB_DEVICE"
        return 0
    fi
    
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
    
    # Determine Clonezilla version
    if [ -z "$CLONEZILLA_VERSION" ]; then
        print_status "INFO" "Detecting latest Clonezilla version..."
        CLONEZILLA_VERSION=$(get_latest_clonezilla_version)
        if [ -z "$CLONEZILLA_VERSION" ]; then
            print_status "ERROR" "Could not detect latest Clonezilla version"
            print_status "INFO" "Please specify version manually using -V or --version flag"
            return 1
        else
            print_status "SUCCESS" "Detected latest version: $CLONEZILLA_VERSION"
        fi
    else
        print_status "INFO" "Using specified version: $CLONEZILLA_VERSION"
    fi
    
    # Build download URL
    CLONEZILLA_URL=$(build_clonezilla_url "$CLONEZILLA_VERSION")
    log_verbose "Clonezilla URL: $CLONEZILLA_URL"
    
    # Ensure mount point exists
    ensure_mount_point || return 1
    
    # Mount first partition
    mount "$PART1" "$MOUNT_POINT" || {
        print_status "ERROR" "Failed to mount Clonezilla partition"
        return 1
    }
    
    # Set download path
    local zip_path="${DOWNLOAD_DIR}/${ZIP_NAME}"
    
    # Get checksum if available
    local checksum=""
    if [ "$OFFLINE_MODE" != true ]; then
        checksum=$(get_checksum_from_url "$CLONEZILLA_URL" || echo "")
        if [ -n "$checksum" ]; then
            log_verbose "Found checksum for verification"
        fi
    fi
    
    # Download Clonezilla (with checksum verification)
    download_file "$CLONEZILLA_URL" "$zip_path" "Clonezilla Live" "$checksum" || return 1
    
    # Extract Clonezilla
    print_status "INFO" "Extracting Clonezilla..."
    unzip -q "$zip_path" -d "$MOUNT_POINT" || {
        print_status "ERROR" "Failed to extract Clonezilla"
        return 1
    }
    
    # Unmount and cleanup
    umount "$MOUNT_POINT" || {
        print_status "ERROR" "Failed to unmount Clonezilla partition"
        return 1
    }
    
    rm -f "$zip_path"
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
        echo -n "Enter the URL or path of the backup file: "
        read -r backup_input
        
        if [ -z "$backup_input" ]; then
            print_status "WARNING" "No backup file provided, skipping backup setup"
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
        
        # Set backup path
        local backup_path="${DOWNLOAD_DIR}/${BACKUP_NAME}"
        
        # Determine if input is URL or local file and process accordingly
        if is_url "$backup_input"; then
            # Download backup from URL
            download_file "$backup_input" "$backup_path" "backup file" || return 1
        elif is_local_file "$backup_input"; then
            # Copy local backup file
            local expanded_path="${backup_input/#\~/$HOME}"
            if [[ "$expanded_path" != /* ]]; then
                expanded_path="$(pwd)/$expanded_path"
            fi
            copy_local_file "$expanded_path" "$backup_path" "backup file" || return 1
        else
            print_status "ERROR" "Invalid backup source: $backup_input"
            print_status "INFO" "Must be a valid URL (http://...) or local file path"
            umount "$MOUNT_POINT" 2>/dev/null
            return 1
        fi
        
        # Extract backup
        print_status "INFO" "Extracting backup..."
        unzip -q "$backup_path" -d "$MOUNT_POINT" || {
            print_status "ERROR" "Failed to extract backup"
            return 1
        }
        
        # Unmount and cleanup
        umount "$MOUNT_POINT" || {
            print_status "ERROR" "Failed to unmount backup partition"
            return 1
        }
        
        rm -f "$backup_path"
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
    -V, --version VER    Specify Clonezilla version (default: auto-detect latest)
    -D, --download-dir DIR  Directory for downloads (default: /tmp)
    -o, --offline        Skip internet connectivity checks
    -y, --yes            Skip confirmation prompts

Description:
    This script downloads and sets up Clonezilla Live on a USB device.
    It creates two partitions: one for Clonezilla and one for backups.

Examples:
    $SCRIPT_NAME                    # Run with default settings (auto-detect latest version)
    $SCRIPT_NAME -v                 # Run with verbose output
    $SCRIPT_NAME --dry-run          # Show what would be done
    $SCRIPT_NAME --backup-only      # Only add backup to existing drive
    $SCRIPT_NAME -V 3.2.0-5        # Use specific Clonezilla version
    $SCRIPT_NAME -D /var/tmp       # Use different directory for downloads
    $SCRIPT_NAME -o                # Run in offline mode
    $SCRIPT_NAME -y                # Skip confirmation prompts

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
            -V|--version)
                CLONEZILLA_VERSION="$2"
                shift 2
                ;;
            -D|--download-dir)
                DOWNLOAD_DIR="$2"
                if [ ! -d "$DOWNLOAD_DIR" ]; then
                    print_status "ERROR" "Download directory does not exist: $DOWNLOAD_DIR"
                    exit 1
                fi
                shift 2
                ;;
            -o|--offline)
                OFFLINE_MODE=true
                shift
                ;;
            -y|--yes)
                SKIP_CONFIRM=true
                shift
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
    
    # Initialize download directory (default to /tmp if not set)
    if [ -z "$DOWNLOAD_DIR" ]; then
        DOWNLOAD_DIR="/tmp"
    fi
    
    # Ensure download directory exists
    if [ ! -d "$DOWNLOAD_DIR" ]; then
        print_status "ERROR" "Download directory does not exist: $DOWNLOAD_DIR"
        exit 1
    fi
    
    log_verbose "Download directory: $DOWNLOAD_DIR"
    
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
    
    if [ "$OFFLINE_MODE" = true ]; then
        print_status "INFO" "OFFLINE MODE - Internet checks disabled"
    fi
    
    # Check internet connectivity (unless offline mode or backup-only with local files)
    if [ "$OFFLINE_MODE" != true ] && [ "$BACKUP_ONLY" != true ]; then
        check_internet || exit 1
    elif [ "$OFFLINE_MODE" != true ] && [ "$BACKUP_ONLY" = true ]; then
        # Only check if we might need to download something
        # (User will provide URL or file path interactively)
        log_verbose "Skipping internet check - will check when backup source is provided"
    fi
    
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
