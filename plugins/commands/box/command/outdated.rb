# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: BUSL-1.1

require 'optparse'

require_relative 'download_mixins'

module VagrantPlugins
  module CommandBox
    module Command
      class Outdated < Vagrant.plugin("2", :command)
        include DownloadMixins

        def execute
          options = {}
          download_options = {}

          opts = OptionParser.new do |o|
            o.banner = "Usage: vagrant box outdated [options]"
            o.separator ""
            o.separator "Checks if there is a new version available for the box"
            o.separator "that you are using. If you pass in the --global flag,"
            o.separator "all boxes will be checked for updates."
            o.separator ""
            o.separator "Options:"
            o.separator ""

            o.on("--global", "Check all boxes installed") do |g|
              options[:global] = g
            end

            o.on("-f", "--force", "Force checks for latest box updates") do |f|
              options[:force] = f
            end

            build_download_options(o, download_options)
          end

          argv = parse_options(opts)
          return if !argv

          # If we're checking the boxes globally, then do that.
          if options[:global]
            outdated_global(download_options)
            return 0
          end

          with_target_vms(argv) do |machine|
            @env.action_runner.run(Vagrant::Action.action_box_outdated, {
              box_outdated_force: options[:force],
              box_outdated_refresh: true,
              box_outdated_success_ui: true,
              machine: machine,
            }.merge(download_options))
          end
          return 0
        end

        def outdated_global(download_options)
          @env.boxes.all.reverse.each do |name, version, provider|
            box = @env.boxes.find(name, provider, version)
            if !box&.metadata_url
              @env.ui.output(I18n.t(
                "vagrant.box_outdated_no_metadata",
                name: name,
                provider: provider))
              next
            end

            md = nil
            begin
              md = box.load_metadata(download_options)
            rescue Vagrant::Errors::BoxMetadataDownloadError => e
              @env.ui.error(I18n.t(
                "vagrant.box_outdated_metadata_error",
                name: box.name,
                provider: box.provider,
                message: e.extra_data[:message]))
              next
            end

            box_versions = md.versions(provider: box.provider, architecture: box.architecture)

            if box_versions.empty?
              latest_box_version = box_versions.last.to_i
            else
              latest_box_version = box_versions.last
            end

            if !md.compatible_version_update?(box.version, latest_box_version, provider: box.provider, architecture: box.architecture)
              @env.ui.success(I18n.t(
                "vagrant.box_up_to_date",
                name: box.name,
                provider: box.provider,
                version: box.version))
            else
              @env.ui.warn(I18n.t(
                "vagrant.box_outdated",
                name: box.name,
                provider: box.provider,
                current: box.version,
                latest: latest_box_version.to_s,))
            end
          end
        end
      end
    end
  end
end
