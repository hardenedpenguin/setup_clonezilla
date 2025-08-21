# Setup Clonezilla

A robust, feature-rich script to download and set up Clonezilla Live on USB drives with optional backup installation.

## 📋 Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Usage](#usage)
- [Command Line Options](#command-line-options)
- [Examples](#examples)
- [Backup Images](#backup-images)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

## 🎯 Overview

This script automates the process of creating a bootable Clonezilla Live USB drive. It downloads the latest stable version of Clonezilla Live, partitions your USB device, and optionally installs backup images. The script includes comprehensive error handling, safety checks, and multiple operation modes.

## ✨ Features

- **🔄 Automatic Download**: Downloads the latest Clonezilla Live stable release
- **🛡️ Safety First**: Comprehensive device validation and safety checks
- **📝 Detailed Logging**: Colored output with timestamped log files
- **🔄 Retry Logic**: Automatic retry for network operations
- **🔒 Lock Protection**: Prevents multiple instances from running
- **🎛️ Multiple Modes**: Full setup, backup-only, dry-run, and verbose modes
- **🧹 Clean Cleanup**: Automatic resource cleanup on exit or failure
- **📊 Progress Tracking**: Visual progress indicators for downloads
- **🔧 Flexible Options**: Command line options for different use cases

## 📋 Prerequisites

### System Requirements
- Linux system with bash shell
- Root access (sudo privileges)
- Internet connection for downloading Clonezilla
- USB device with at least 8GB capacity

### Required Dependencies
The script will automatically check for and install these packages:
```bash
parted unzip curl lsblk blkid mkfs.vfat shred wget
```

Install missing dependencies:
```bash
sudo apt-get install parted unzip curl lsblk blkid dosfstools secure-delete wget
```

## 🚀 Installation

1. **Clone the repository**:
   ```bash
   git clone https://github.com/hardenedpenguin/setup_clonezilla.git
   cd setup_clonezilla
   ```

2. **Make the script executable**:
   ```bash
   chmod +x setup_clonezilla.sh
   ```

## 💻 Usage

### Basic Usage

**Full Setup** (recommended for new drives):
```bash
sudo ./setup_clonezilla.sh
```

**Backup-Only Mode** (for existing Clonezilla drives):
```bash
sudo ./setup_clonezilla.sh --backup-only
```

**Verbose Mode** (for debugging):
```bash
sudo ./setup_clonezilla.sh -v
```

**Dry Run** (preview operations without making changes):
```bash
sudo ./setup_clonezilla.sh --dry-run
```

## 🎛️ Command Line Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message and exit |
| `-v, --verbose` | Enable verbose output for debugging |
| `-d, --dry-run` | Preview operations without making changes |
| `-b, --backup-only` | Only add backup to existing Clonezilla drive |
| `-l, --log-file` | Specify custom log file location |

## 📖 Examples

### Example 1: Full Setup with Backup
```bash
# Run full setup with interactive backup selection
sudo ./setup_clonezilla.sh -v
```

### Example 2: Add Backup to Existing Drive
```bash
# Add backup to existing Clonezilla USB drive
sudo ./setup_clonezilla.sh --backup-only
```

### Example 3: Preview Operations
```bash
# See what the script would do without making changes
sudo ./setup_clonezilla.sh --dry-run -v
```

### Example 4: Custom Log File
```bash
# Use custom log file location
sudo ./setup_clonezilla.sh -l /var/log/clonezilla_setup.log
```

## 💾 Backup Images

### Dell 3040 / ASL3 Backup

A pre-configured Debian 12 system with ASL3 (AllStar Link) ready for amateur radio use.

**URL**: `https://anarchy.w5gle.us/Dell-3040-2025-08-10-01-img.zip`

**Important Note**: While this backup is labeled for Dell 3040, it is compatible with all x86_64 devices. The backup contains a generic Debian 12 installation with ASL3 pre-configured, making it suitable for any x86_64 system.

**Features**:
- Debian 12 base system
- ASL3 and ASL3-pi-appliance pre-installed
- NetworkManager configured for all network devices
- dw_dmac_core module blacklisted for proper reboot/shutdown
- Default credentials: `hamradio` / `hamradio`

### Post-Installation Setup

After restoring the backup, perform these steps:

1. **Change default password**:
   ```bash
   passwd
   ```

2. **Configure timezone** (if needed):
   ```bash
   sudo dpkg-reconfigure tzdata
   ```

3. **Create your own user account**:
   ```bash
   sudo adduser yourusername
   sudo adduser yourusername sudo
   ```

4. **Remove default account** (optional):
   ```bash
   sudo deluser --remove-all-files hamradio
   ```

5. **Configure ASL3** as needed for your setup

## 🔧 Troubleshooting

### Common Issues

**"Another instance is already running"**
```bash
# Check for existing processes
ps aux | grep setup_clonezilla

# Remove stale lock file
sudo rm /tmp/setup_clonezilla.sh.lock
```

**"Device is currently mounted"**
```bash
# Unmount the device
sudo umount /dev/sdX*

# Check mount status
mount | grep sdX
```

**"Download failed"**
- Check internet connectivity
- Verify URL accessibility
- Check available disk space
- Try running with `-v` flag for detailed output

**"Device too small"**
- Ensure USB device is at least 8GB
- Check device selection with `lsblk`

### Log Files

The script creates detailed logs at `/tmp/setup_clonezilla.sh.log` by default.

**View recent logs**:
```bash
tail -f /tmp/setup_clonezilla.sh.log
```

**Search for errors**:
```bash
grep "ERROR" /tmp/setup_clonezilla.sh.log
```

**View all operations**:
```bash
cat /tmp/setup_clonezilla.sh.log
```

### Getting Help

1. **Check the logs** for detailed error information
2. **Run with verbose mode** (`-v`) for more output
3. **Use dry-run mode** (`--dry-run`) to preview operations
4. **Review this README** for common solutions

## 🤝 Contributing

We welcome contributions! Here's how you can help:

1. **Report Issues**: Use the GitHub issue tracker
2. **Suggest Features**: Open a feature request
3. **Submit Code**: Fork the repository and submit a pull request
4. **Improve Documentation**: Help improve this README

### Development Guidelines

- Test your changes thoroughly
- Follow the existing code style
- Add appropriate error handling
- Update documentation as needed
- Include test cases when possible

## 📄 License

This project is licensed under the GNU General Public License v2.0 - see the [LICENSE](LICENSE) file for details.

The script includes the following license header:
```
Copyright (C) 2025 Jory A. Pratt - W5GLE

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, version 2 of the License.
```

## 🙏 Acknowledgments

- **Clonezilla Team** for the excellent disk imaging tool
- **AllStar Link Community** for ASL3 development
- **Debian Project** for the stable base system
- **Contributors** who help improve this project

---

**Note**: This script is designed for educational and legitimate backup purposes. Always ensure you have proper authorization before imaging any systems.
