module VagrantPlugins
  module CommandServe
    module Util
      # Adds service info helper to be used with services
      module ServiceInfo
        def with_info(context, broker:, &block)
          if !context.metadata["plugin_name"]
            raise KeyError,
              "plugin name not defined (metadata content: #{context.metadata.inspect})"
          end

          info = Service::ServiceInfo.new(
            plugin_name: context.metadata["plugin_name"],
            broker: broker
          )
          if context.metadata["plugin_manager"] && info.broker
            Service::ServiceInfo.manager_tracker.activate do
              info.plugin_manager = Client::PluginManager.load(
                context.metadata["plugin_manager"],
                broker: info.broker
              )
              Vagrant.plugin("2").enable_remote_manager
            end
          end
          Thread.current.thread_variable_set(:service_info, info)
          return if !block_given?
          yield info
        ensure
          Service::ServiceInfo.manager_tracker.deactivate do
            Vagrant.plugin("2").disable_remote_manager
          end
          Thread.current.thread_variable_set(:service_info, nil)
        end

        def with_plugin(context, plugins, broker:, &block)
          if !context.metadata["plugin_name"]
            raise KeyError,
              "plugin name not defined (metadata content: #{context.metadata.inspect})"
          end

          info = Service::ServiceInfo.new(
            plugin_name: context.metadata["plugin_name"],
            broker: broker
          )
          if context.metadata["plugin_manager"] && info.broker
            Service::ServiceInfo.manager_tracker.activate do
              info.plugin_manager = Client::PluginManager.load(
                context.metadata["plugin_manager"],
                broker: info.broker
              )
              Vagrant.plugin("2").enable_remote_manager
            end
          end
          Thread.current.thread_variable_set(:service_info, info)
          return if !block_given?
          plugin_name = info.plugin_name
          plugin = plugins[plugin_name.to_s.to_sym].to_a.first
          if !plugin
            logger.debug("Failed to locate plugin for: #{plugin_name} in list: #{plugins.keys}")
            raise "Failed to locate plugin for: #{plugin_name.inspect}"
          end
          yield plugin
        ensure
          Service::ServiceInfo.manager_tracker.deactivate do
            Vagrant.plugin("2").disable_remote_manager
          end
          Thread.current.thread_variable_set(:service_info, nil)
        end
      end
    end
  end
end
