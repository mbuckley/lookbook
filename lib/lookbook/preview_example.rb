module Lookbook
  class PreviewExample < Entity
    attr_reader :name, :preview
    delegate :params, :position, :group, :notes, :hidden?, :source, :tags, :tag, to: :@example_inspector

    def initialize(name, preview)
      @name = name
      @preview = preview
      @example_inspector = SourceInspector.new("#{@preview.name}##{name}")
      super("#{@preview.path}/#{name}")
    end

    def id
      @example_inspector&.id || generate_id(@preview.id, name)
    end

    def url_path
      lookbook_inspect_path lookup_path
    end

    def label
      @example_inspector.label.presence || name.titleize
    end

    def display_params
      @preview.display_params.merge(@example_inspector.display_params)
    end

    def method_source
      @example_inspector.source.split("\n")[1..-2].join("\n").strip_heredoc
    end

    def lang
      Lookbook::Lang.find(:ruby)
    end

    def template_source(template_path)
      File.read(full_template_path(template_path))
    end

    def template_lang(template_path)
      Lookbook::Lang.guess(full_template_path(template_path)) || Lookbook::Lang.find(:html)
    end

    def type
      :example
    end

    def matchers
      normalize_matchers(@preview.label, label)
    end

    def hierarchy_depth
      @preview.hierarchy_depth + 1
    end

    protected

    def full_template_path(template_path)
      base_path = Array(Lookbook.config.preview_paths).detect do |p|
        Dir["#{p}/#{template_path}.html.*"].first
      end
      Pathname.new(Dir["#{base_path}/#{template_path}.html.*"].first)
    end

    class << self
      def all
        Preview.all.map { |preview| preview.examples }.flatten
      end

      def find(path)
        all.find { |p| p.lookup_path == path }
      end

      def exists?(path)
        !!find(path)
      end
    end

    alias_method :lookup_path, :path
  end
end
