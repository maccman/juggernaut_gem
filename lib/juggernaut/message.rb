module Juggernaut
  class Message
    attr_accessor :id
    attr_accessor :signature
    attr_accessor :body
    attr_reader   :created_at
    
    def initialize(id, body, signature)
     @id         = id
     @body       = body
     @signature  = signature
     @created_at = Time.now
    end
    
    def to_s
      { :id => @id.to_s, :body => @body, :signature => @signature }.to_json
    end
  end
end