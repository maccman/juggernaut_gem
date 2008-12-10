require 'rubygems'
require 'logger'
require 'eventmachine'
require 'json'
$:.unshift(File.dirname(__FILE__))

module Juggernaut
  VERSION   = '0.5.8'

  class JuggernautError < StandardError #:nodoc:
  end

  @@options = {}
  
  DEFAULT_CONFIG_FILE = <<-EOF
     # ======================
     # Juggernaut Options
     # ======================

     # === Subscription authentication ===
     # Leave all subscription options uncommented to allow anyone to subscribe.

     # If specified, subscription_url is called everytime a client subscribes.
     # Parameters passed are: session_id, client_id and an array of channels.
     # 
     # The server should check that the session_id matches up to the client_id
     # and that the client is allowed to access the specified channels.
     # 
     # If a status code other than 200 is encountered, the subscription_request fails
     # and the client is disconnected.
     # 
     # :subscription_url:  http://localhost:3000/sessions/juggernaut_subscription

     # === Broadcast and query authentication ===
     # Leave all broadcast/query options uncommented to allow anyone to broadcast/query.
     # 
     # Broadcast authentication in a production environment is very importantant since broadcasters
     # can execute JavaScript on subscribed clients, leaving you vulnerable to cross site scripting
     # attacks if broadcasters aren't authenticated. 

     # 1) Via IP address
     # 
     # If specified, if a client has an ip that is specified in allowed_ips, than it is automatically
     # authenticated, even if a secret_key isn't provided. 
     # 
     # This is the recommended method for broadcast authentication.
     #
     :allowed_ips: 
                  - 127.0.0.1
                  # - 192.168.0.1

     # 2) Via HTTP request
     # 
     # If specified, if a client attempts a broadcast/query, without a secret_key or using an IP
     # no included in allowed_ips, then broadcast_query_login_url will be called.
     # Parameters passed, if given, are: session_id, client_id, channels and type.
     # 
     # The server should check that the session_id matches up to the client id, and the client
     # is allowed to perform that particular type of broadcast/query.
     # 
     # If a status code other than 200 is encountered, the broadcast_query_login_url fails
     # and the client is disconnected.
     # 
     # :broadcast_query_login_url: http://localhost:3000/sessions/juggernaut_broadcast

     # 3) Via shared secret key
     # 
     # This secret key must be sent with any query/broadcast commands. 
     # It must be the same as the one in the Rails config file.
     # 
     # You shouldn't authenticate broadcasts from subscribed clients using this method
     # since the secret_key will be easily visible in the page (and not so secret any more)!
     # 
     # :secret_key: your_secret_key_here

     # == Subscription Logout ==

     # If specified, logout_connection_url is called everytime a specific connection from a subscribed client disconnects. 
     # Parameters passed are session_id, client_id and an array of channels specific to that connection.
     # 
     # :logout_connection_url: http://localhost:3000/sessions/juggernaut_connection_logout

     # Logout url is called when all connections from a subscribed client are closed.
     # Parameters passed are session_id and client_id.
     # 
     # :logout_url: http://localhost:3000/sessions/juggernaut_logout

     # === Miscellaneous ===

     # timeout defaults to 10. A timeout is the time between when a client closes a connection
     # and a logout_request or logout_connection_request is made. The reason for this is that a client
     # may only temporarily be disconnected, and may attempt a reconnect very soon.
     # 
     # :timeout: 10

     # store_messages defaults to false. If this option is true, messages send to connections will be stored. 
     # This is useful since a client can then receive broadcasted message that it has missed (perhaps it was disconnected).
     #
     # :store_messages: false

     # === Server ===

     # Host defaults to "0.0.0.0". You shouldn't need to change this.
     # :host: 0.0.0.0

     # Port is mandatory
     :port: 5001
     
     # Defaults to value of :port. If you are doing port forwarding you'll need to configure this to the same 
     # value as :public_port in the juggernaut_hosts.yml file
     # :public_port: 5001

  EOF

  class << self
    def options
      @@options
    end
    
    def options=(val)
      @@options = val
    end
    
    def logger
      return @@logger if defined?(@@logger) && !@@logger.nil?
      FileUtils.mkdir_p(File.dirname(log_path))
      @@logger = Logger.new(log_path)
      @@logger.level = Logger::INFO if options[:debug] == false
      @@logger
    rescue
      @@logger = Logger.new(STDOUT)
    end
    
    def logger=(logger)
      @@logger = logger
    end
    
    def log_path
      options[:log_path] || File.join(%w( / var run juggernaut.log ))
    end
    
    def pid_path
      options[:pid_path] || File.join(%w( / var run ), "juggernaut.#{options[:port]}.pid" )
    end
      
    def config_path
      options[:config_path] || File.join(%w( / var run juggernaut.yml ))
    end
    
  end
end

require 'juggernaut/utils'
require 'juggernaut/miscel'
require 'juggernaut/message'
require 'juggernaut/client'
require 'juggernaut/server'
require 'juggernaut/runner'
