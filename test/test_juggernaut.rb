
$:.unshift "../lib"
require "juggernaut"
require "test/unit"
require "shoulda"
require "mocha"

class TestJuggernaut < Test::Unit::TestCase
  
  context "Juggernaut" do
    
    setup do
      Juggernaut.options = { }
    end
    
    should "set options correctly" do
      options = {
        :host => "0.0.0.0",
        :port => 5001,
        :debug => false
      }
      Juggernaut.options = options
      assert_equal options, Juggernaut.options
    end
    
    should "have a debug logger by default" do
      log = Juggernaut.logger
      assert_not_nil log
      assert_equal Logger::DEBUG, log.level
    end
    
  end
  
end
