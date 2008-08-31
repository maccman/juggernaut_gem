# -*- ruby -*-

require 'rubygems'
require 'hoe'
require './lib/juggernaut.rb'

Hoe.new('juggernaut', Juggernaut::VERSION) do |p|
  p.rubyforge_name = 'juggernaut'
  p.author = 'Alex MacCaw'
  p.email = 'info@eribium.org'
  # p.summary = 'FIX'
  # p.description = p.paragraphs_of('README.txt', 2..5).join("\n\n")
  p.url = 'http://juggernaut.rubyforge.org'
  p.changes = p.paragraphs_of('History.txt', 0..1).join("\n\n")
  p.extra_deps << ['eventmachine', '>=0.10.0']
  p.extra_deps << ['json', '>=1.1.2']
end

# vim: syntax=Ruby
