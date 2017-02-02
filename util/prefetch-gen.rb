#!/usr/bin/env ruby

require 'simpleopts'
require 'bugzillagerritbot'

OPTS = {
  bugzilla_alt: [],
  gerrit_alt: [],
  bugzilla_url: String,
  gerrit_url: String,
  server: "<ignored>",
  nick: "<ignored>",
}

bot = BugzillaGerritBot.new(**SimpleOpts.get(OPTS))

log = $<.read
data = {"bz"=>:_BUGZILLA_RX, "gerrit"=>:_GERRIT_RX}.map { |t,rx|
   log.scan(/#{bot.send rx}/m).flatten.uniq.map {|i| "#{t}:#{i}" }
}.flatten.join(",")
puts data
