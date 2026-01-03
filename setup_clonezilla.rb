#!/usr/bin/env ruby
# frozen_string_literal: true

# Download and setup Clonezilla, then install a backup if requested.
# Copyright (C) 2026 Jory A. Pratt - W5GLE (geekypenguin@gmail.com)
# Licensed under GPL v2 - see https://www.gnu.org/licenses/gpl-2.0.html

require 'open3'
require 'fileutils'
require 'optparse'
require 'uri'
require 'net/http'
require 'digest'
require 'timeout'

class ClonezillaSetup
  # Configuration constants
  CLONEZILLA_BASE_URL = 'https://sourceforge.net/projects/clonezilla/files/clonezilla_live_stable'
  CLONEZILLA_PART_SIZE = '513M'
  MIN_DEVICE_SIZE = 8 * 1024 * 1024 * 1024 # 8GB in bytes
  MAX_RETRIES = 3
  DOWNLOAD_TIMEOUT = 300 # 5 minutes
  MOUNT_POINT = '/mnt/usb'
  ZIP_NAME = 'clonezilla-live.zip'
  BACKUP_NAME = 'backup.zip'
  DEFAULT_DOWNLOAD_DIR = '/root'
  LOG_FILE = "/tmp/#{File.basename(__FILE__)}.log"
  LOCK_FILE = "/tmp/#{File.basename(__FILE__)}.lock"

  # Backup URLs
  BACKUP_ASL3_TRIXIE_URL = 'https://anarchy.w5gle.us/asl3_trixie_amd64_2025-12-25-17.zip'
  BACKUP_DELL_3040_URL = 'https://anarchy.w5gle.us/Dell-3040-2025-08-10-01-img.zip'

  # Colors for output
  RED = "\033[0;31m"
  GREEN = "\033[0;32m"
  YELLOW = "\033[1;33m"
  BLUE = "\033[0;34m"
  NC = "\033[0m" # No Color

  attr_reader :usb_device, :part1, :part2, :verbose, :backup_only,
              :skip_confirm, :clonezilla_version, :download_dir

  def initialize
    @usb_device = nil
    @part1 = nil
    @part2 = nil
    @verbose = false
    @backup_only = false
    @skip_confirm = false
    @clonezilla_version = nil
    @download_dir = DEFAULT_DOWNLOAD_DIR
    @log_file = LOG_FILE
    @lock_file = LOCK_FILE
    @exit_code = 0
  end

  # Utility Functions
  def ensure_mount_point
    FileUtils.mkdir_p(MOUNT_POINT) unless Dir.exist?(MOUNT_POINT)
    true
  rescue => e
    print_status('ERROR', "Failed to create mount point #{MOUNT_POINT}: #{e.message}")
    false
  end

  def cleanup_mount_point
    Dir.rmdir(MOUNT_POINT) if Dir.exist?(MOUNT_POINT)
  rescue => e
    log_verbose("Failed to remove #{MOUNT_POINT}: #{e.message}")
  end

  def print_status(level, message, force_show: false)
    timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S')
    unless force_show || level == 'ERROR' || @verbose
      if %w[INFO SUCCESS WARNING].include?(level)
        File.open(@log_file, 'a') { |f| f.puts("[#{timestamp}] [#{level}] #{message}") }
        return
      end
    end
    color = case level
            when 'INFO' then BLUE
            when 'SUCCESS' then GREEN
            when 'WARNING' then YELLOW
            when 'ERROR' then RED
            else NC
            end
    puts "#{color}[#{level}]#{NC} #{message}"
    File.open(@log_file, 'a') { |f| f.puts("[#{timestamp}] [#{level}] #{message}") }
  end

  def log_verbose(message)
    print_status('INFO', message) if @verbose
  end

  def format_bytes(bytes)
    return "#{bytes / (1024**4)}TB" if bytes >= 1024**4
    return "#{bytes / (1024**3)}GB" if bytes >= 1024**3
    return "#{bytes / (1024**2)}MB" if bytes >= 1024**2
    return "#{bytes / 1024}KB" if bytes >= 1024
    "#{bytes}B"
  end

  def convert_size_to_bytes(size_str)
    size_str = size_str.upcase
    match = size_str.match(/^(\d+)([KMGTP]?)$/)
    return 0 unless match

    value = match[1].to_i
    unit = match[2]

    multiplier = case unit
                 when 'K' then 1024
                 when 'M' then 1024**2
                 when 'G' then 1024**3
                 when 'T' then 1024**4
                 when 'P' then 1024**5
                 else 1
                 end

    value * multiplier
  end

  def check_disk_space(required_bytes, check_path = '/tmp')
    df_output = `df -B1 #{check_path.shellescape} 2>/dev/null`.split("\n")
    available = df_output.length > 1 ? (df_output[1].split.length > 3 ? df_output[1].split[3].to_i : 0) : 0
    if available < required_bytes
      print_status('ERROR', 'Insufficient disk space')
      print_status('INFO', "Required: #{format_bytes(required_bytes)}, Available: #{format_bytes(available)}")
      print_status('INFO', 'Suggested fix: Free up space or use -D/--download-dir to specify different location')
      return false
    end
    log_verbose("Disk space check passed: #{format_bytes(available)} available")
    true
  end

  def get_url_file_size(url)
    output = `curl -sIL --max-time 10 "#{url}" 2>/dev/null`
    return 0 if output.empty?
    content_length = output.lines.find { |line| line.match?(/^content-length:\s+/i) }
    return 0 unless content_length
    size = content_length.split(':').last.strip.to_i
    size > 0 ? size : 0
  rescue => e
    log_verbose("Failed to get file size: #{e.message}")
    0
  end

  def get_checksum_from_url(url)
    checksum_url = "#{url}.sha256"
    uri = URI(checksum_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 10
    http.read_timeout = 10

    response = http.get(uri.path.empty? ? '/' : uri.path)
    checksum = response.body.split.first

    return checksum if checksum && checksum.length == 64

    nil
  rescue => e
    log_verbose("Failed to get checksum: #{e.message}")
    nil
  end

  def verify_checksum(file_path, expected_checksum)
    return true if expected_checksum.nil? || expected_checksum.empty?
    unless system('which sha256sum >/dev/null 2>&1')
      log_verbose('sha256sum not available, skipping checksum verification')
      return true
    end
    log_verbose('Verifying checksum...')
    actual = `sha256sum #{file_path.shellescape} 2>/dev/null`.split.first
    if actual == expected_checksum
      log_verbose('Checksum verification passed')
      true
    else
      print_status('ERROR', 'Checksum verification failed')
      print_status('ERROR', "Expected: #{expected_checksum}, Actual: #{actual}")
      print_status('ERROR', 'File may be corrupted. Please re-download.')
      false
    end
  end

  # Validation Functions
  def check_root
    unless Process.uid.zero?
      print_status('ERROR', 'This script must be run as root.')
      exit 1
    end
  end

  def check_dependencies
    required_cmds = %w[parted unzip curl lsblk blkid mkfs.vfat shred wget]
    missing_deps = required_cmds.reject { |cmd| system("which #{cmd} >/dev/null 2>&1") }

    unless missing_deps.empty?
      print_status('ERROR', "Missing dependencies: #{missing_deps.join(', ')}")
      print_status('INFO', 'Install them using: apt-get install parted unzip curl util-linux dosfstools secure-delete wget')
      exit 1
    end
  end

  def check_internet
    log_verbose('Checking internet connectivity...')

    MAX_RETRIES.times do |i|
      if system('curl -s --max-time 10 --head --request GET https://www.google.com 2>/dev/null | grep -q "200"')
        log_verbose('Internet connection verified')
        return true
      end

      if i < MAX_RETRIES - 1
        log_verbose("Internet check failed, retrying in 3 seconds... (attempt #{i + 1}/#{MAX_RETRIES})")
        sleep 3
      end
    end

    print_status('ERROR', "No internet connection detected after #{MAX_RETRIES} attempts")
    print_status('ERROR', 'Suggested fix: Check network connection')
    false
  end

  # Lock File Management
  def create_lock
    if File.exist?(@lock_file)
      pid = File.read(@lock_file).to_i
      if pid > 0 && system("kill -0 #{pid} >/dev/null 2>&1")
        print_status('ERROR', "Another instance is already running (PID: #{pid})")
        exit 1
      else
        File.delete(@lock_file)
      end
    end
    File.write(@lock_file, Process.pid.to_s)
  end

  def remove_lock
    File.delete(@lock_file) if File.exist?(@lock_file)
  end

  # Signal Handling and Cleanup
  def setup_signal_handlers
    trap('INT') { @exit_code = 1; cleanup_and_exit(1) }
    trap('TERM') { @exit_code = 1; cleanup_and_exit(1) }
    trap('EXIT') do
      exit_code = if $!.is_a?(SystemExit)
                    $!.status
                  else
                    @exit_code || 0
                  end
      cleanup_and_exit(exit_code)
    end
  end

  def cleanup_and_exit(exit_code)
    log_verbose('Cleaning up...')

    # Unmount any mounted partitions
    if system("mount | grep -q #{MOUNT_POINT.shellescape}")
      log_verbose("Unmounting #{MOUNT_POINT}...")
      system("umount #{MOUNT_POINT.shellescape} >/dev/null 2>&1") || log_verbose("Failed to unmount #{MOUNT_POINT}")
    end

    cleanup_mount_point

    # Clean up temporary files
    zip_path = File.join(@download_dir, ZIP_NAME)
    backup_path = File.join(@download_dir, BACKUP_NAME)
    File.delete(zip_path) if File.exist?(zip_path)
    File.delete(backup_path) if File.exist?(backup_path)

    remove_lock

    if exit_code == 0
      print_status('SUCCESS', 'Setup completed successfully!', force_show: true)
    else
      print_status('ERROR', "Setup failed with exit code #{exit_code}")
    end

    exit exit_code
  end

  # Version Detection
  def get_latest_clonezilla_version
    url = "#{CLONEZILLA_BASE_URL}/"
    log_verbose('Fetching latest Clonezilla version from SourceForge...')

    html = `curl -sL #{url.shellescape} 2>/dev/null`
    versions = html.scan(/clonezilla_live_stable\/(\d+\.\d+\.\d+-\d+)\//).flatten

    if versions.empty?
      versions = html.scan(/clonezilla-live-(\d+\.\d+\.\d+-\d+)/).flatten
    end

    return nil if versions.empty?

    # Sort versions by converting to comparable format
    versions.sort_by do |v|
      parts = v.split('-')
      major_minor_patch = parts[0].split('.').map(&:to_i)
      build = parts[1].to_i
      [major_minor_patch, build]
    end.last
  rescue => e
    log_verbose("Failed to get version: #{e.message}")
    nil
  end

  def build_clonezilla_url(version)
    "#{CLONEZILLA_BASE_URL}/#{version}/clonezilla-live-#{version}-amd64.zip"
  end

  # Network Operations
  def is_url?(input)
    input.match?(/^(https?|ftp|file):\/\//)
  end

  def is_local_file?(file_path)
    expanded = File.expand_path(file_path)
    File.file?(expanded) && File.readable?(expanded)
  end

  def copy_local_file(source, dest, description)
    source = File.expand_path(source)
    dest_dir = File.dirname(dest)

    unless File.file?(source)
      print_status('ERROR', "Local file not found: #{source}")
      return false
    end

    unless File.readable?(source)
      print_status('ERROR', "Cannot read file: #{source}")
      return false
    end

    file_size = File.size(source)
    log_verbose("File size: #{format_bytes(file_size)}")
    return false unless check_disk_space(file_size, dest_dir)

    log_verbose("Copying #{description}...")

    FileUtils.cp(source, dest)
    log_verbose("#{description} copied successfully")
    true
  rescue => e
    print_status('ERROR', "Failed to copy #{description}: #{e.message}")
    false
  end

  def download_file(url, output, description, expected_checksum = nil)
    output_dir = File.dirname(output)
    resume_flag = ''

    # Check if partial download exists
    if File.exist?(output) && File.size(output) > 0
      resume_flag = '-C -'
      log_verbose('Resuming partial download...')
    end

    # Check disk space
    log_verbose('Checking disk space...')
    file_size = get_url_file_size(url)

    if file_size > 0
      log_verbose("File size: #{format_bytes(file_size)}")
    else
      part_bytes = convert_size_to_bytes(CLONEZILLA_PART_SIZE)
      part_bytes = 600 * 1024 * 1024 if part_bytes <= 0
      file_size = part_bytes + (100 * 1024 * 1024)
      log_verbose("Could not determine file size, requiring #{format_bytes(file_size)} based on partition size")
    end

    log_verbose("Ensuring #{format_bytes(file_size)} free in #{output_dir} before download")
    return false unless check_disk_space(file_size, output_dir)

    print_status('INFO', "Downloading #{description}...", force_show: true)

      MAX_RETRIES.times do |i|
      print_status('WARNING', "Retry attempt #{i + 1}/#{MAX_RETRIES}...", force_show: true) if i > 0
      cmd = "curl -L -o #{output.shellescape} #{resume_flag} --progress-bar --max-time #{DOWNLOAD_TIMEOUT} #{url.shellescape}"
      system(cmd)
      status = $?
      if status.success? && File.exist?(output) && File.size(output) > 0
        return false unless verify_checksum(output, expected_checksum) if expected_checksum
        return true
      end
      log_verbose("Download failed (exit code: #{status.exitstatus})")
      sleep 5 if i < MAX_RETRIES - 1
      resume_flag = '-C -'
    end

    print_status('ERROR', "Failed to download #{description} after #{MAX_RETRIES} attempts")
    false
  end

  # Device Management
  def detect_clonezilla_drive(device)
    unless File.blockdev?(device)
      print_status('ERROR', "Device #{device} does not exist or is not a block device")
      return false
    end

    partitions = `lsblk -lnpo NAME,TYPE #{device.shellescape}`.lines
                     .select { |l| l.split[1] == 'part' }
                     .map { |l| l.split.first }

    if partitions.empty?
      print_status('ERROR', "No partitions found on device #{device}")
      return false
    end

    if partitions.length < 2
      print_status('ERROR', "Device #{device} does not have enough partitions (found #{partitions.length}, need at least 2)")
      return false
    end

    @part2 = partitions[1]
    fs_type = `blkid -s TYPE -o value #{@part2.shellescape} 2>/dev/null`.chomp

    unless %w[vfat fat32].include?(fs_type.downcase)
      print_status('ERROR', "Second partition on #{device} is not FAT32 (found: #{fs_type})")
      return false
    end

    log_verbose("Detected Clonezilla drive: #{device}")
    device_info = `lsblk -d -o NAME,SIZE,MODEL,VENDOR #{device.shellescape} 2>/dev/null`.chomp
    log_verbose("Device info: #{device_info}")
    log_verbose("Backup partition: #{@part2}")

    true
  end

  def is_removable_device?(device)
    sys_path = "/sys/block/#{File.basename(device)}/removable"
    return false unless File.exist?(sys_path)

    File.read(sys_path).chomp == '1'
  end

  def is_system_disk?(device)
    device_name = File.basename(device)
    system("mount | grep -q '^/dev/#{device_name}'") && system("mount | grep -q ' on / '")
  end

  def get_device_info(device)
    unless File.blockdev?(device)
      print_status('ERROR', "Device #{device} does not exist or is not a block device")
      print_status('ERROR', "Suggested fix: Check device name with 'lsblk' command")
      return false
    end

    if system("mount | grep -q #{device.shellescape}")
      print_status('ERROR', "Device #{device} is currently mounted. Please unmount it first.")
      print_status('ERROR', "Suggested fix: Run 'umount #{device}*' to unmount all partitions")
      return false
    end

    if is_system_disk?(device)
      print_status('WARNING', "Device #{device} may be the system disk!", force_show: true)
      print_status('WARNING', 'Continuing may cause data loss!', force_show: true)
      unless @skip_confirm
        print 'Continue anyway? (yes/no) [no]: '
        confirm = STDIN.gets.chomp
        return false unless confirm == 'yes'
      else
        log_verbose('Skipping confirmation (--yes flag used)')
      end
    end

    device_size = `lsblk -b -o SIZE -n -d #{device.shellescape} 2>/dev/null`.to_i

    if device_size < MIN_DEVICE_SIZE
      print_status('ERROR', "Device #{device} is too small. Minimum size required: #{format_bytes(MIN_DEVICE_SIZE)}")
      print_status('ERROR', "Device size: #{format_bytes(device_size)}")
      return false
    end

    log_verbose("Selected device: #{device}")
    device_info = `lsblk -d -o NAME,SIZE,MODEL,VENDOR #{device.shellescape} 2>/dev/null`.chomp
    log_verbose("Device info: #{device_info}")

    true
  end

  def list_devices
    puts
    printf "%-10s %-10s %-15s %-20s %-10s %s\n", 'DEVICE', 'SIZE', 'TYPE', 'MODEL', 'MOUNTED', 'NOTES'
    puts '---------------------------------------------------------------------------'
    `lsblk -d -o NAME,SIZE,TYPE,MODEL`.lines.each do |line|
      parts = line.split
      next unless parts[2] == 'disk'
      name, size, type = parts[0], parts[1], parts[2]
      model = parts[3..-1]&.join(' ') || 'Unknown'
      device = "/dev/#{name}"
      mounted = system("mount | grep -q '^#{device}'") ? 'YES' : 'NO'
      notes = []
      notes << '[USB/SD]' if is_removable_device?(device)
      notes << '[SYSTEM]' if is_system_disk?(device)
      printf "%-10s %-10s %-15s %-20s %-10s %s\n", name, size, type, model, mounted, notes.join
    end
    puts
  end

  def get_device_selection
    loop do
      list_devices

      if @backup_only
        print 'Enter the existing Clonezilla USB device (e.g., sda, sdb, mmcblk0): '
      else
        print 'Enter the device you want to use (e.g., sda, sdb, mmcblk0): '
      end

      device_input = STDIN.gets.chomp
      device_input = device_input.sub(%r{^/dev/}, '')
      @usb_device = "/dev/#{device_input}"

      if @backup_only
        break if detect_clonezilla_drive(@usb_device)
      else
        break if get_device_info(@usb_device)
      end

      puts
      print_status('ERROR', 'Invalid device. Please try again.')
    end
  end

  def confirm_device_wipe
    if @skip_confirm
      log_verbose('Skipping confirmation (--yes flag used)')
      log_verbose("This operation will ERASE ALL DATA on #{@usb_device}")
      return true
    end

    puts
    print_status('WARNING', "This operation will ERASE ALL DATA on #{@usb_device}", force_show: true)
    print_status('WARNING', 'This action cannot be undone!', force_show: true)

    print "Type 'YES' (in uppercase) to confirm: "
    confirm = STDIN.gets.chomp

    if confirm != 'YES'
      log_verbose('Operation canceled by user')
      exit 0
    end

    true
  end

  # Partitioning and Filesystem Operations
  def partition_device
    print_status('INFO', "Partitioning #{@usb_device}...", force_show: true)

    system("umount #{@usb_device}* >/dev/null 2>&1")

    log_verbose("Securely erasing the first 1MB of #{@usb_device}...")
    unless system("shred -n 1 -z -s 1M #{@usb_device.shellescape}")
      print_status('ERROR', 'Failed to shred device')
      return false
    end

    log_verbose('Creating GPT partition table...')
    unless system("parted -s #{@usb_device.shellescape} mklabel gpt")
      print_status('ERROR', 'Failed to create GPT label')
      return false
    end

    log_verbose('Creating partitions...')
    unless system("parted -s #{@usb_device.shellescape} mkpart primary fat32 1MiB #{CLONEZILLA_PART_SIZE}")
      print_status('ERROR', 'Failed to create first partition')
      return false
    end

    unless system("parted -s #{@usb_device.shellescape} mkpart primary fat32 #{CLONEZILLA_PART_SIZE} 100%")
      print_status('ERROR', 'Failed to create second partition')
      return false
    end

    unless system("parted -s #{@usb_device.shellescape} set 1 boot on")
      print_status('ERROR', 'Failed to set boot flag')
      return false
    end

    unless system("partprobe #{@usb_device.shellescape}")
      print_status('ERROR', 'Failed to update partition table')
      return false
    end

    sleep 5

    partitions = `lsblk -lnpo NAME,TYPE #{@usb_device.shellescape}`.lines
                     .select { |l| l.split[1] == 'part' }
                     .map { |l| l.split.first }

    @part1 = partitions[0]
    @part2 = partitions[1]

    if @part1.nil? || @part2.nil?
      print_status('ERROR', 'Could not determine partition names')
      return false
    end

    log_verbose("Partitioning completed - Partition 1: #{@part1}, Partition 2: #{@part2}")

    true
  end

  def create_filesystems
    log_verbose('Creating filesystems...')

    log_verbose('Creating filesystem on Clonezilla partition...')
    unless system("mkfs.vfat -F 32 #{@part1.shellescape} >/dev/null 2>&1")
      print_status('ERROR', 'Failed to create filesystem on first partition')
      return false
    end

    log_verbose('Creating filesystem on second partition...')
    unless system("mkfs.vfat -F 32 #{@part2.shellescape} >/dev/null 2>&1")
      print_status('ERROR', 'Failed to create filesystem on second partition')
      return false
    end

    log_verbose('Filesystems created successfully')
    true
  end

  # Clonezilla Setup
  def setup_clonezilla
    print_status('INFO', 'Setting up Clonezilla...', force_show: true)

    if @clonezilla_version.nil?
      log_verbose('Detecting latest Clonezilla version...')
      @clonezilla_version = get_latest_clonezilla_version
      if @clonezilla_version.nil?
        print_status('ERROR', 'Could not detect latest Clonezilla version')
        print_status('ERROR', 'Please specify version manually using -V or --version flag')
        return false
      end
      log_verbose("Detected latest Clonezilla version: #{@clonezilla_version}")
    else
      log_verbose("Using specified Clonezilla version: #{@clonezilla_version}")
    end

    clonezilla_url = build_clonezilla_url(@clonezilla_version)
    log_verbose("Clonezilla URL: #{clonezilla_url}")

    return false unless ensure_mount_point

    unless system("mount #{@part1.shellescape} #{MOUNT_POINT.shellescape}")
      print_status('ERROR', 'Failed to mount Clonezilla partition')
      return false
    end

    zip_path = File.join(@download_dir, ZIP_NAME)

    checksum = get_checksum_from_url(clonezilla_url)
    log_verbose('Found checksum for verification') if checksum

    return false unless download_file(clonezilla_url, zip_path, 'Clonezilla Live', checksum)

    log_verbose('Extracting Clonezilla...')
    unless system("unzip -q #{zip_path.shellescape} -d #{MOUNT_POINT.shellescape}")
      print_status('ERROR', 'Failed to extract Clonezilla')
      return false
    end

    unless system("umount #{MOUNT_POINT.shellescape}")
      print_status('ERROR', 'Failed to unmount Clonezilla partition')
      return false
    end

    File.delete(zip_path) if File.exist?(zip_path)
    log_verbose('Clonezilla setup completed')

    true
  end

  # Backup Setup
  def select_backup_source
    backup_input = nil

    puts
    puts 'Available backup options:'
    puts '  1) ASL3 Trixie Backup (Debian Trixie stable with ASL3)'
    puts '  2) Dell 3040 Backup (Debian 12 with ASL3)'
    puts '  3) Custom backup (URL or local file path)'

    loop do
      print 'Select backup option (1-3): '
      backup_choice = STDIN.gets.chomp

      case backup_choice
      when '1'
        backup_input = BACKUP_ASL3_TRIXIE_URL
        log_verbose('Selected: ASL3 Trixie Backup')
        break
      when '2'
        backup_input = BACKUP_DELL_3040_URL
        log_verbose('Selected: Dell 3040 Backup')
        break
      when '3'
        print 'Enter the URL or path of the backup file: '
        backup_input = STDIN.gets.chomp
        if backup_input.empty?
          print_status('ERROR', 'No backup file provided')
          next
        end
        break
      else
        print_status('ERROR', 'Invalid choice. Please enter 1, 2, or 3')
      end
    end

    backup_input
  end

  def setup_backup
    begin
      force_backup = false

      unless @backup_only
        puts
        print 'Would you like to add a backup from a zip file? (yes/no) [no]: '
        add_backup = STDIN.gets.chomp
        return true unless add_backup == 'yes'
      end

      backup_input = select_backup_source

      if backup_input.nil? || backup_input.empty?
        print_status('ERROR', 'No backup file provided, skipping backup setup')
        return true
      end

      print_status('INFO', 'Setting up backup...', force_show: true)

      return false unless ensure_mount_point

      unless @part2 && File.blockdev?(@part2)
        print_status('ERROR', "Backup partition not found: #{@part2}")
        return false
      end

    unless system("mount #{@part2.shellescape} #{MOUNT_POINT.shellescape}")
      print_status('ERROR', "Failed to mount backup partition")
      return false
    end

    backup_path = File.join(@download_dir, BACKUP_NAME)

    if is_url?(backup_input)
      download_result = download_file(backup_input, backup_path, 'backup file')
      
      unless download_result
        print_status('ERROR', 'Backup download failed')
        system("umount #{MOUNT_POINT.shellescape} >/dev/null 2>&1")
        return false
      end
      
      unless File.exist?(backup_path) && File.size(backup_path) > 0
        print_status('ERROR', 'Downloaded backup file is missing or empty')
        system("umount #{MOUNT_POINT.shellescape} >/dev/null 2>&1")
        return false
      end
    elsif is_local_file?(backup_input)
      print_status('INFO', "Copying backup from: #{backup_input}", force_show: true)
      unless copy_local_file(backup_input, backup_path, 'backup file')
        print_status('ERROR', 'Backup copy failed')
        system("umount #{MOUNT_POINT.shellescape} >/dev/null 2>&1")
        return false
      end
    else
      print_status('ERROR', "Invalid backup source: #{backup_input}")
      print_status('ERROR', 'Must be a valid URL (http://...) or local file path')
      system("umount #{MOUNT_POINT.shellescape} >/dev/null 2>&1")
      return false
    end

    print_status('INFO', 'Extracting backup...', force_show: true)
    
    unless File.exist?(backup_path) && File.readable?(backup_path)
      print_status('ERROR', "Backup file not accessible: #{backup_path}")
      system("umount #{MOUNT_POINT.shellescape} >/dev/null 2>&1")
      return false
    end
    output, status = Open3.capture2e("unzip -o #{backup_path.shellescape} -d #{MOUNT_POINT.shellescape} 2>&1")
    
    unless status.success?
      print_status('ERROR', 'Failed to extract backup')
      system("umount #{MOUNT_POINT.shellescape} >/dev/null 2>&1")
      return false
    end

    # Verify extraction completed
    sleep 1
    top_level_items = Dir.entries(MOUNT_POINT).reject { |f| f == '.' || f == '..' }
    
    if top_level_items.empty?
      print_status('ERROR', 'Backup extraction completed but no files found')
      system("umount #{MOUNT_POINT.shellescape} >/dev/null 2>&1")
      return false
    end

    system("sync")
    sleep 1

    begin
      Timeout.timeout(10) do
        system("umount #{MOUNT_POINT.shellescape} >/dev/null 2>&1")
      end
    rescue Timeout::Error
      system("umount -l #{MOUNT_POINT.shellescape} >/dev/null 2>&1")
    end

    File.delete(backup_path) if File.exist?(backup_path)
    print_status('SUCCESS', 'Backup setup completed', force_show: true)

    true
    rescue => e
      print_status('ERROR', "Backup setup failed: #{e.message}")
      system("umount #{MOUNT_POINT.shellescape} >/dev/null 2>&1")
      false
    end
  end

  # Command Line Interface
  def show_usage
    puts <<~USAGE
      Usage: #{File.basename(__FILE__)} [OPTIONS]

          Options:
          -h, --help          Show this help message
          -v, --verbose       Enable verbose output
          -l, --log-file      Specify log file (default: #{LOG_FILE})
          -b, --backup-only   Only add a backup to existing Clonezilla USB drive
          -V, --version VER    Specify Clonezilla version (default: auto-detect latest)
          -D, --download-dir DIR  Directory for downloads (default: #{DEFAULT_DOWNLOAD_DIR})
          -y, --yes            Skip confirmation prompts

      Description:
          This script downloads and sets up Clonezilla Live on a USB device.
          It creates two partitions: one for Clonezilla and one for backups.

      Examples:
          #{File.basename(__FILE__)}                    # Run with default settings (auto-detect latest version)
          #{File.basename(__FILE__)} -v                 # Run with verbose output
          #{File.basename(__FILE__)} --backup-only     # Only add backup to existing drive
          #{File.basename(__FILE__)} -V 3.2.0-5        # Use specific Clonezilla version
          #{File.basename(__FILE__)} -D /var/tmp        # Use different directory for downloads
          #{File.basename(__FILE__)} -y                # Skip confirmation prompts

    USAGE
  end

  def parse_arguments
    OptionParser.new do |opts|
      opts.banner = "Usage: #{File.basename(__FILE__)} [OPTIONS]"

      opts.on('-h', '--help', 'Show this help message') do
        show_usage
        exit 0
      end

      opts.on('-v', '--verbose', 'Enable verbose output') do
        @verbose = true
      end

      opts.on('-b', '--backup-only', 'Only add a backup to existing Clonezilla USB drive') do
        @backup_only = true
      end

      opts.on('-l', '--log-file FILE', 'Specify log file') do |file|
        @log_file = file
      end

      opts.on('-V', '--version VERSION', 'Specify Clonezilla version') do |version|
        @clonezilla_version = version
      end

      opts.on('-D', '--download-dir DIR', 'Directory for downloads') do |dir|
        @download_dir = dir
      end

      opts.on('-y', '--yes', 'Skip confirmation prompts') do
        @skip_confirm = true
      end
    end.parse!
  end

  # Main Function
  def run
    log_verbose('Starting Clonezilla setup script')
    log_verbose("Log file: #{@log_file}")

    parse_arguments

    unless Dir.exist?(@download_dir)
      print_status('ERROR', "Download directory does not exist: #{@download_dir}")
      exit 1
    end

    unless File.writable?(@download_dir)
      print_status('ERROR', "Download directory is not writable: #{@download_dir}")
      exit 1
    end

    log_verbose("Download directory: #{@download_dir}")

    check_root
    check_dependencies
    create_lock
    setup_signal_handlers

    if @backup_only
      log_verbose('BACKUP ONLY MODE - Will only add backup to existing drive')
    end

    unless @backup_only
      exit 1 unless check_internet
    end

    get_device_selection

    if @backup_only
      exit 1 unless setup_backup
    else
      exit 1 unless confirm_device_wipe
      exit 1 unless partition_device
      exit 1 unless create_filesystems
      exit 1 unless setup_clonezilla
      exit 1 unless setup_backup
    end

    @exit_code = 0
    print_status('SUCCESS', 'All operations completed successfully!', force_show: true)
  end
end

# Add shellescape method to String if not available
class String
  def shellescape
    "'#{gsub("'", "'\\''")}'"
  end
end

# Run main function
if __FILE__ == $PROGRAM_NAME
  begin
    setup = ClonezillaSetup.new
    setup.run
  rescue Interrupt
    puts "\n\nOperation cancelled by user."
    setup.instance_variable_set(:@exit_code, 1) if setup
    exit 1
  rescue => e
    puts "\n❌ Error: #{e.message}"
    puts e.backtrace if ENV['DEBUG']
    setup.instance_variable_set(:@exit_code, 1) if setup
    exit 1
  end
end

