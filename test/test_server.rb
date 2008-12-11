
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
    def close
      @socket.close if @socket
    end
    def initialize(options)
      @options = options
      @socket = nil
    end
    def receive
      return nil unless @socket
      begin
        response = @socket.read.chomp!("\0")
        Juggernaut.logger.info "RESPONSE: " + response.inspect
        JSON.parse(response)
      rescue => e
        Juggernaut.logger.error "#{e.class}: #{e.message}"
        return false
      end
    end
    def transmit(hash, wait_response = false)
      response = nil
      @socket ||= TCPSocket.new(@options[:host], @options[:port])
      @socket.print(hash.to_json + "\0")
      @socket.flush
      if wait_response
        self.receive
      else
        nil
      end
    end
  end
  
  def new_client
    c = DirectClient.new(OPTIONS)
    if block_given?
      yield(c)
    else
      c
    end
  end
  
  # def with_server(options = { }, &block)
  def with_server(*procs)
    options = procs.last.is_a?(Hash) ? procs.pop : { }
    old_options, Juggernaut.options = Juggernaut.options, OPTIONS.merge(options)
    Juggernaut.logger.level = Logger::DEBUG
    @connections = [ ]
    EM.run do
      endgame = proc {
        Juggernaut::Client.send_logouts_to_all_clients
        EM.stop
      }
      
      chain = procs.reverse.inject(endgame) do |cb, p|
        proc { EM.defer p, cb }
      end
      
      EM.start_server(Juggernaut.options[:host], Juggernaut.options[:port], Juggernaut::Server) { |c| @connections << c }
      EM.add_timer(5) { EM.stop }

      EM.defer chain
      
      # EM.defer proc {
      #   instance_eval(&block)
      # }, proc {
      #   Juggernaut::Client.send_logouts_to_all_clients
      #   EM.stop
      # }
      
      # EM.add_timer(1) do
      #   Juggernaut::Client.send_logouts_to_all_clients
      #   EM.stop
      # end
    end
  ensure
    Juggernaut.options = old_options if old_options
  end
  
  context "Server" do
    
    should "accept a connection" do
      with_server proc {
        self.new_client do |c|
          c.transmit :command => :subscribe, :channels => [ ]
        end
      }, proc {
        # assert_active_connections 1
        # assert_equal 1, @connections.size
        # assert_equal false, @connections.first.alive?
        assert_equal 1, @connections.select { |c| c.alive? }.size
        assert_equal true, @connections.first.alive?
      }
      puts "3"
      assert_equal false, @connections.first.alive?
    end
    
    should "register channels correctly" do
      with_server proc {
        self.new_client { |c| c.transmit :command => :subscribe, :channels => ["master", "slave"] }
      }
      assert @connections.first.has_channel?("master")
      assert_equal false, @connections.first.has_channel?("non_existant")
      assert @connections.first.has_channels?(["non_existant", "master", "slave"])
      assert_equal false, @connections.first.has_channels?(["non_existant", "invalid"])
    end
    
    should "broadcast only to subscribed clients" do
      body = "This is a test!"
      clients = [ ]
      with_server proc {
        clients << self.new_client { |c| c.transmit :command => :subscribe, :channels => [ ]; c }
        clients << self.new_client { |c| c.transmit :command => :subscribe, :channels => ["master"]; c }
        clients << self.new_client { |c| c.transmit :command => :subscribe, :channels => ["master", "slave"]; c }
        clients << self.new_client { |c| c.transmit :command => :subscribe, :channels => ["slave"]; c }
      }, proc {
        self.new_client { |c| c.transmit :command => :broadcast, :type => :to_channels, :channels => ["master"], :body => body; c }
      }, proc {
        assert_equal 5, @connections.size
        assert_equal 2, @connections.select { |c| c.has_channel?("master") }.size
        clients.each do |client|
          #client.close
          Juggernaut.logger.info "RECEIVE: " + client.receive.inspect
        end
      }
    end
    
  end
  
end
