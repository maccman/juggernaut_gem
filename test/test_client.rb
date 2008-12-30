
$:.unshift "../lib"
require "juggernaut"
require "test/unit"
require "shoulda"
require "mocha"

class TestClient < Test::Unit::TestCase
  
  CONFIG = File.join(File.dirname(__FILE__), "files", "juggernaut.yml")
  
  class DummySubscriber; end
  
  EXAMPLE_URL = "http://localhost:5000/callbacks/example"
  SECURE_URL = "https://localhost:5000/callbacks/example"
  
  context "Client" do
    
    setup do
      Juggernaut.options = {
        :logout_connection_url => "http://localhost:5000/callbacks/logout_connection",
        :logout_url => "http://localhost:5000/callbacks/logout",
        :subscription_url => "http://localhost:5000/callbacks/subscription"
      }
      @s1 = DummySubscriber.new
      @request = {
        :client_id => "jonny",
        :session_id => rand(1_000_000).to_s(16)
      }
      @client = Juggernaut::Client.find_or_create(@s1, @request)
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
      @s1.stubs(:signature).returns("012345")
      assert_equal @client, Juggernaut::Client.find_by_signature("012345")
    end
    
    should "return the client based on client ID and channel list" do
      @client.stubs(:has_channels?).with(%w(a couple of channels)).returns(true)
      assert_equal @client, Juggernaut::Client.find_by_id_and_channels("jonny", %w(a couple of channels))
      assert_nil Juggernaut::Client.find_by_id_and_channels("peter", %w(a couple of channels))
      @client.stubs(:has_channels?).with(%w(something else)).returns(false)
      assert_nil Juggernaut::Client.find_by_id_and_channels("jonny", %w(something else))
    end
    
    should "automatically be registered, and can unregister" do
      assert @client.send(:registered?)
      assert_equal @client, @client.send(:unregister)
      assert_equal false, @client.send(:registered?)
    end
    
    should "be alive if at least one subscriber is alive" do
      @s1.stubs(:alive?).returns(true)
      @s2 = DummySubscriber.new
      @client.add_new_connection(@s2)
      @s2.stubs(:alive?).returns(false)
      assert @client.alive?
    end
    
    should "not be alive if no subscriber is alive" do
      @s1.stubs(:alive?).returns(false)
      @s2 = DummySubscriber.new
      @client.add_new_connection(@s2)
      @s2.stubs(:alive?).returns(false)
      assert_equal false, @client.alive?
    end

    should "not give up if within the timeout period" do
      Juggernaut.options[:timeout] = 10
      @s1.stubs(:alive?).returns(false)
      @client.send(:reset_logout_timeout!)
      assert_equal false, @client.give_up?
    end

    should "not give up if at least one subscriber is alive" do
      Juggernaut.options[:timeout] = 0
      @s1.stubs(:alive?).returns(true)
      @client.send(:reset_logout_timeout!)
      assert_equal false, @client.give_up?
    end
    
    should "send logouts after timeout" do
      Juggernaut.options[:timeout] = 0
      @s1.stubs(:alive?).returns(false)
      @client.send(:reset_logout_timeout!)
      @client.expects(:logout_request).once
      Juggernaut::Client.send_logouts_after_timeout
    end
    
    %w(subscription logout_connection).each do |type|
      
      context "#{type} request" do
        
        should "post to the correct URL" do
          @client.expects(:post_request).with(Juggernaut.options[:"#{type}_url"], %w(master), :timeout => 5).returns(true)
          assert_equal true, @client.send("#{type}_request", %w(master))
        end
        
        should "not raise exceptions if posting raises an exception" do
          @client.expects(:post_request).with(Juggernaut.options[:"#{type}_url"], %w(master), :timeout => 5).returns(false)
          assert_nothing_raised {
            assert_equal false, @client.send("#{type}_request", %w(master))
          }
        end
        
      end
      
    end
    
    context "post to URL" do
      
      should "return true when successful" do
        Net::HTTP.any_instance.
          expects(:post).
          with("/callbacks/example", "client_id=jonny&session_id=#{@request[:session_id]}&channels[]=master&channels[]=slave", {"User-Agent" => "Ruby/#{RUBY_VERSION}"}).
          returns([Net::HTTPOK.new('1.1', '200', 'OK'), ''])
        assert_equal true, @client.send(:post_request, EXAMPLE_URL, %w(master slave))
      end
      
      should "return false on an internal server error" do
        Net::HTTP.any_instance.expects(:post).returns([Net::HTTPInternalServerError.new('1.1', '500', 'Internal Server Error'), ''])
        assert_equal false, @client.send(:post_request, EXAMPLE_URL, %w(master slave))
      end
      
      should "return false when a runtime error is caught" do
        Net::HTTP.any_instance.expects(:post).raises(RuntimeError)
        assert_equal false, @client.send(:post_request, EXAMPLE_URL, %w(master slave))
      end
      
      should "return false when callback times out" do
        Net::HTTP.any_instance.expects(:post).raises(Timeout::Error)
        assert_equal false, @client.send(:post_request, EXAMPLE_URL, %w(master slave))
      end
      
      context "using a secure URL" do
        
        should "return true when successful" do
          Net::HTTP.any_instance.expects(:post).returns([Net::HTTPOK.new('1.1', '200', 'OK'), ''])
          Net::HTTP.any_instance.expects(:use_ssl=).with(true).returns(true)
          assert_equal true, @client.send(:post_request, SECURE_URL, %w(master slave))
        end
        
      end
      
    end
    
    context "channel list" do
      
      should "be the unique list of all channels in the subscribers" do
        @s1.stubs(:channels).returns(%w(master slave1))
        @s2 = DummySubscriber.new
        @s2.stubs(:channels).returns(%w(master slave2))
        @client.add_new_connection(@s2)
        assert_same_elements %w(master slave1 slave2), @client.channels
      end
      
    end
    
  end
  
end
