#!/usr/bin/env ruby

require "socket"

require "rubygems"
require "json"

subscriber = TCPSocket.new "127.0.0.1", 14999
subscriber.print({:command => :subscribe, :channels => %w(master)}.to_json + "\0")
$s = subscriber

broadcaster = TCPSocket.new "127.0.0.1", 14999
broadcaster.print({:command => :broadcast, :type => :to_channels, :channels => ["master"], :body => "zomg"}.to_json + "\0")
$b = broadcaster

require "irb"
IRB.start(__FILE__)
# puts subscriber.read.inspect
