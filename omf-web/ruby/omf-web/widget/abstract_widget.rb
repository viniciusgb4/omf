
require 'erector'

module OMF::Web::Widget
  
  # Maintains the context for a particular code rendering within a specific session.
  #
  class AbstractWidget < Erector::Widget
    
    @@widgets = {}
    
    def self.register_widget(wdescr)
      id = (wdescr[:id] ||= "w#{wdescr.object_id}").to_sym
      if (@@widgets.key? id)
        raise "Repeated try to register widget '#{id}'"
      end  
      @@widgets[id] = wdescr
    end
    
    def self.registered_widgets()
      @@widgets
    end
    
    def self.create_widget(name)
      if name.is_a? Array
        require 'omf-web/widget/stacked_widget'
        return OMF::Web::Widget::StackedWidget.new(name)        
      end
      unless wdescr = @@widgets[name.to_sym]
        raise "Can't create unknown widget '#{name}':(#{@@widgets.keys.inspect})"
      end
      case type = wdescr[:type].to_sym
      when :data
        require 'omf-web/widget/graph/graph_widget'
        OMF::Web::Widget::Graph::GraphWidget.new(wdescr)
      when :stacked
        require 'omf-web/widget/stacked_widget'
        return OMF::Web::Widget::StackedWidget.new(wdescr)        
      else
        raise "Unknown widget type '#{type}'"
      end
    end
    
    attr_reader :widget_id, :widget_type, :name, :opts
    
    def initialize(opts = {})
      @opts = opts
      @widget_id = "w#{object_id}"
      @name = opts[:name] || 'Unknown: Set opts[:name]'
      @widget_type = opts[:type] || 'unknown'
      OMF::Web::SessionStore[@widget_id, :w] = self
    end

    # Return html for an optional widget tools menu to be added
    # to the widget decoration by the theme.
    # 
    def tools_menu()
      # Nothing
    end
    
        
  end # class
end # OMF::Web::Widget