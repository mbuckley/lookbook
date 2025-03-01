require "view_component"
require "action_cable/engine"
require "listen"

module Lookbook
  autoload :Config, "lookbook/config"
  autoload :Data, "lookbook/data"
  autoload :Hooks, "lookbook/hooks"
  autoload :Panels, "lookbook/panels"
  autoload :Tags, "lookbook/tags"

  class << self
    include Lookbook::Data
    include Lookbook::Hooks
    include Lookbook::Panels
    include Lookbook::Tags

    def version
      Lookbook::VERSION
    end

    def config
      @config ||= Config.new
    end

    def configure
      yield(config)
    end

    def logger
      @logger ||= Rails.env.development? ? Logger.new($stdout) : Rails.logger
    end

    def debug_data
      {
        version: version,
        env: Rails.env.to_s,
        config: config
      }
    end

    def previews
      Preview.all
    end

    def previews?
      Preview.any?
    end

    def pages
      Page.all
    end

    def pages?
      Page.any?
    end

    def broadcast(event_name, data = {})
      Engine.websocket&.broadcast(event_name.to_s, data)
    end

    def theme
      @theme ||= Lookbook::Theme.new(config.ui_theme, config.ui_theme_overrides)
    end
  end

  class Engine < Rails::Engine
    isolate_namespace Lookbook

    config.lookbook = Lookbook.config
    config.autoload_paths << File.expand_path(Lookbook::Engine.root.join("app/components"))

    initializer "lookbook.viewcomponent.config" do
      config.lookbook.preview_paths += config.view_component.preview_paths
      config.lookbook.preview_controller ||= config.view_component.preview_controller

      config.lookbook.components_path = config.view_component.view_component_path if config.view_component.view_component_path.present?

      config.lookbook.listen_paths += config.lookbook.preview_paths
      config.lookbook.listen_paths << config.lookbook.components_path
    end

    initializer "lookbook.logging.development" do
      Lookbook.logger.level = Lookbook.config.log_level if Rails.env.development?
    end

    initializer "lookbook.parser.tags" do
      Lookbook::Parser.define_tags(Lookbook.config.preview_tags)
    end

    initializer "lookbook.assets.serve" do
      config.app_middleware.use(
        Rack::Static,
        urls: ["/lookbook-assets"], root: Lookbook::Engine.root.join("public").to_s
      )
    end

    config.after_initialize do
      @preview_controller = Lookbook.config.preview_controller.constantize
      @preview_controller.include(Lookbook::PreviewController)

      if Gem::Version.new(Rails.version) >= Gem::Version.new("6.1.3.1")
        # Rails.application.server is only available for newer Rails versions
        Rails.application.server do
          init_listeners
        end
      else
        # Fallback for older Rails versions - don't start listeners if running in a rake task.
        unless Lookbook::Engine.prevent_listening?
          init_listeners
        end
      end

      if config.lookbook.runtime_parsing
        Lookbook::Engine.parser.parse
      else
        unless File.exist?(config.lookbook.parser_registry_path)
          Lookbook.logger.warn "
            Runtime parsing is disabled but no registry file has been found.
            Did you run `rake lookbook:preparse` before starting the app?
            Expected to find registry file at #{config.lookbook.parser_registry_path}
          "
        end
      end

      Lookbook::Engine.run_hooks(:after_initialize)
    end

    at_exit do
      if Lookbook::Engine.listeners.any?
        Lookbook.logger.debug "Stopping listeners"
        Lookbook::Engine.stop_listeners
      end
      Lookbook::Engine.run_hooks(:before_exit)
    end

    class << self
      def init_listeners
        config = Lookbook.config
        return unless config.listen == true
        Listen.logger = Lookbook.logger

        preview_listener = Listen.to(
          *config.listen_paths,
          only: /\.(#{config.listen_extensions.join("|")})$/,
          force_polling: config.listen_use_polling
        ) do |modified, added, removed|
          changes = {modified: modified, added: added, removed: removed}
          begin
            parser.parse
          rescue
          end
          Lookbook::Preview.clear_cache
          reload_ui(changes)
          run_hooks(:after_change, changes)
        end
        register_listener(preview_listener)

        page_listener = Listen.to(
          *config.page_paths,
          only: /\.(html.*|md.*)$/,
          force_polling: config.listen_use_polling
        ) do |modified, added, removed|
          changes = {modified: modified, added: added, removed: removed}
          reload_ui(changes)
          run_hooks(:after_change, changes)
        end
        register_listener(page_listener)
      end

      def websocket
        config = Lookbook.config
        return @websocket unless @websocket.nil?
        return unless config.auto_refresh == true && !Rails.env.test?
        Lookbook.logger.info "Initializing websocket"

        cable = ActionCable::Server::Configuration.new
        cable.cable = {adapter: "async"}.with_indifferent_access
        cable.mount_path = config.cable_mount_path
        cable.connection_class = -> { Lookbook::Connection }
        cable.logger = config.cable_logger

        @websocket ||= if Gem::Version.new(Rails.version) >= Gem::Version.new(6.0)
          ActionCable::Server::Base.new(config: cable)
        else
          ws = ActionCable::Server::Base.new
          ws.config = cable
          ws
        end
      end

      def websocket_mount_path
        "#{mounted_path}#{config.lookbook.cable_mount_path}" if websocket?
      end

      def websocket?
        websocket.present?
      end

      def mounted_path
        Lookbook::Engine.routes.find_script_name({})
      end

      def parser
        @parser ||= Lookbook::Parser.new(config.lookbook.preview_paths, config.lookbook.parser_registry_path)
      end

      def log_level
        Lookbook.logger.level
      end

      def app_name
        name = if Gem::Version.new(Rails.version) >= Gem::Version.new("6.1")
          Rails.application.class.module_parent_name
        else
          Rails.application.class.parent_name
        end
        name.underscore
      end

      def register_listener(listener)
        listener.start
        listeners << listener
      end

      def listeners
        @listeners ||= []
      end

      def stop_listeners
        listeners.each { |listener| listener.stop }
      end

      def run_hooks(event_name, *args)
        config.lookbook.hooks[event_name].each do |hook|
          hook.call(Lookbook, *args)
        end
      end

      def reload_ui(changed = {})
        websocket&.broadcast("reload", changed)
      end

      def prevent_listening?
        Rails.env.test? || running_in_rake_task?
      end

      def running_in_rake_task?
        if defined?(Rake) && Rake.respond_to?(:application)
          File.basename($0) == "rake" || Rake.application.top_level_tasks.any?
        else
          false
        end
      end

      attr_reader :preview_controller
    end
  end
end
