# -*- encoding: utf-8 -*-

Gem::Specification.new do |s|
  s.name = %q{juggernaut}
  s.version = "0.5.8"

  s.required_rubygems_version = Gem::Requirement.new(">= 0") if s.respond_to? :required_rubygems_version=
  s.authors = ["Alex MacCaw"]
  s.date = %q{2008-12-06}
  s.default_executable = %q{juggernaut}
  s.description = %q{See Plugin README: http://juggernaut.rubyforge.org/svn/trunk/juggernaut/README}
  s.email = %q{info@eribium.org}
  s.executables = ["juggernaut"]
  s.extra_rdoc_files = ["Manifest.txt", "README.txt"]
  s.files = ["Manifest.txt", "README.txt", "Rakefile", "bin/juggernaut", "lib/juggernaut.rb", "lib/juggernaut/client.rb", "lib/juggernaut/message.rb", "lib/juggernaut/miscel.rb", "lib/juggernaut/runner.rb", "lib/juggernaut/server.rb", "lib/juggernaut/utils.rb"]
  s.has_rdoc = true
  s.homepage = %q{http://juggernaut.rubyforge.org}
  s.rdoc_options = ["--main", "README.txt"]
  s.require_paths = ["lib"]
  s.rubyforge_project = %q{juggernaut}
  s.rubygems_version = %q{1.3.0}
  s.summary = %q{See Plugin README: http://juggernaut.rubyforge.org/svn/trunk/juggernaut/README}

  if s.respond_to? :specification_version then
    current_version = Gem::Specification::CURRENT_SPECIFICATION_VERSION
    s.specification_version = 2

    if Gem::Version.new(Gem::RubyGemsVersion) >= Gem::Version.new('1.2.0') then
      s.add_runtime_dependency(%q<eventmachine>, [">= 0.10.0"])
      s.add_runtime_dependency(%q<json>, [">= 1.1.2"])
      s.add_development_dependency(%q<hoe>, [">= 1.7.0"])
    else
      s.add_dependency(%q<eventmachine>, [">= 0.10.0"])
      s.add_dependency(%q<json>, [">= 1.1.2"])
      s.add_dependency(%q<hoe>, [">= 1.7.0"])
    end
  else
    s.add_dependency(%q<eventmachine>, [">= 0.10.0"])
    s.add_dependency(%q<json>, [">= 1.1.2"])
    s.add_dependency(%q<hoe>, [">= 1.7.0"])
  end
end