# Setup Clonezilla

A robust, feature-rich script to download and set up Clonezilla Live on USB drives with optional backup installation.

## 🎯 Overview

This script automates the process of creating a bootable Clonezilla Live USB drive. It downloads the latest stable version of Clonezilla Live, partitions your USB device, and optionally installs backup images. The script includes comprehensive error handling, safety checks, and multiple operation modes.

## ✨ Features

- **🔄 Automatic Download**: Downloads the latest Clonezilla Live stable release
- **🛡️ Safety First**: Comprehensive device validation and safety checks
- **📝 Detailed Logging**: Colored output with timestamped log files
- **🔄 Retry Logic**: Automatic retry for network operations
- **🔒 Lock Protection**: Prevents multiple instances from running
- **🎛️ Multiple Modes**: Full setup, backup-only, and verbose modes
- **🧹 Clean Cleanup**: Automatic resource cleanup on exit or failure
- **📊 Progress Tracking**: Visual progress indicators for downloads
- **🔧 Flexible Options**: Command line options for different use cases
- **📦 Interactive Backup Menu**: Easy selection of predefined backup images or custom backups

## 📋 Prerequisites

### System Requirements
- Linux system with Ruby installed
- Root access (sudo privileges)
- Internet connection for downloading Clonezilla
- USB device with at least 8GB capacity

### Required Dependencies
The script requires Ruby and will automatically check for the following system packages:
```bash
ruby parted unzip curl lsblk blkid mkfs.vfat shred wget
```

**Note**: You do not need to manually install these dependencies. The script will automatically check for them and provide installation instructions if any are missing.

If you need to install dependencies manually:
```bash
sudo apt-get install ruby parted unzip curl util-linux dosfstools secure-delete wget
```

## 🚀 Installation

1. **Clone the repository**:
   ```bash
   git clone https://github.com/hardenedpenguin/setup_clonezilla.git
   cd setup_clonezilla
   ```

2. **Make the script executable**:
   ```bash
   chmod +x setup_clonezilla.rb
   ```

## 💻 Usage

### Basic Usage

**Full Setup** (recommended for new drives):
```bash
sudo ./setup_clonezilla.rb
```

**Backup-Only Mode** (for existing Clonezilla drives):
```bash
sudo ./setup_clonezilla.rb --backup-only
```

**Verbose Mode** (for debugging):
```bash
sudo ./setup_clonezilla.rb -v
```

## 🎛️ Command Line Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message and exit |
| `-v, --verbose` | Enable verbose output for debugging |
| `-b, --backup-only` | Only add backup to existing Clonezilla drive |
| `-l, --log-file` | Specify custom log file location |
| `-V, --version VER` | Specify Clonezilla version (default: auto-detect latest) |
| `-D, --download-dir DIR` | Directory for downloads (default: /root) |
| `-y, --yes` | Skip confirmation prompts |

## 📖 Examples

### Example 1: Full Setup with Backup
```bash
# Run full setup with interactive backup selection
# The script will prompt you to choose from available backups or enter a custom URL/path
sudo ./setup_clonezilla.rb -v
```

### Example 2: Add Backup to Existing Drive
```bash
# Add backup to existing Clonezilla USB drive
# You'll be presented with a menu to select from predefined backups or enter a custom source
sudo ./setup_clonezilla.rb --backup-only
```

### Example 3: Use Specific Clonezilla Version
```bash
# Use a specific Clonezilla version instead of auto-detecting
sudo ./setup_clonezilla.rb -V 3.3.0-33
```

### Example 4: Custom Download Directory
```bash
# Use a different directory for downloads
sudo ./setup_clonezilla.rb -D /var/tmp
```

### Example 5: Skip Confirmation Prompts
```bash
# Automatically confirm all prompts (use with caution!)
sudo ./setup_clonezilla.rb -y
```

### Example 6: Custom Log File
```bash
# Use custom log file location
sudo ./setup_clonezilla.rb -l /var/log/clonezilla_setup.log
```

## 💾 Backup Images

When you choose to add a backup during setup, the script presents an interactive menu with the following options:

1. **ASL3 Trixie Backup** - Debian Trixie stable with ASL3 (AllStar Link) ready for amateur radio use
2. **Dell 3040 Backup** - Debian 12 with ASL3 (AllStar Link) ready for amateur radio use
3. **Custom backup** - Enter your own URL or local file path

**Note**: Both predefined backup images are compatible with all x86_64 devices and contain generic Debian installations with ASL3 pre-configured. Default credentials for both images are `hamradio` / `hamradio`.

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
sudo rm /tmp/setup_clonezilla.rb.lock
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

The script creates detailed logs at `/tmp/setup_clonezilla.rb.log` by default.

**View recent logs**:
```bash
tail -f /tmp/setup_clonezilla.rb.log
```

**Search for errors**:
```bash
grep "ERROR" /tmp/setup_clonezilla.rb.log
```

**View all operations**:
```bash
cat /tmp/setup_clonezilla.rb.log
```

### Getting Help

1. **Check the logs** for detailed error information
2. **Run with verbose mode** (`-v`) for more output
3. **Review this README** for common solutions

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
