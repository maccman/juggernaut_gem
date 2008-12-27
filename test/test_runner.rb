
$:.unshift "../lib"
require "juggernaut"
require "test/unit"
require "shoulda"
require "mocha"
require "tempfile"

class TestRunner < Test::Unit::TestCase
  
  CONFIG = File.join(File.dirname(__FILE__), "files", "juggernaut.yml")
  
  context "Runner" do
    
    should "always be true" do
      assert true
    end
    
    # should "run" do
    #   EM.run { EM.stop }
    #   Juggernaut::Runner.run(["-c", CONFIG])
    # end
    
  end
  
end
