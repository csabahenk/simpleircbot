#!/usr/bin/env ruby

require 'simpleopts'
require 'bugzillagerritbot'


BOT_OPTS = {
  greeting: true,
  bugzilla_alt: [],
  bugzilla_user: "",
  bugzilla_pass: "",
  bugzilla_url: String,
  gerrit_user: String,
  gerrit_port: 29418,
  gerrit_alt: [],
  gerrit_url: String,
  cache_expiry: 168,
  cache_file: "",
  server: "irc.freenode.net",
  nick: "batty",
  hush: 0,
  admins: [],
  data_dir: nil,
  user: "",
}
SHARED_OPTS = {
  config_file: "",
}
MAIN_OPTS = {
  cache_prefetch: [],
  cache_prefetch_gen: "",
  pid_file: "",
  channels: Array,
}
# at the bottom, so that
# "--port" gets the "-p"
# shortened form
BOT_OPTS2 = {
  port: 6667,
}

opts = SimpleOpts.get [BOT_OPTS, SHARED_OPTS, MAIN_OPTS, BOT_OPTS2],
                      config_file_opt: :config_file,
                      keep_config_file: true

channels = opts.delete :channels
if channels.empty?
  puts "no channel specified"
  exit 1
end
cache_prefetch = opts.delete :cache_prefetch
gen = opts.delete :cache_prefetch_gen
gen and cache_prefetch.concat(
  IO.popen(gen, &:read).strip.split(/\s*,\s*/))
pid_file = opts.delete :pid_file
pid_file and open(pid_file, "w") { |f| f.puts $$ }

bot = BugzillaGerritBot.new(**opts)

begin
  trap("INT"){ bot.quit }
  trap("USR1") {
    _,msg = bot.save_cache
    puts msg
  }

  bot.init_cache cache_prefetch: cache_prefetch
  bot.connect
  bot.join *channels
  bot.run
ensure
  pid_file and File.delete(pid_file)
end
