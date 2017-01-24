#!/usr/bin/env ruby

load "simpleircbot"

OPTS = {
  bugzilla_alt: [],
  gerrit_alt: [],
  bugzilla_url: String,
  gerrit_url: String,
}

class OptionSink
  def initialize _stub: nil
  end
end

class StubBot < OptionSink
  include BugzillaGerritBot
end

bot = StubBot.new(**SimpleOpts.get(OPTS))

log = $<.read
data = {"bz"=>:_BUGZILLA_RX, "gerrit"=>:_GERRIT_RX}.map { |t,rx|
   log.scan(/#{bot.send rx}/m).flatten.uniq.map {|i| "#{t}:#{i}" }
}.flatten.join(",")
puts data
