
$:.unshift "../lib"
require "juggernaut"
require "test/unit"
require "shoulda"
require "flexmock"

class TestClient < Test::Unit::TestCase
  
  CONFIG = File.join(File.dirname(__FILE__), "files", "juggernaut.yml")
  
  class DummySubscriber
    def has_channels?(channels)
      !channels.empty?
    end
    def signature
      self.hash
    end
  end
  
  context "Client" do
    
    setup do
      @dummy_subscriber = DummySubscriber.new
      @request = {
        :client_id => "jonny",
        :session_id => rand(1_000_000).to_s(16)
      }
      @client = Juggernaut::Client.new(@dummy_subscriber, @request)
    end
    
    teardown do
      Juggernaut::Client.reset!
    end
    
    should "have correct JSON representation" do
      assert_nothing_raised do
        json = {
          "client_id"  => "jonny",
          "num_connections" => 1,
          "session_id" => @request[:session_id]
        }
        assert_equal json, JSON.parse(@client.to_json)
      end
    end
    
    should "return the client based on subscriber's signature" do
      assert_equal @client, Juggernaut::Client.find_by_signature(@dummy_subscriber.signature)
    end
    
    should "return the client based on client ID and channel list" do
      assert_equal @client, Juggernaut::Client.find_by_id_and_channels("jonny", %w(a couple of channels))
      assert_nil Juggernaut::Client.find_by_id_and_channels("jonny", %w())
      assert_nil Juggernaut::Client.find_by_id_and_channels("peter", %w(a couple of channels))
    end
    
    should "automatically be registered, and can unregister" do
      assert @client.send(:registered?)
      assert_equal @client, @client.send(:unregister)
      assert_equal false, @client.send(:registered?)
    end
    
  end
  
end
