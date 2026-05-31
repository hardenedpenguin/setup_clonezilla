#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../setup_clonezilla'

class TestClonezillaSetup < Minitest::Test
  def setup
    @setup = ClonezillaSetup.new
  end

  def test_valid_disk_name
    assert @setup.valid_disk_name?('sdb')
    assert @setup.valid_disk_name?('mmcblk0')
    assert @setup.valid_disk_name?('nvme0n1')
    refute @setup.valid_disk_name?('sdb1')
    refute @setup.valid_disk_name?('../sdb')
    refute @setup.valid_disk_name?('')
  end

  def test_normalize_device_path
    assert_equal '/dev/sdb', @setup.normalize_device_path('sdb')
    assert_equal '/dev/sdb', @setup.normalize_device_path('/dev/sdb')
    assert_nil @setup.normalize_device_path('sdb1')
  end

  def test_format_bytes
    assert_equal '512KB', @setup.format_bytes(512 * 1024)
    assert_equal '1GB', @setup.format_bytes(1024**3)
  end

  def test_convert_size_to_bytes
    assert_equal 513 * 1024**2, @setup.convert_size_to_bytes('513M')
    assert_equal 0, @setup.convert_size_to_bytes('invalid')
  end

  def test_sort_clonezilla_versions
    versions = %w[3.1.0-10 3.2.0-5 3.1.0-9 3.10.0-1]
    assert_equal '3.10.0-1', @setup.sort_clonezilla_versions(versions)
  end

  def test_build_clonezilla_url
    @setup.instance_variable_set(:@arch, 'amd64')
    url = @setup.build_clonezilla_url('3.2.0-5')
    assert_includes url, 'clonezilla-live-3.2.0-5-amd64.zip'
  end

  def test_is_url
    assert @setup.is_url?('https://example.com/file.zip')
    refute @setup.is_url?('/tmp/file.zip')
  end
end
