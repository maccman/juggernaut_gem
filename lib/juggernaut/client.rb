require 'timeout'
require 'net/http'
require 'net/https'
require 'uri'

module Juggernaut
  class Client
    include Juggernaut::Miscel

    @@clients = [ ]

    attr_reader   :id
    attr_accessor :session_id
    attr_reader   :connections

    class << self
      # Actually does a find_or_create_by_id
      def find_or_create(subscriber, request)
        if client = find_by_id(request[:client_id])
          client.session_id = request[:session_id]
          client.add_new_connection(subscriber)
          client
        else
          self.new(subscriber, request)
        end
      end

      # Client find methods
      def find_all
        @@clients
      end

      def find(&block)
        @@clients.select(&block).uniq
      end

      def find_by_id(id)
        find { |client| client.id == id }.first
      end

      def find_by_signature(signature)
        # signature should be unique
        find do |client| 
          client.connections.select { |connection| connection.signature == signature }.any?
        end.first
      end

      def find_by_channels(channels)
        find do |client| 
          client.has_channels?(channels)
        end
      end

      def find_by_id_and_channels(id, channels)
        find do |client| 
          client.has_channels?(channels) && client.id == id
        end.first
      end

      def send_logouts_after_timeout
        @@clients.each do |client|
          if client.give_up?
            client.logout_request
          end
        end
      end

      # Called when the server is shutting down
      def send_logouts_to_all_clients
        @@clients.each do |client|
          client.logout_request
        end
      end

      def reset!
        @@clients.clear
      end

      def register_client(client)
        @@clients << client unless @@clients.include?(client)
      end

      def client_registered?(client)
        @@clients.include?(client)
      end

      def unregister_client(client)
        @@clients.delete(client)
      end
    end

    def initialize(subscriber, request)
      @connections = []
      @id         = request[:client_id]
      @session_id = request[:session_id]
      @messages   = []
      @logout_timeout = 0
      self.register
      add_new_connection(subscriber)
    end

    def to_json
      {
        :client_id  => @id, 
        :num_connections => @connections.size,
        :session_id => @session_id
      }.to_json
    end

    def add_new_connection(subscriber)
      @connections << subscriber
    end

    def friendly_id
      if self.id
        "with ID #{self.id}"
      else
        "session #{self.session_id}"
      end
    end

    def subscription_request(channels)
      return true unless options[:subscription_url]
      post_request(options[:subscription_url], channels, :timeout => options[:post_request_timeout] || 5)
    end

    def logout_connection_request(channels)
      return true unless options[:logout_connection_url]
      post_request(options[:logout_connection_url], channels, :timeout => options[:post_request_timeout] || 5)
    end

    def logout_request
      self.unregister
      logger.debug("Timed out client #{friendly_id}")
      return true unless options[:logout_url]
      post_request(options[:logout_url], [ ], :timeout => options[:post_request_timeout] || 5)
    end
    
    def remove_connection(connection)
      @connections.delete(connection)
      self.reset_logout_timeout!
      self.logout_request if self.give_up?
    end

    def send_message(msg, channels = nil)
      store_message(msg, channels) if options[:store_messages]
      send_message_to_connections(msg, channels)
    end

    # Send messages that are queued up for this particular client.
    # Messages are only queued for previously-connected clients.
    def send_queued_messages(connection)
      self.expire_queued_messages!

      # Weird looping because we don't want to send messages that get
      # added to the array after we start iterating (since those will
      # get sent to the client anyway).
      @length = @messages.length

      logger.debug("Sending #{@length} queued message(s) to client #{friendly_id}")

      @length.times do |id|
        message = @messages[id]
        send_message_to_connection(connection, message[:message], message[:channels])
      end
    end

    def channels
      @connections.collect { |em| em.channels }.flatten.uniq
    end

    def has_channels?(channels)
      @connections.each do |em|
        return true if em.has_channels?(channels)
      end
      false
    end

    def remove_channels!(channels)
      @connections.each do |em|
        em.remove_channels!(channels)
      end
    end

    def alive?
      @connections.select { |em| em.alive? }.any?
    end

    # This client is only dead if there are no connections and we are
    # past the timeout (if we are within the timeout, the user could
    # just be doing a page reload or going to a new page)
    def give_up?
      !alive? and (Time.now > @logout_timeout)
    end

    protected

    def register
      self.class.register_client(self)
    end

    def registered?
      self.class.client_registered?(self)
    end

    def unregister
      self.class.unregister_client(self)
    end

    def post_request(url, channels = [ ], options = { })
      uri = URI.parse(url)
      uri.path = '/' if uri.path == ''
      params = []
      params << "client_id=#{id}" if id
      params << "session_id=#{session_id}" if session_id
      channels.each {|chan| params << "channels[]=#{chan}" }
      headers = {"User-Agent" => "Ruby/#{RUBY_VERSION}"}
      begin
        http = Net::HTTP.new(uri.host, uri.port)
        if uri.scheme == 'https'
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        end
        http.read_timeout = options[:timeout] || 5
        resp, data = http.post(uri.path, params.join('&'), headers)
        return resp.is_a?(Net::HTTPOK)
      rescue => e
        logger.error("Bad request #{url.to_s} (#{e.class}: #{e.message})")
        return false
      rescue Timeout::Error
        logger.error("#{url.to_s} timeout")
        return false
      end
    end  

    def send_message_to_connections(msg, channels)
      @connections.each do |connection|
        send_message_to_connection(connection, msg, channels)
      end
    end

    def send_message_to_connection(connection, msg, channels)
      connection.broadcast(msg) if !channels or channels.empty? or connection.has_channels?(channels)
    end

    # Queued messages are stored until a timeout is reached which is the
    # same as the connection timeout. This takes care of messages that
    # come in between page loads or ones that come in right when you are
    # clicking off one page and loading the next one.
    def store_message(msg, channels)
      self.expire_queued_messages!
      @messages << { :channels => channels, :message => msg, :timeout => Time.now + options[:timeout] }
    end

    def expire_queued_messages!
      @messages.reject! { |message| Time.now > message[:timeout] }
    end

    def reset_logout_timeout!
      @logout_timeout = Time.now + options[:timeout]
    end
  end
end
