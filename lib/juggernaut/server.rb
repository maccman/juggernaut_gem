require 'eventmachine'
require 'socket'
require 'json'
require 'open-uri'
require 'fileutils'
require 'digest/sha1'

module Juggernaut
  class Server < EventMachine::Connection
    include Juggernaut::Miscel
    
    class InvalidRequest < Juggernaut::JuggernautError #:nodoc:
    end

    class InvalidCommand < Juggernaut::JuggernautError #:nodoc:
    end

    class CorruptJSON < Juggernaut::JuggernautError #:nodoc:
    end

    class MalformedBroadcast < Juggernaut::JuggernautError #:nodoc:
    end

    class MalformedSubscribe < Juggernaut::JuggernautError #:nodoc:
    end

    class UnauthorisedSubscription < Juggernaut::JuggernautError #:nodoc:
    end

    class MalformedQuery < Juggernaut::JuggernautError #:nodoc:
    end

    class UnauthorisedBroadcast < Juggernaut::JuggernautError #:nodoc:
    end

    class UnauthorisedQuery < Juggernaut::JuggernautError #:nodoc:
    end

    POLICY_FILE = <<-EOF
      <cross-domain-policy>
        <allow-access-from domain="*" to-ports="PORT" />
      </cross-domain-policy>
    EOF

    POLICY_REQUEST = "<policy-file-request/>"

    CR              = "\0"
    
    attr_reader   :current_msg_id
    attr_reader   :messages
    attr_reader   :connected
    attr_reader   :logout_timeout
    attr_reader   :status
    attr_reader   :channels
    attr_reader   :client

    # EM methods
    
    def post_init
      logger.debug "New client [#{client_ip}]"
      @client         = nil
      @channels       = []
      @current_msg_id = 0
      @connected      = true
      @logout_timeout = nil
      @buffer = ''
    end
    
    # Juggernaut packets are terminated with "\0"
    # so we need to buffer the data until we find the
    # terminating "\0"
    def receive_data(data)
      @buffer << data
      @buffer = process_whole_messages(@buffer)
    end
    
    # process any whole messages in the buffer,
    # and return the new contents of the buffer
    def process_whole_messages(data)
      return data if data !~ /\0/ # only process if data contains a \0 char
      messages = data.split("\0")
      if data =~ /\0$/
        data = ''
      else
        # remove the last message from the list (because it is incomplete) before processing
        data = messages.pop
      end
      messages.each {|message| process_message(message.strip)}
      return data
    end
    
    def process_message(ln)
      logger.debug "Processing message: #{ln}"
      @request        = nil
      
      if ln == POLICY_REQUEST
        logger.debug "Sending crossdomain file"
        send_data POLICY_FILE.gsub('PORT', (options[:public_port]||options[:port]).to_s)
        close_connection_after_writing
        return
      end
      
      begin
        @request = JSON.parse(ln) unless ln.empty?
      rescue
        raise CorruptJSON, ln
      end
      
      raise InvalidRequest, ln if !@request
      
      @request.symbolize_keys!
      
      # For debugging
      @request[:ip] = client_ip
      
      @request[:channels] = (@request[:channels] || []).compact.select {|c| !!c && c != '' }.uniq
      
      if @request[:client_ids] 
        @request[:client_ids] = @request[:client_ids].to_a.compact.select {|c| !!c && c != '' }.uniq
      end
      
      case @request[:command].to_sym
        when :broadcast
          broadcast_command
        when :subscribe
          subscribe_command
        when :query
          query_command
        when :noop
          noop_command
      else
        raise InvalidCommand, @request
      end
    
    rescue JuggernautError => e
      logger.error("#{e} - #{e.message.inspect}")
      close_connection
    # So as to stop em quitting
    rescue => e
      logger ? logger.error(e) : puts(e)
    end
    
    def unbind
      if @client
        # todo - should be called after timeout?
        @client.logout_connection_request(@channels)
        logger.debug "Lost client #{@client.friendly_id}"
      end
      mark_dead('Unbind called')
    end
    
    # As far as I'm aware, send_data
    # never throws an exception
    def publish(msg)
      logger.debug "Sending msg: #{msg.to_s} to client #{@request[:client_id]} (session #{@request[:session_id]})"
      send_data(msg.to_s + CR)
    end
    
    # Connection methods
    
    def broadcast(bdy)
      msg = Juggernaut::Message.new(@current_msg_id += 1, bdy, self.signature)
      publish(msg)
    end
    
    def mark_dead(reason = "Unknown error")
      # Once dead, a client never recovers since a reconnection
      # attempt would hook onto a new em instance. A client
      # usually dies through an unbind 
      @connected = false
      @client.remove_connection(self) if @client
    end
    
    def alive?
      @connected == true
    end
    
    def has_channels?(channels)
      channels.each {|channel|
        return true if has_channel?(channel)
      }
      false
    end
    
    def has_channel?(channel)
      @channels.include?(channel)
    end
    
    def add_channel(chan_name)
      return if !chan_name or chan_name == ''
      @channels << chan_name unless has_channel?(chan_name)
    end
    
    def add_channels(chan_names)
      chan_names.to_a.each do |chan_name|
        add_channel(chan_name)
      end
    end
    
    def remove_channel!(chan_name)
      @channels.delete(chan_name)
    end
    
    def remove_channels!(chan_names)
      chan_names.to_a.each do |chan_name|
        remove_channel!(chan_name)
      end
    end
    
    protected
    
      # Commands
    
      def broadcast_command
        raise MalformedBroadcast, @request unless @request[:type]

        raise UnauthorisedBroadcast, @request unless authenticate_broadcast_or_query
        
        case @request[:type].to_sym
          when :to_channels
            # if channels is a blank array, sends to everybody!
            broadcast_to_channels(@request[:body], @request[:channels])
          when :to_clients
            broadcast_needs :client_ids
            @request[:client_ids].each do |client_id|
              # if channels aren't empty, scopes broadcast to clients on those channels
              broadcast_to_client(@request[:body], client_id, @request[:channels])
            end
        else
          raise MalformedBroadcast, @request
        end
      end
      
      def query_command
        raise MalformedQuery, @request unless @request[:type]
              
        raise UnauthorisedQuery, @request unless authenticate_broadcast_or_query
              
        case @request[:type].to_sym
          when :remove_channels_from_all_clients
            query_needs :channels
            clients = Juggernaut::Client.find_all
            clients.each {|client| client.remove_channels!(@request[:channels]) }
          when :remove_channels_from_client
            query_needs :client_ids, :channels
            @request[:client_ids].each do |client_id|
              client = Juggernaut::Client.find_by_id(client_id)
              client.remove_channels!(@request[:channels]) if client
            end
          when :show_channels_for_client
            query_needs :client_id
            if client = Juggernaut::Client.find_by_id(@request[:client_id])
              publish client.channels.to_json
            else
              publish nil.to_json
            end
          when :show_clients
            if @request[:client_ids] and @request[:client_ids].any?
              clients = @request[:client_ids].collect{ |client_id| Client.find_by_id(client_id) }.compact.uniq
            else
              clients = Juggernaut::Client.find_all
            end
            publish clients.to_json
          when :show_client
            query_needs :client_id
            publish Juggernaut::Client.find_by_id(@request[:client_id]).to_json
          when :show_clients_for_channels
            query_needs :channels
            publish Juggernaut::Client.find_by_channels(@request[:channels]).to_json
        else
          raise MalformedQuery, @request
        end
      end
    
      def noop_command
        logger.debug "NOOP"
      end
    
      def subscribe_command
        logger.debug "SUBSCRIBE: #{@request.inspect}"
        
        if channels = @request[:channels]
          add_channels(channels)
        end
        
        @client = Juggernaut::Client.find_or_create(self, @request)
        
        if !@client.subscription_request(@channels)
          raise UnauthorisedSubscription, @client
        end
        
        if options[:store_messages]
          @client.send_queued_messages(self)
        end
      end
    
    private
    
      # Different broadcast types
    
      def broadcast_to_channels(msg, channels = [])
        Juggernaut::Client.find_all.each {|client| client.send_message(msg, channels) }
      end
      
      def broadcast_to_client(body, client_id, channels)
        client = Juggernaut::Client.find_by_id(client_id)
        client.send_message(body, channels) if client
      end
      
      # Helper methods
      
      def broadcast_needs(*args)
        args.each do |arg|
          raise MalformedBroadcast, @request unless @request.has_key?(arg)
        end
      end
      
      def subscribe_needs(*args)
        args.each do |arg|
          raise MalformedSubscribe, @request unless @request.has_key?(arg)
        end
      end
      
      def query_needs(*args)
        args.each do |arg|
          raise MalformedQuery, @request unless @request.has_key?(arg)
        end
      end
      
      def authenticate_broadcast_or_query
        if options[:allowed_ips]
          return true if options[:allowed_ips].include?(client_ip)
        elsif !@request[:secret_key]
          return true if broadcast_query_request
        elsif options[:secret_key]
          return true if @request[:secret_key] == options[:secret_key]
        end
        if !options[:allowed_ips] and !options[:secret_key] and !options[:broadcast_query_login_url]
          return true
        end
        false
      end
      
      def broadcast_query_request
        return false unless options[:broadcast_query_login_url]
        url = URI.parse(options[:broadcast_query_login_url])
        params = []
        params << "client_id=#{@request[:client_id]}" if @request[:client_id]
        params << "session_id=#{URI.escape(@request[:session_id])}" if @request[:session_id]
        params << "type=#{@request[:type]}"
        params << "command=#{@request[:command]}"
        (@request[:channels] || []).each {|chan| params << "channels[]=#{chan}" }
        url.query = params.join('&')
        begin
          open(url.to_s, "User-Agent" => "Ruby/#{RUBY_VERSION}")
        rescue Timeout::Error
          return false
        rescue
          return false
        end
        true
      end
      
      def client_ip
        Socket.unpack_sockaddr_in(get_peername)[1] rescue nil
      end
  end
end
