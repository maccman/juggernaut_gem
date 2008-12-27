
$:.unshift "../lib"
require "juggernaut"
require "test/unit"
require "shoulda"
require "mocha"

class TestUtils < Test::Unit::TestCase
  
  context "Hash" do
    
    should "symbolize keys" do
      obj = Object.new
      hsh = {"a" => 1, "b" => "string", "c" => obj}
      hsh.symbolize_keys!
      assert_nil hsh["a"]
      assert_equal 1, hsh[:a]
      assert_nil hsh["b"]
      assert_equal "string", hsh[:b]
      assert_nil hsh["c"]
      assert_equal obj, hsh[:c]
    end
    
  end
  
end
