
$:.unshift "../lib"
require "juggernaut"
require "test/unit"

class TestServer < Test::Unit::TestCase
  
  CONFIG = File.join(File.dirname(__FILE__), "files", "juggernaut.yml")
  
  DEFAULT_OPTIONS = {
    :host => "0.0.0.0",
    :port => 5001,
    :debug => false,
    :cleanup_timer => 2,
    :timeout => 10,
    :store_messages => false
  }
  
  OPTIONS = DEFAULT_OPTIONS.merge(YAML::load(ERB.new(IO.read(CONFIG)).result))
  
  class DirectClient
    attr_reader :channels
    def broadcast_to_channels(channels, body)
      self.transmit :command => :broadcast, :type => :to_channels, :channels => channels, :body => body
      self
    end
    def broadcast_to_clients(clients, body)
      self.transmit :command => :broadcast, :type => :to_clients, :client_ids => clients, :body => body
    end
    def close
      @socket.close if @socket
    end
    def initialize(options)
      @options = options
      @socket = nil
      @client_id = options[:client_id]
      @session_id = options[:session_id] || rand(1_000_000).to_s(16)
      @channels = [ ]
      @socket = TCPSocket.new(@options[:host], @options[:port])
    end
    def inspect
      {:channels => @channels, :client_id => @client_id, :session_id => @session_id}.inspect
    end
    def query_show_clients
      self.transmit :command => :query, :type => :show_clients
    end
    def receive
      return nil unless @socket
      begin
        # response = @socket.read.to_s
        # response = @socket.readline("\0").to_s
        response = ""
        begin
          response << @socket.read_nonblock(1024)
        rescue Errno::EAGAIN
        end
        response.chomp!("\0")
        Juggernaut.logger.info "DirectClient read: " + response.inspect
        JSON.parse(response)
      rescue => e
        Juggernaut.logger.error "DirectClient #{e.class}: #{e.message}"
        return false
      end
    end
    def subscribe(channels)
      channels.each do |channel|
        @channels << channel.to_s unless @channels.include?(channel.to_s)
      end
      self.transmit :command => :subscribe, :client_id => @client_id, :session_id => @session_id, :channels => channels
      self
    end
    def transmit(hash, wait_response = false)
      @socket.print(hash.to_json + "\0")
      @socket.flush
      if wait_response
        self.receive
      else
        nil
      end
    end
  end
  
  # Assert that the DirectClient has an awaiting message with +body+.
  def assert_body(body, subscriber)
    assert_not_nil subscriber
    result = subscriber.receive
    assert_respond_to result, :[]
    assert_equal body, result["body"]
  ensure
    subscriber.close
  end
  
  # Assert that the DirectClient has no awaiting message.
  def assert_no_body(subscriber)
    assert_equal false, subscriber
  end
  
  # Convenience method to create a new DirectClient instance with overridable options.
  # If a block is passed, control is yielded, passing the new client in. This method
  # returns the value returned from that block, or the new client if no block was given.
  def new_client(options = { })
    c = DirectClient.new(OPTIONS.merge(options))
    if block_given?
      yield(c)
    else
      c
    end
  end
  
  # Shortcut to run tests that require setting up, starting, then shutting down EventMachine.
  # So ugly, but EventMachine doesn't have test examples on code that require back-and-forth
  # communication over a long-running connection.
  def with_server(options = { }, &block)
    # Save the current options. This is an obvious hack.
    old_options, Juggernaut.options = Juggernaut.options, OPTIONS.merge(options)
    Juggernaut.logger.level = Logger::DEBUG
    
    # Initialize an array to keep track of connections made to the server in this instance.
    @connections = [ ]
    
    EM.run do
      # Start the server, and save each connection made so we can refer to it later.
      EM.start_server(Juggernaut.options[:host], Juggernaut.options[:port], Juggernaut::Server) { |c| @connections << c }
      
      # Guard against never-ending tests by shutting off at 2 seconds.
      EM.add_timer(2) do
        Juggernaut::Client.send_logouts_to_all_clients
        EM.stop
      end
      
      # Deferred: evaluate the block and then run the shutdown proc. By using instance_eval,
      # our block gets access to assert_* methods and the +@connections+ variable above.
      EM.defer proc {
        instance_eval(&block)
      }, proc {
        # There's probably a better way of doing this, but without this line, different
        # clients may create a race condition in tests, causing some of them to sometimes
        # fail. This isn't foolproof either, should any client take more than 200 ms.
        EM.add_timer(0.2) do
          Juggernaut::Client.send_logouts_to_all_clients
          EM.stop
        end
      }
    end
  ensure
    # Restore old options.
    Juggernaut.options = old_options if old_options
  end
  
  context "Server" do
    
    should "accept a connection" do
      with_server do
        self.new_client do |c|
          c.transmit :command => :subscribe, :channels => [ ]
        end
        assert_equal 1, @connections.select { |c| c.alive? }.size
        assert_equal true, @connections.first.alive?
      end
      assert_equal false, @connections.first.alive?
    end
    
    should "register channels correctly" do
      with_server do
        self.new_client { |c| c.transmit :command => :subscribe, :channels => ["master", "slave"] }
      end
      assert @connections.first.has_channel?("master")
      assert_equal false, @connections.first.has_channel?("non_existant")
      assert @connections.first.has_channels?(["non_existant", "master", "slave"])
      assert_equal false, @connections.first.has_channels?(["non_existant", "invalid"])
    end
    
    context "channel-wide broadcast" do
      
      body = "This is a channel-wide broadcast test!"
      
      should "be received by client in the same channel" do
        subscriber = nil
        with_server do
          subscriber = self.new_client(:client_id => "broadcast_channel") { |c| c.subscribe %w(master) }
          self.new_client { |c| c.broadcast_to_channels %w(master), body }
        end
        assert_not_nil subscriber
        result = subscriber.receive
        subscriber.close
        assert_respond_to result, :[]
        assert_equal body, result["body"]
      end
      
      should "not be received by client not in a channel" do
        subscriber = nil
        with_server do
          subscriber = self.new_client(:client_id => "broadcast_channel") { |c| c.subscribe %w() }
          self.new_client { |c| c.broadcast_to_channels %w(master), body }
        end
        assert_not_nil subscriber
        result = subscriber.receive
        subscriber.close
        assert_equal false, result
      end
      
      should "not be received by client in a different channel" do
        subscriber = nil
        with_server do
          subscriber = self.new_client(:client_id => "broadcast_test") { |c| c.subscribe %w(slave) }
          self.new_client { |c| c.broadcast_to_channels %w(broadcast_channel), body }
        end
        assert_not_nil subscriber
        result = subscriber.receive
        subscriber.close
        assert_equal false, result
      end
      
    end
    
    # For some reason, these refuse to pass:
    context "broadcast with no specific channel" do
      
      body = "This is a broadcast test!"
      
      should "be received by client not in any channels" do
        subscriber = nil
        with_server do
          subscriber = self.new_client(:client_id => "broadcast_all") { |c| c.subscribe %w() }
          self.new_client { |c| c.broadcast_to_channels %w(), body }
        end
        assert_body body, subscriber
      end
      
      should "be received by client in a channel" do
        subscriber = nil
        with_server do
          subscriber = self.new_client(:client_id => "broadcast_all") { |c| c.subscribe %w(master) }
          self.new_client { |c| c.broadcast_to_channels %w(), body }
        end
        assert_body body, subscriber
      end
      
    end
    
    context "broadcast to a client" do
      
      body = "This is a client-specific broadcast test!"
      
      should "be received by the target client" do
        subscriber = nil
        with_server do
          subscriber = self.new_client(:client_id => "broadcast_client") { |c| c.subscribe %w() }
          self.new_client { |c| c.broadcast_to_clients %w(broadcast_client), body }
        end
        assert_body body, subscriber
      end
      
    end
    
  end
  
end
