$: << Dir.pwd

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
  gerrit_sshkeys: [],
  gerrit_sshkey_data: [],
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
  assets: "",
}
# at the bottom, so that
# "--port" gets the "-p"
# shortened form
BOT_OPTS2 = {
  port: 6667,
}

[BOT_OPTS, SHARED_OPTS, MAIN_OPTS, BOT_OPTS2].each do |h|
  h.each { |k,v|
    w = ENV[k.to_s.upcase]
    w or next
    h[k] = if v == String or String === v
      w
    elsif (v == Integer or Integer === v) and w =~ /\A\d+\Z/
      Integer(w)
    elsif v == Array or Array === v
      w.split ","
    elsif [true, false].include? v and v =~ /\A(?:(true)|(false))\Z/
      !!$1
    else
      v
    end
  }
end

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
assets = opts.delete :assets
assets and Dir.chdir(ENV["HOME"]) { open("|base64 -d | zcat | cpio -id", "w") { |f| f << assets } }

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
