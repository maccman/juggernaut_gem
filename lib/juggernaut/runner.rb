require 'optparse'
require 'yaml'
require 'erb'
require 'resolv'

module Juggernaut
  class Runner
    include Juggernaut::Miscel
    
    class << self
      def run(argv = ARGV)
        self.new(argv)
      end
    end
    
    def initialize(argv = ARGV)
      self.options = {
        :host => "0.0.0.0",
        :port => 5001,
        :debug => false,
        :cleanup_timer => 2,
        :timeout => 10,
        :store_messages => false
      }
      
      self.options.merge!({
        :pid_path => pid_path,
        :log_path => log_path,
        :config_path => config_path
      })
      
      parse_options(argv)
      
      if !File.exists?(config_path)
        puts "You must generate a config file (juggernaut -g filename.yml)"
        exit
      end
      
      options.merge!(YAML::load(ERB.new(IO.read(config_path)).result))
      
      if options.include?(:kill)
        kill_pid(options[:kill] || '*')
      end

      if options[:allowed_ips]
        options[:allowed_ips] = options[:allowed_ips].collect { |ip| Resolv.getaddress(ip) }
      end
      
      Process.euid = options[:user] if options[:user]
      Process.egid = options[:group] if options[:group]
      
      if !options[:daemonize]
        start
      else
        daemonize
      end
    end
    
    def start
      puts "Starting Juggernaut server #{Juggernaut::VERSION} on port: #{options[:port]}..."
      
      trap("INT") {
        stop
        exit
      }
      trap("TERM"){
        stop
        exit
      }

      if options[:descriptor_table_size]
        EM.epoll
        new_size = EM.set_descriptor_table_size( options[:descriptor_table_size] )
        logger.debug "New descriptor-table size is #{new_size}"
      end
      
      EventMachine::run {
        EventMachine::add_periodic_timer( options[:cleanup_timer] || 2 ) { Juggernaut::Client.send_logouts_after_timeout }
        EventMachine::start_server(options[:host], options[:port].to_i, Juggernaut::Server)
        EM.set_effective_user( options[:user] ) if options[:user]
      }
    end
    
    def stop
      puts "Stopping Juggernaut server"
      Juggernaut::Client.send_logouts_to_all_clients
      EventMachine::stop
    end
    
    def parse_options(argv)
      OptionParser.new do |opts|
        opts.summary_width = 25
        opts.banner = "Juggernaut (#{VERSION})\n\n",
                      "Usage: juggernaut [-h host] [-p port] [-P file]\n",
                      "               [-d] [-k port] [-l file] [-e]\n",
                      "       juggernaut --help\n",
                      "       juggernaut --version\n"
        
        opts.separator ""
        opts.separator ""; opts.separator "Configuration:"
        
        opts.on("-g", "--generate FILE", String, "Generate config file", "(default: #{options[:config_path]})") do |v|
          options[:config_path] = File.expand_path(v) if v
          generate_config_file
        end
        
        opts.on("-c", "--config FILE", String, "Path to configuration file.", "(default: #{options[:config_path]})") do |v|
          options[:config_path] = File.expand_path(v)
        end
        
        opts.separator ""; opts.separator "Network:"
        
        opts.on("-h", "--host HOST", String, "Specify host", "(default: #{options[:host]})") do |v|
          options[:host] = v
        end
        
        opts.on("-p", "--port PORT", Integer, "Specify port", "(default: #{options[:port]})") do |v|
          options[:port] = v
        end

        opts.on("-s", "--fdsize SIZE", Integer, "Set the file descriptor size an user epoll() on Linux", "(default: use select() which is limited to 1024 clients)") do |v|
          options[:descriptor_table_size] = v
        end
        
        opts.separator ""; opts.separator "Daemonization:"
        
        opts.on("-P", "--pid FILE", String, "save PID in FILE when using -d option.", "(default: #{options[:pid_path]})") do |v|
          options[:pid_path] = File.expand_path(v)
        end
        
        opts.on("-d", "--daemon", "Daemonize mode") do |v|
          options[:daemonize] = v
        end

        opts.on("-k", "--kill PORT", String, :OPTIONAL, "Kill specified running daemons - leave blank to kill all.") do |v|
          options[:kill] = v
        end
        
        opts.separator ""; opts.separator "Logging:"
        
        opts.on("-l", "--log [FILE]", String, "Path to print debugging information.", "(default: #{options[:log_path]})") do |v|
          options[:log_path] = File.expand_path(v)
        end
        
        opts.on("-e", "--debug", "Run in debug mode", "(default: #{options[:debug]})") do |v|
          options[:debug] = v
        end
        
        opts.separator ""; opts.separator "Permissions:"
        
        opts.on("-u", "--user USER", Integer, "User to run as") do |user|
          options[:user] = user
        end

        opts.on("-G", "--group GROUP", String, "Group to run as") do |group|
          options[:group] = group
        end
        
        opts.separator ""; opts.separator "Miscellaneous:"
        
        opts.on_tail("-?", "--help", "Display this usage information.") do
          puts "#{opts}\n"
          exit
        end
        
        opts.on_tail("-v", "--version", "Display version") do |v|
          puts "Juggernaut #{VERSION}"
          exit
        end
      end.parse!(argv)
      options
    end
    
    private
    
    def generate_config_file
      if File.exists?(config_path)
        puts "Config file already exists. You must remove it before generating a new one."
        exit
      end
      puts "Generating config file...."
      File.open(config_path, 'w+') do |file|
        file.write DEFAULT_CONFIG_FILE.gsub('your_secret_key_here', Digest::SHA1.hexdigest("--#{Time.now.to_s.split(//).sort_by {rand}.join}--"))
      end
      puts "Config file generated at #{config_path}"
      exit
    end
    
    def store_pid(pid)
     FileUtils.mkdir_p(File.dirname(pid_path))
     File.open(pid_path, 'w'){|f| f.write("#{pid}\n")}
    end

    def kill_pid(k)
      Dir[options[:pid_path]||File.join(File.dirname(pid_dir), "juggernaut.#{k}.pid")].each do |f|
        begin
        puts f
        pid = IO.read(f).chomp.to_i
        FileUtils.rm f
        Process.kill(9, pid)
        puts "killed PID: #{pid}"
        rescue => e
          puts "Failed to kill! #{k}: #{e}"
        end
      end
      exit
    end

    def daemonize
     fork do
       Process.setsid
       exit if fork
       store_pid(Process.pid)
       # Dir.chdir "/" # Mucks up logs
       File.umask 0000
       STDIN.reopen "/dev/null"
       STDOUT.reopen "/dev/null", "a"
       STDERR.reopen STDOUT
       start
     end
    end
    
  end
end
