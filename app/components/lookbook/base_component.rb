module Lookbook
  class BaseComponent < ViewComponent::Base
    include Lookbook::ComponentHelper

    def initialize(alpine_data: [], **html_attrs)
      @alpine_data ||= alpine_data
      @html_attrs = html_attrs
      @html_attrs[:class] = {"#{@html_attrs[:class]}": true} if @html_attrs[:class].is_a? String
    end

    def render_component_tag(tag = :div, **attrs, &block)
      merged_classes = class_names(attrs[:class], @html_attrs[:class])
      merged_attrs = @html_attrs.except(:class).deep_merge(attrs.except(:class))

      render Lookbook::TagComponent.new(tag: tag,
        name: component_name,
        **merged_attrs,
        "x-data": prepare_alpine_data(merged_attrs[:"x-data"]),
        class: merged_classes), &block
    end

    def component_name
      self.class.name.chomp("::Component").delete_prefix("Lookbook::").underscore.tr("/", "_").tr("_", "-")
    end

    protected

    attr_reader :alpine_data

    def alpine_component
      nil
    end

    def prepare_alpine_data(x_data = nil)
      alpine_component_name = x_data || @html_attrs&.dig(:"x-data") || alpine_component
      if alpine_component_name.present?
        args = Array.wrap(alpine_data)
        args.any? ? "#{alpine_component_name}(#{safe_join(args)})" : alpine_component_name
      end
    end
  end
end
