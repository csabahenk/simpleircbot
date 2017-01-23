#!/usr/bin/env ruby

load "simpleircbot"

OPTS = {
  bugzilla_url: String,
  gerrit_url: String,
  channel: "<ignored>",
  nick: "<ignored>",
}

bot = SimpleIrcBot.new(**SimpleOpts.get(OPTS))

log = $<.read
data = {"bz"=>:_BUGZILLA_RX, "gerrit"=>:_GERRIT_RX}.map { |t,rx|
   log.scan(/#{bot.send rx}/m).flatten.uniq.map {|i| "#{t}:#{i}" }
}.flatten.join(",")
puts data
