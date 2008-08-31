module Juggernaut
  module Miscel
    def options
      Juggernaut.options
    end
  
    def options=(ob)
      Juggernaut.options = ob
    end
  
    def log_path
      Juggernaut.log_path
    end
  
    def pid_path
      Juggernaut.pid_path
    end
    
    def config_path
      Juggernaut.config_path
    end
    
    def logger
      Juggernaut.logger
    end
  end
end