# Copyright (c) 2012 National ICT Australia Limited (NICTA).
# This software may be used and distributed solely under the terms of the MIT license (License).
# You should find a copy of the License in LICENSE.TXT or at http://opensource.org/licenses/MIT.
# By downloading or using this software you accept the terms and the liability disclaimer in the License.

require 'monitor'
require 'securerandom'
require 'openssl'
require 'sourcify'

module OmfCommon
  class Comm
    class Topic

      @@name2inst = {}
      @@lock = Monitor.new
      @children = []
      @subtopics = []
      @root_resource = false

      def self.name2inst
        return @@name2inst
      end

      def self.create(name, opts = {}, &block)
        # Force string conversion as 'name' can be an ExperimentProperty
        routing_key_name = opts[:routing_key] ? opts[:routing_key].to_s : 'o.*'
        name = name.to_s.to_sym
        name2InstName = "#{name.to_s}-#{routing_key_name}".to_sym
        @@lock.synchronize do
          if @@name2inst[name2InstName]
            debug "Existing topic: #{name} | #{@@name2inst[name2InstName].routing_key} | #{name2InstName}"
            block.call(@@name2inst[name2InstName]) if block
          else
            debug "New topic: #{name} | #{opts[:routing_key]} | #{name2InstName}"
            #opts[:address] ||= address_for(name)
            @@name2inst[name2InstName] = self.new(name, opts, &block)
          end
          @root_resource = opts[:root_resource]
          unless @root_resource
            @@name2inst[name2InstName].on_inform do |msg|
              debug "#{name}: MESSAGE ON INFORM IS #{msg.itype}"
              case msg.itype
                when 'TOPIC.DELETED'
                  debug "MESSAGE TO DELETE TOPIC: #{msg[:topic]}"
                  @@name2inst[name2InstName].unsubscribe(msg[:topic], {:delete => true})
              end
            end
          end
          @@name2inst[name2InstName]
        end
      end

      def self.[](name)
        @@name2inst[name]
      end

      attr_reader :id, :routing_key, :children, :root_resource

      # Request the creation of a new resource. Returns itself
      #
      def create(res_type, config_props = {}, core_props = {}, &block)
        config_props[:type] ||= res_type
        config_props[:parent] ||= id
        debug "Create resource of type '#{res_type}', '#{self.address}'"
        create_message_and_publish(:create, config_props, core_props, block)
        self
      end

      def configure(props = {}, core_props = {}, &block)
        create_message_and_publish(:configure, props, core_props, block)
        self
      end

      def request(select = [], core_props = {}, &block)
        # TODO: What are the parameters to the request method really?
        create_message_and_publish(:request, select, core_props, block)
        self
      end

      def inform(type, props = {}, core_props = {}, &block)
        core_props[:src] ||= OmfCommon.comm.local_address
        msg = OmfCommon::Message.create(:inform, props, core_props.merge(itype: type))
        publish(msg, { routing_key: "o.info" }, &block)
        self
      end

      def release(resource, core_props = {}, &block)
        unless resource.is_a? self.class
          raise ArgumentError, "Expected '#{self.class}', but got '#{resource.class}'"
        end
        core_props[:src] ||= OmfCommon.comm.local_address
        debug "Release message: #{OmfCommon.comm.local_address}"
        msg = OmfCommon::Message.create(:release, {}, core_props.merge(res_id: resource.id))
        publish(msg, { routing_key: "o.op" }, &block)
        self
      end

      # Only used for create, configure and request
      def create_message_and_publish(type, props = {}, core_props = {}, block = nil)
        # debug "(#{id}) create_message_and_publish '#{type}': #{props.to_s}: #{core_props.to_s}"
        debug "(#{id}) create_message_and_publish '#{type}'"
        core_props[:src] ||= OmfCommon.comm.local_address
        msg = OmfCommon::Message.create(type, props, core_props)
        publish(msg, { routing_key: "o.op" }, &block)
      end

      def publish(msg, opts = {}, &block)
        error "!!!" if opts[:routing_key].nil?

        raise "Expected message but got '#{msg.class}" unless msg.is_a?(OmfCommon::Message)
        _send_message(msg, opts, block)
      end

      # TODO we should fix this long list related to INFORM messages
      # according to FRCP, inform types are (underscore form):
      # :creation_ok, :creation_failed, :status, :error, :warn, :released
      #
      # and we shall add :message for ALL types of messages.
      [:created,
       :create_succeeded, :create_failed,
       :inform_status, :inform_failed,
       :released, :failed,
       :creation_ok, :creation_failed, :status, :error, :warn
      ].each do |itype|
        mname = "on_#{itype}"
        define_method(mname) do |*args, &message_block|
          warn_deprecation(mname, :on_message, :on_inform)

          add_message_handler(itype, args.first, &message_block)
        end
      end

      def on_message(key = nil, &message_block)
        add_message_handler(:message, key, &message_block)
      end

      def on_inform(key = nil, &message_block)
        add_message_handler(:inform, key, &message_block)
      end

      # Remove all registered callbacks for 'key'. Will also unsubscribe from the underlying
      # comms layer if no callbacks remain.
      #
      def unsubscribe(key, opts={})
        @lock.synchronize do
          @handlers.clear
          @@name2inst.delete_if { |k, v| k == id.to_sym || k == address.to_sym}
        end
      end

      def on_subscribed(&block)
        raise NotImplementedError
      end

      # For detecting message publishing error, means if callback indeed yield a Topic object, there is no publishing error, thus always false
      def error?
        false
      end

      def address
        raise NotImplementedError
      end

      def after(delay_sec, &block)
        return unless block
        OmfCommon.eventloop.after(delay_sec) do
          block.arity == 1 ? block.call(self) : block.call
        end
      end

      def add_child(child_id)
        @lock.synchronize do
          @children << child_id
        end
      end

      def add_subtopic(topic_id)
        @lock.synchronize do
          @subtopics << topic_id
        end
      end

      private

      def initialize(id, opts = {})
        @id = id
        debug "OPTS IN INITIALIZE TOPIC = #{opts.to_yaml}"
        if opts[:parent]
          parent = opts[:parent].to_sym
          for name, topic in @@name2inst
            if topic.id == parent
              @@name2inst[name].add_child(id)
            end
          end
        end
        if opts[:parent_address]
          parent_address = opts[:parent_address] || "orphan"
          #parent_address = parent_address[:parent_address] if parent_address.is_a? Hash
          parent_address = parent_address.to_sym
          for name, topic in @@name2inst
            if topic.id == parent_address
              @@name2inst[name].add_subtopic(id)
            end
          end
        end
        #@address = opts[:address]
        @handlers = {}
        @lock = Monitor.new
        @context2cbk = {}
        @children = []
        @subtopics = []
        #@root_resource = false
        @root_resource = opts[:root_resource]
      end

      # _send_message will also register callbacks for reply messages by default
      #
      def _send_message(msg, opts = {}, block = nil)
        if (block)
          # register callback for responses to 'mid'
          # debug "(#{id}) register callback for responses to 'mid: #{msg.mid}'"
          debug "(#{id}) register callback for responses"
          @lock.synchronize do
            @context2cbk[msg.mid.to_s] = { block: block, created_at: Time.now }
          end
        end
      end

      # Process a message received from this topic.
      #
      # @param [OmfCommon::Message] msg Message received
      #
      def on_incoming_message(msg)
        type = msg.operation
        # debug "(#{id}) Deliver message '#{type}': #{msg.to_s}"
        debug "(#{id}) Deliver message '#{type}'"
        htypes = [type, :message]
        if type == :inform
          # TODO keep converting itype is painful, need to solve this.
          if (it = msg.itype(:ruby)) # format itype as lower case string
            case it
              when "creation_ok"
                htypes << :create_succeeded
              when 'status'
                htypes << :inform_status
            end

            htypes << it.to_sym
          end
        end

        # debug "(#{id}) Message type '#{htypes.inspect}' (#{msg.class}:#{msg.cid})"
        debug "(#{id}) Message type '#{htypes.inspect}'"
        hs = htypes.map { |ht| (@handlers[ht] || {}).values }.compact.flatten
        # debug "(#{id}) Distributing message to '#{hs.inspect}'"
        debug "(#{id}) Distributing message"
        hs.each do |block|
          block.call msg
        end
        if cbk = @context2cbk[msg.cid.to_s]
          # debug "(#{id}) Distributing message to '#{cbk.inspect}'"
          debug "(#{id}) Distributing message"
          cbk[:last_used] = Time.now
          cbk[:block].call(msg)
        end
      end

      def add_message_handler(handler_name, key, &message_block)
        raise ArgumentError, 'Missing message callback' if message_block.nil?
        debug "(#{id}) register handler for '#{handler_name}'"
        @lock.synchronize do
          key ||= OpenSSL::Digest::SHA1.new(message_block.source_location.to_s).to_s
          (@handlers[handler_name] ||= {})[key] = message_block
        end
        self
      end

    end
  end
end
