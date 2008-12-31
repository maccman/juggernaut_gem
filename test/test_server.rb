
$:.unshift "../lib"
require "juggernaut"
require "test/unit"
require "shoulda"
require "mocha"

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
    def request_crossdomain_file
      @socket.print "<policy-file-request/>\0"
      self
    end
    def query_remove_channels_from_all_clients(channels)
      self.transmit :command => :query, :type => :remove_channels_from_all_clients, :channels => channels
      self
    end
    def query_remove_channels_from_client(channels, clients)
      self.transmit :command => :query, :type => :remove_channels_from_client, :client_ids => clients, :channels => channels
      self
    end
    def query_show_channels_for_client(client_id)
      self.transmit :command => :query, :type => :show_channels_for_client, :client_id => client_id
      self
    end
    def query_show_client(client_id)
      self.transmit :command => :query, :type => :show_client, :client_id => client_id
      self
    end
    def query_show_clients(client_ids = [])
      self.transmit :command => :query, :type => :show_clients, :client_ids => client_ids
      self
    end
    def query_show_clients_for_channels(channels)
      self.transmit :command => :query, :type => :show_clients_for_channels, :channels => channels
      self
    end
    def receive(as_json = true)
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
        as_json ? JSON.parse(response) : response
      rescue => e
        Juggernaut.logger.error "DirectClient #{e.class}: #{e.message}"
        raise
      end
    end
    def subscribe(channels)
      channels.each do |channel|
        @channels << channel.to_s unless @channels.include?(channel.to_s)
      end
      self.transmit :command => :subscribe, :channels => channels
      self
    end
    def send_raw(raw, wait_response = false)
      @socket.print(raw + "\0")
      @socket.flush
      if wait_response
        self.receive
      else
        nil
      end
    end
    def transmit(hash, wait_response = false)
      hash[:client_id] ||= @client_id
      hash[:session_id] ||= @session_id
      self.send_raw(hash.to_json, wait_response)
    end
  end
  
  # Assert that the DirectClient has an awaiting message with +body+.
  def assert_body(body, subscriber)
    assert_response subscriber do |result|
      assert_respond_to result, :[]
      assert_equal body, result["body"]
    end
  end
  
  # Assert that the DirectClient has no awaiting message.
  def assert_no_body(subscriber)
    assert_response subscriber do |result|
      assert_equal false, result
    end
  end
  
  def assert_no_response(subscriber)
    assert_not_nil subscriber
    assert_raise(EOFError) { subscriber.receive }
  ensure
    subscriber.close
  end
  
  def assert_raw_response(subscriber, response = nil)
    assert_not_nil subscriber
    result = nil
    assert_nothing_raised { result = subscriber.receive(false) }
    assert_not_nil result
    if block_given?
      yield result
    else
      assert_equal response, result
    end
  ensure
    subscriber.close
  end
  
  def assert_response(subscriber, response = nil)
    assert_not_nil subscriber
    result = nil
    assert_nothing_raised { result = subscriber.receive }
    assert_not_nil result
    if block_given?
      yield result
    else
      assert_equal response, result
    end
  ensure
    subscriber.close
  end
  
  def assert_server_disconnected(subscriber)
    assert_not_nil subscriber
    assert_raise(Errno::ECONNRESET, EOFError) { subscriber.receive }
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
    # We should not have any clients before we start
    Juggernaut::Client.reset!

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
        assert_no_response subscriber
      end
      
      should "not be received by client in a different channel" do
        subscriber = nil
        with_server do
          subscriber = self.new_client(:client_id => "broadcast_test") { |c| c.subscribe %w(slave) }
          self.new_client { |c| c.broadcast_to_channels %w(broadcast_channel), body }
        end
        assert_no_response subscriber
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
      
      should "not be received by other clients" do
        subscriber = nil
        with_server do
          subscriber = self.new_client(:client_id => "broadcast_faker") { |c| c.subscribe %w() }
          self.new_client { |c| c.broadcast_to_clients %w(broadcast_client), body }
        end
        assert_no_response subscriber
      end
      
      should "be saved until the client reconnects" do
        subscriber = nil
        with_server :store_messages => true do
          self.new_client(:client_id => "broadcast_client") { |c| c.subscribe %w() }.close
          self.new_client { |c| c.broadcast_to_clients %w(broadcast_client), body }
          subscriber = self.new_client(:client_id => "broadcast_client") { |c| c.subscribe %w() }
        end
        assert_body body, subscriber
      end

      should "only be sent to new client connection" do
        old_subscriber = nil
        new_subscriber = nil

        with_server :store_messages => true, :timeout => 30 do 
          old_subscriber = self.new_client(:client_id => "broadcast_client", :session_id => "1") { |c| c.subscribe %w() }
          self.new_client { |c| c.broadcast_to_clients %w(broadcast_client), body }
          @connections.first.client.expects(:send_message_to_connection).times(2)
          new_subscriber = self.new_client(:client_id => "broadcast_client", :session_id => "2") { |c| c.subscribe %w() }
        end
      end
      
    end
    
    context "querying client list" do
      
      should "return all clients" do
        subscriber = nil
        with_server do
          self.new_client(:client_id => "alex") { |c| c.subscribe %w() }
          self.new_client(:client_id => "bob") { |c| c.subscribe %w() }
          subscriber = self.new_client(:client_id => "cindy") { |c| c.subscribe %w(); c.query_show_clients }
        end
        assert_not_nil subscriber
        result = subscriber.receive
        assert_not_nil result
        assert_equal 3, result.size
        assert_same_elements %w(alex bob cindy), result.collect { |r| r["client_id"] }
      end
      
      should "not include disconnected clients" do
        subscriber = nil
        with_server(:timeout => 0) do
          self.new_client(:client_id => "sandra") { |c| c.subscribe %w() }
          self.new_client(:client_id => "tom") { |c| c.subscribe %w() }.close
          subscriber = self.new_client(:client_id => "vivian") { |c| c.subscribe %w(); c.query_show_clients }
        end
        assert_not_nil subscriber
        result = subscriber.receive
        assert_not_nil result
        assert_equal 2, result.size
        assert_same_elements %w(sandra vivian), result.collect { |r| r["client_id"] }
      end
      
      should "only return requested clients" do
        subscriber = nil
        with_server do
          self.new_client(:client_id => "dixie") { |c| c.subscribe %w() }
          self.new_client(:client_id => "eamon") { |c| c.subscribe %w() }
          self.new_client(:client_id => "fanny") { |c| c.subscribe %w() }
          subscriber = self.new_client(:client_id => "zelda") { |c| c.subscribe %w(); c.query_show_clients %w(dixie fanny) }
        end
        assert_not_nil subscriber
        result = subscriber.receive
        assert_not_nil result
        assert_equal 2, result.size
        assert_same_elements %w(dixie fanny), result.collect { |r| r["client_id"] }
      end
      
      should "never return non-existant clients even when requested" do
        subscriber = nil
        with_server do
          self.new_client(:client_id => "dixie") { |c| c.subscribe %w() }
          self.new_client(:client_id => "eamon") { |c| c.subscribe %w() }
          self.new_client(:client_id => "fanny") { |c| c.subscribe %w() }
          subscriber = self.new_client(:client_id => "zelda") { |c| c.subscribe %w(); c.query_show_clients %w(ginny homer) }
        end
        assert_not_nil subscriber
        result = subscriber.receive
        assert_not_nil result
        assert_equal 0, result.size
      end
      
      should "return correct number of active connections" do
        subscriber = nil
        with_server do
          5.times { self.new_client(:client_id => "homer") { |c| c.subscribe %w() } }
          subscriber = self.new_client(:client_id => "zelda") { |c| c.subscribe %w(); c.query_show_clients %w(homer) }
        end
        assert_not_nil subscriber
        result = subscriber.receive
        assert_not_nil result
        assert_equal 1, result.size
        assert_equal 5, result.first["num_connections"]
      end
      
      should "be equivalent when querying one client" do
        s1, s2 = nil
        with_server do
          5.times { self.new_client(:client_id => "homer") { |c| c.subscribe %w() } }
          s1 = self.new_client(:client_id => "zelda") { |c| c.subscribe %w(); c.query_show_client "homer" }
          s2 = self.new_client(:client_id => "zelda") { |c| c.subscribe %w(); c.query_show_clients %w(homer) }
        end
        assert_not_nil s1
        assert_not_nil s2
        r1 = s1.receive
        assert_not_nil r1
        r2 = s2.receive
        assert_not_nil r2
        assert_equal 1, r2.size
        assert_equal r1, r2.first
      end
      
      should "only return clients in specific channels" do
        subscriber = nil
        with_server do
          self.new_client(:client_id => "alexa") { |c| c.subscribe %w(master slave zoo) }
          self.new_client(:client_id => "bobby") { |c| c.subscribe %w(master slave) }
          self.new_client(:client_id => "cindy") { |c| c.subscribe %w(master zoo) }
          self.new_client(:client_id => "dixon") { |c| c.subscribe %w(slave zoo) }
          self.new_client(:client_id => "eamon") { |c| c.subscribe %w(slave) }
          self.new_client(:client_id => "flack") { |c| c.subscribe %w(decoy slave) }
          subscriber = self.new_client(:client_id => "geoff") { |c| c.subscribe %w(zoo); c.query_show_clients_for_channels %w(master zoo) }
        end
        assert_response subscriber do |result|
          assert_equal 5, result.size
          assert_same_elements %w(alexa bobby cindy dixon geoff), result.collect { |r| r["client_id"] }
        end
      end
      
    end
    
    context "upon processing an invalid command" do
      
      should "disconnect immediately" do
        subscriber = nil
        with_server do
          subscriber = self.new_client(:client_id => "pinocchio") { |c| c.transmit :command => :some_undefined_command; c.subscribe %w(); c }
        end
        assert_server_disconnected subscriber
      end
      
    end
    
    %w(broadcast subscribe query).each do |type|
      
      context "upon receiving malformed #{type}" do
        
        should "disconnect immediately" do
          subscriber = nil
          with_server do
            subscriber = self.new_client(:client_id => "pinocchio") { |c| c.transmit :command => type, :type => :unknown; c.subscribe %w(); c }
          end
          assert_server_disconnected subscriber
        end
        
      end
      
    end
    
    context "upon receiving invalid JSON" do
      
      should "disconnect immediately" do
        subscriber = nil
        with_server do
          subscriber = self.new_client(:client_id => "pinocchio") { |c| c.send_raw "invalid json..."; c }
        end
        assert_server_disconnected subscriber
      end
      
    end
    
    context "crossdomain file request" do
      
      should "return contents of crossdomain file" do
        subscriber = nil
        with_server do
          subscriber = self.new_client(:client_id => "pinocchio") { |c| c.request_crossdomain_file }
        end
        assert_raw_response subscriber, <<-EOF
      <cross-domain-policy>
        <allow-access-from domain="*" to-ports="#{OPTIONS[:port]}" />
      </cross-domain-policy>
    EOF
      end
      
    end
    
    context "querying channel list" do
      
      should "return channel list" do
        subscribe = nil
        with_server do
          self.new_client(:client_id => "homer") { |c| c.subscribe %w(groupie master slave1 slave2) }
          self.new_client(:client_id => "marge") { |c| c.subscribe %w(master slave1 slave2) }
          subscribe = self.new_client(:client_id => "pinocchio") { |c|
            c.subscribe %w(master slave1)
            c.query_show_channels_for_client "marge"
          }
        end
        assert_response subscribe do |result|
          assert_equal 3, result.size 
          assert_same_elements %w(master slave1 slave2), result
        end
      end
      
    end
    
    context "remove channel request" do
      
      should "work on all clients when requested" do
        with_server do
          self.new_client(:client_id => "homer") { |c| c.subscribe %w(groupie master slave1 slave2) }
          self.new_client(:client_id => "marge") { |c| c.subscribe %w(master slave1 slave2) }
          self.new_client(:client_id => "pinocchio") { |c|
            c.subscribe %w(master slave1 slave2)
            c.query_remove_channels_from_all_clients %w(slave1 slave2)
          }
        end
        @connections.each do |connection|
          assert_does_not_contain connection.channels, /slave/
        end
      end
      
      should "work on specific clients when requested" do
        with_server do
          self.new_client(:client_id => "homer") { |c| c.subscribe %w(groupie master slave1 slave2) }
          self.new_client(:client_id => "marge") { |c| c.subscribe %w(master slave1 slave2) }
          self.new_client(:client_id => "pinocchio") { |c|
            c.subscribe %w(master slave1 slave2)
            c.query_remove_channels_from_client %w(slave1 slave2), %w(homer)
          }
        end
        assert_does_not_contain @connections.find { |c| c.instance_eval("@request[:client_id]") == "homer" }.channels, /slave/
        assert_contains @connections.find { |c| c.instance_eval("@request[:client_id]") == "marge" }.channels, /slave/
      end
      
    end
    
  end
  
end
