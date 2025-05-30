# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: BUSL-1.1

require 'fileutils'
require "tempfile"

require "json"
require "log4r"

require "vagrant/box_metadata"
require "vagrant/util/downloader"
require "vagrant/util/platform"
require "vagrant/util/safe_chdir"
require "vagrant/util/subprocess"

module Vagrant
  # Represents a "box," which is a package Vagrant environment that is used
  # as a base image when creating a new guest machine.
  class Box
    include Comparable

    # The required fields in a boxes `metadata.json` file
    REQUIRED_METADATA_FIELDS = ["provider"]

    # Number of seconds to wait between checks for box updates
    BOX_UPDATE_CHECK_INTERVAL = 3600

    # The box name. This is the logical name used when adding the box.
    #
    # @return [String]
    attr_reader :name

    # This is the provider that this box is built for.
    #
    # @return [Symbol]
    attr_reader :provider

    # This is the architecture that this box is build for.
    #
    # @return [String]
    attr_reader :architecture

    # The version of this box.
    #
    # @return [String]
    attr_reader :version

    # This is the directory on disk where this box exists.
    #
    # @return [Pathname]
    attr_reader :directory

    # This is the metadata for the box. This is read from the "metadata.json"
    # file that all boxes require.
    #
    # @return [Hash]
    attr_reader :metadata

    # This is the URL to the version info and other metadata for this
    # box.
    #
    # @return [String]
    attr_reader :metadata_url

    # This is used to initialize a box.
    #
    # @param [String] name Logical name of the box.
    # @param [Symbol] provider The provider that this box implements.
    # @param [Pathname] directory The directory where this box exists on
    #   disk.
    # @param [String] architecture Architecture the box was built for
    # @param [String] metadata_url Metadata URL for box
    # @param [Hook] hook A hook to apply to the box downloader, for example, for authentication
    def initialize(name, provider, version, directory, architecture: nil, metadata_url: nil, hook: nil)
      @name      = name
      @version   = version
      @provider  = provider
      @directory = directory
      @architecture = architecture
      @metadata_url = metadata_url
      @hook = hook

      metadata_file = directory.join("metadata.json")
      raise Errors::BoxMetadataFileNotFound, name: @name if !metadata_file.file?

      begin
        @metadata = JSON.parse(directory.join("metadata.json").read)
        validate_metadata_json(@metadata)
      rescue JSON::ParserError
        raise Errors::BoxMetadataCorrupted, name: @name
      end

      @logger = Log4r::Logger.new("vagrant::box")
    end

    def validate_metadata_json(metadata)
      metatdata_fields = metadata.keys
      REQUIRED_METADATA_FIELDS.each do |field|
        if !metatdata_fields.include?(field)
          raise Errors::BoxMetadataMissingRequiredFields,
            name: @name,
            required_field: field,
            all_fields: REQUIRED_METADATA_FIELDS.join(", ")
        end
      end
    end

    # This deletes the box. This is NOT undoable.
    def destroy!
      # Delete the directory to delete the box.
      FileUtils.rm_r(@directory)

      # Just return true always
      true
    rescue Errno::ENOENT
      # This means the directory didn't exist. Not a problem.
      return true
    end

    # Checks if this box is in use according to the given machine
    # index and returns the entries that appear to be using the box.
    #
    # The entries returned, if any, are not tested for validity
    # with {MachineIndex::Entry#valid?}, so the caller should do that
    # if the caller cares.
    #
    # @param [MachineIndex] index
    # @return [Array<MachineIndex::Entry>]
    def in_use?(index)
      results = []
      index.each do |entry|
        box_data = entry.extra_data["box"]
        next if !box_data

        # If all the data matches, record it
        if box_data["name"] == self.name &&
          box_data["provider"] == self.provider.to_s &&
          box_data["architecture"] == self.architecture &&
          box_data["version"] == self.version.to_s
          results << entry
        end
      end

      return nil if results.empty?
      results
    end

    # Loads the metadata URL and returns the latest metadata associated
    # with this box.
    #
    # @param [Hash] download_options Options to pass to the downloader.
    # @return [BoxMetadata]
    def load_metadata(download_options={})
      tf = Tempfile.new("vagrant-load-metadata")
      tf.close

      url = @metadata_url
      if File.file?(url) || url !~ /^[a-z0-9]+:.*$/i
        url = File.expand_path(url)
        url = Util::Platform.cygwin_windows_path(url)
        url = "file:#{url}"
      end

      opts = { headers: ["Accept: application/json"] }.merge(download_options)
      d = Util::Downloader.new(url, tf.path, opts)
      if @hook
        @hook.call(:authenticate_box_downloader, downloader: d)
      end
      d.download!
      BoxMetadata.new(File.open(tf.path, "r"), url: url)
    rescue Errors::DownloaderError => e
      raise Errors::BoxMetadataDownloadError,
        message: e.extra_data[:message]
    ensure
      tf.unlink if tf
    end

    # Checks if the box has an update and returns the metadata, version,
    # and provider. If the box doesn't have an update that satisfies the
    # constraints, it will return nil.
    #
    # This will potentially make a network call if it has to load the
    # metadata from the network.
    #
    # @param [String] version Version constraints the update must
    #   satisfy. If nil, the version constrain defaults to being a
    #   larger version than this box.
    # @return [Array]
    def has_update?(version=nil, download_options: {})
      if !@metadata_url
        raise Errors::BoxUpdateNoMetadata, name: @name
      end

      if download_options.delete(:automatic_check) && !automatic_update_check_allowed?
        @logger.info("Skipping box update check")
        return
      end

      version += ", " if version
      version ||= ""
      version += "> #{@version}"
      md      = self.load_metadata(download_options)
      newer   = md.version(version, provider: @provider, architecture: @architecture)
      
      return nil if newer == nil || !md.compatible_version_update?(@version, newer.version, provider: @provider, architecture: @architecture)

      [md, newer, newer.provider(@provider, @architecture)]
    end

    # Check if a box update check is allowed. Uses a file
    # in the box data directory to track when the last auto
    # update check was performed and returns true if the
    # BOX_UPDATE_CHECK_INTERVAL has passed.
    #
    # @return [Boolean]
    def automatic_update_check_allowed?
      check_path = directory.join("box_update_check")
      if check_path.exist?
        last_check_span = Time.now.to_i - check_path.mtime.to_i
        if last_check_span < BOX_UPDATE_CHECK_INTERVAL
          @logger.info("box update check is under the interval threshold")
          return false
        end
      end
      FileUtils.touch(check_path)
      true
    end

    # This repackages this box and outputs it to the given path.
    #
    # @param [Pathname] path The full path (filename included) of where
    #   to output this box.
    # @return [Boolean] true if this succeeds.
    def repackage(path)
      @logger.debug("Repackaging box '#{@name}' to: #{path}")

      Util::SafeChdir.safe_chdir(@directory) do
        # Find all the files in our current directory and tar it up!
        files = Dir.glob(File.join(".", "**", "*")).select { |f| File.file?(f) }

        # Package!
        Util::Subprocess.execute("bsdtar", "-czf", path.to_s, *files)
      end

      @logger.info("Repackaged box '#{@name}' successfully: #{path}")

      true
    end

    # Implemented for comparison with other boxes. Comparison is
    # implemented by comparing names, providers, and architectures.
    def <=>(other)
      return super if !other.is_a?(self.class)

      # Comparison is done by composing the name and provider
      "#{@name}-#{@version}-#{@provider}-#{@architecture}" <=>
      "#{other.name}-#{other.version}-#{other.provider}-#{other.architecture}"
    end
  end
end
