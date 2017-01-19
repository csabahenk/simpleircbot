#!/usr/bin/env ruby

require 'optparse'

load "simpleircbot"

OPTS = {
  bugzilla_url: String,
  gerrit_url: String,
  cache_prefetch: [],
  server: "<ignored>",
  channel: "<ignored>",
  nick: "<ignored>",
}.map { |o,d| [o, [d]] }.to_h
fixer = { Fixnum => Integer }
OptionParser.new { |op|
   op.banner = "Scrape bugzilla and gerrit ids from logs and dump as suitable for 'simpleircbot --cache-prefetch'"

   OPTS.each { |o,w|
     # Mangling OPTS to OptionParser options in a disgraced manner
     # - opt_name: <scalar> becomes:
     #   op.on("-o", "--opt-name", fixer[<scalar>.class], <scalar>.to_s) {...}
     #   where fixer is needed to map arbitrary classes into the class set
     #   accepted by OptionParser
     # - opt_name: <class> becomes: op.on("-o", "--opt-name", <class>) {...}
     op.on("-#{o[0]}", "--#{o.to_s.gsub "_", "-"}=VAL", *(
       (Class === w[0] ? [] : [w[0].class]) << w[0]
     ).instance_eval {|a|
         [fixer[a[0]]||a[0]] + a[1..-1].map(&:to_s)
     }) { |v| OPTS[o] << v }
   }
}.parse!
OPTS.each { |o,w|
  v = w[1] || w[0]
  if Class === v
    puts "missing value for --#{o}"
    exit 1
  end
  OPTS[o] = v
}

bot = SimpleIrcBot.new(**OPTS)

log = $<.read
data = {"bz"=>:_BUGZILLA_RX, "gerrit"=>:_GERRIT_RX}.map { |t,rx|
   log.scan(/#{bot.send rx}/m).flatten.uniq.map {|i| "#{t}:#{i}" }
}.flatten.join(",")
puts data
