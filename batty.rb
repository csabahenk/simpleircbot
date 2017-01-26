#!/usr/bin/env ruby

require 'open-uri'
require 'cgi'
require 'yaml'

require 'simpleopts'
require 'simpleircbot'


######################################################################################


class BugzillaGerritBot < SimpleIrcBot

  def initialize(
        bugzilla_url:, gerrit_url: ,
        bugzilla_alt: [], gerrit_alt: [],
        gerrit_user: nil, gerrit_port: 29418,
        cache: {}, cache_expiry: nil,
        cache_file: nil, admins: [], hush: nil,
        **opts)
    @bugzilla = bugzilla_url.sub(%r@\Ahttps?://@, "")
    @bugzilla_alt = bugzilla_alt
    @gerrit_user = gerrit_user
    @gerrit = gerrit_url.sub(%r@\Ahttps?://@, "")
    @gerrit_alt = gerrit_alt
    @gerrit_port = gerrit_port
    @cache = cache
    @cache_expiry = (cache_expiry||0) <= 0 ? nil : cache_expiry
    @cache_file = cache_file
    @admins = admins
    @hush = (hush||0) <= 0 ? nil : hush
    @accesslog = {}
    super **opts
  end

  def cache_get *keys, verbose: false
    record = @cache[keys]
    value = if record
      if @cache_expiry and Time.now - record[:time] > @cache_expiry * 3600
        cache_delete *keys
        nil
      else
        record[:value]
      end
    end
    verbose and puts "CACHE: " + if value
      "hit #{keys.inspect}" +
      if @cache_expiry
        ", valid for #{(record[:time] - Time.now).to_i/3600 + @cache_expiry} hours"
      else
        ""
      end
    else
      "miss #{keys.inspect}"
    end
    value
  end

  def cache_add value, *keys
    @cache[keys] = {value: value, time: Time.now}
    value
  end

  def cache_delete *keys
    @cache.delete keys
  end

  def cache_provide *keys
    value = cache_get *keys, verbose: true
    value and return value
    value = yield *keys
    cache_add value, *keys
  end

  def cache_fetch service, id
    cache_provide service, id, &method(:fetch)
  end

  def fetch service, id
    send "fetch_#{service}", id
  end

  def bugzilla_url bz
    "https://#{@bugzilla}/#{bz}"
  end

  def fetch_bugzilla bz
    title = "Bug not found :("
    open(bugzilla_url bz) {|f|
      while l=f.gets
        if l =~ %r@<title>(.*)</title>@
          # CGI.unescapeHTML does not know of ndash :/
          title = CGI.unescapeHTML $1.gsub("&ndash;", "–")
          break
        end
      end
    }
    title
  end

  def fetch_gerrit change
    changedata = IO.popen(
      ["ssh", "#{@gerrit_user}@#{@gerrit}", "-p", "#{@gerrit_port}",
       %w[gerrit query --format=json --patch-sets], change].flatten, &:read)
    changeinfo = begin
      # what comes is a JSON stream, ie. concatenated JSON objects,
      # but JSON can do only a single object, so instead we use YAML
      changeinfo = YAML.load changedata
    rescue Psych::SyntaxError
    end
    case changeinfo
    when Hash
      changeinfo = %w[url subject commitMessage].instance_eval {
        zip(changeinfo.values_at *self).to_h
      }
      changeinfo.values.include? nil and changeinfo = nil
    end
    changeinfo
  end

  BUGZILLA_TOKENS = %w[bz bug bugzilla]
  def _BUGZILLA_RX
    %r@(?:(?:#{SimpleIrcBot.regexp_join @bugzilla, @bugzilla_alt})/(?:show_bug.cgi\?id=)?|(?:\A|\s)(?:#{BUGZILLA_TOKENS.join "|"})[:\s]\s*)(\d+)@i
  end

  GERRIT_TOKENS = %w[change review gerrit]
  def _GERRIT_RX
    %r@(?:(?:#{SimpleIrcBot.regexp_join @gerrit, @gerrit_alt})/(?:#/c/)?|(?:\A|\s)(?:#{GERRIT_TOKENS.join "|"})[:\s]\s*)(\d+|I?[\da-f]{6,})@i
  end

  TOKEN_MAP = {bugzilla: BUGZILLA_TOKENS, gerrit: GERRIT_TOKENS}.map { |tv,ta|
    ta.map { |t| [t, tv] }
  }.inject(&:+).to_h

  def gerrit_get_bugs changeinfo
    changeinfo["commitMessage"].each_line {|l|
      if l =~ /\A\s*#{_BUGZILLA_RX}\s*\Z/
        yield $1
      end
    }
  end

  def init_cache cache_file: @cache_file, cache_prefetch: []
    cache_file and begin
      @cache.merge! YAML.load_file cache_file
    rescue Errno::ENOENT
      puts "warning: cache file does not exist"
    end
    prefetch_size = cache_prefetch.size
    cache_prefetch.each_with_index { |token,i|
      service_tok, id = token.split(":", 2)
      service = TOKEN_MAP[service_tok]
      print "pre-fetching #{i+1}/#{prefetch_size}... "
      val = cache_fetch service, id
      if service == :gerrit and val
        j = 1
        gerrit_get_bugs(val) { |bz|
          print "pre-fetching #{i+1}:#{j}/#{prefetch_size}..."
          cache_fetch :bugzilla, bz
          j += 1
        }
      end
    }
  end

  def save_cache cache_file: @cache_file
    unless cache_file
      return nil, "no cache file specified"
    end
    # purge cache from expired records
    @cache.each_key { |k| cache_get *k }
    begin
      open("#{cache_file}.tmp", File::WRONLY|File::CREAT|File::EXCL) { |f|
        f << @cache.to_yaml
      }
      File.rename "#{cache_file}.tmp", cache_file
      [true, "saved cache to #{cache_file}"]
    rescue SystemCallError => x
      [false, "error: failed save cache: #{x}"]
    end
  end

  def greet chan
    say_to chan, "Whenever I see references to Bugzilla bugs or Gerrit changes, like..."
    say_to chan, "... BZ 36734, gerrit:531232 ..."
    say_to chan, "... or URLs like..."
    say_to chan, " #{@bugzilla}/36734, #{@gerrit}/531232 ..."
    sleep 1
    say_to chan, " "
    say_to chan, "... I tell it like it is!".upcase
    sleep 1
    say_to chan, " "
    say_to chan, %@Please message "#{@nick}: help" to know more.@
  end

  def respond_to chan, nick, cmd, arg
    # bot admin/inquiry commands...

    scanitems = proc { |&blk|
      [[_BUGZILLA_RX, :bugzilla],
       [_GERRIT_RX, :gerrit]
      ].each { |rx, service|
        arg.scan(rx).flatten.uniq.each { |id|
          blk[[service, id]]
        }
      }
    }

    # General commands
    do_admin = false
    case cmd
    when "forget"
      @cache.clear
      @accesslog.clear
      say_to chan, "OK, I forgot everything!"
    when "refetch"
      items = []
      scanitems.call { |ref|
        cache_delete *ref
        @accesslog.delete ref
        items << ref
      }
      if items.empty?
        say_to chan, "Hey #{nick}, nothing to refetch."
      else
        return items.map { |service,id| "#{service}:#{id}" }.join(" ")
      end
    when /\A(show-?cache|cache-?show)\Z/
      items = []
      scanitems.call { |ref| items << ref }
      if items.empty?
        # Filtering through cache_get enforces a purge of expired items
        ckeys = @cache.keys.select{ |k| cache_get *k }
        ckeys.map! { |s,i| "#{s}:#{i}" }
        # grouping cache key data (heuristically) to not to overflow message
        arr = [["OK, cached entries:"]]
        ckeys.each_with_index { |k,i|
          if i % 18 == 0 and i > 0
            if i < ckeys.size - 1
              arr.last << "..."
            end
            arr << []
          end
          arr.last << k
        }
        arr.each { |e| say_to chan, e.join(" ") }
      else
        data = {}
        items.each { |ref|
          cache_get *ref
          # we want the whole record, not just the
          # data part, so we access the cache directly
          rec = @cache[ref]
          rec and data[ref] = rec
        }
        say_to chan, "OK, cached items:"
        data.to_yaml.each_line { |l| say_to chan, l }
      end
      say_to chan, "<end>"
    when "help"
      admin_help = if @admins.include? chan
        [
         %@"#{@nick}: admins -- show list of admins@,
         %@"#{@nick}: {add,remove}-admin <name>@,
         %@"#{@nick}: channels -- show channels joined@,
         %@"#{@nick}: join <chan>@,
         %@"#{@nick}: part <chan>@,
         %@"#{@nick}: save-cache [<file>] -- saves cache to default location or <file>@
        ]
      else
        []
      end

      help = [
       "This is #{@nick} bot on the mission to resolve Bugzilla and Gerrit references.",
       " ",
       "Syntax:",
       %@"#{BUGZILLA_TOKENS.join "|"} <bug-id>" for Bugzilla@,
       %@"#{GERRIT_TOKENS.join "|"} <change-id>" for Gerrit.@,
       "Case does not matter and a colon separator is also accepted,",
       %@So "BZ:23432" and "Gerrit: 42355" are fine too.@,
       "URLs like #{@bugzilla}/23432 and #{@gerrit}/42355 are understood,",
       "and also variants like #{@bugzilla}/show-bug.cgi?id=23432 and",
       "#{@gerrit}/#/c/42355.",
       " ",
       "Besides the following service commands are taken:",
       %@"#{@nick}: refetch <bugzilla or gerrit ref>, ..." -- refetch refs@,
       %@"#{@nick}: show-cache [<ref>...]" -- shows cached entries@,
       %@"#{@nick}: forget" -- empty the cache@,
       admin_help,
       %@"#{@nick}: help" -- shows this message.@,
       " ",
       "Drop stars to https://github.com/csabahenk/simpleircbot ;)"
      ]
      help.flatten.each {|msg|
        say_to chan, msg
      }
    else
      if @admins.include? chan
        do_admin = true
      else
        say_to chan, "Hey #{nick}, I don't undestand command #{cmd}."
      end
    end
    return unless do_admin

    # Admin commands (only for private peers)

    mgmt_cmd = proc { |kind: "name",cond:,okmsg:,failmsg:,&action|
      say_to chan,(if arg.empty?
        "Hey #{nick}, no #{kind} given."
      elsif cond
        action[]
        "OK, #{okmsg}."
      else
        "Hey #{nick}, #{failmsg}."
      end)
    }

    case cmd
    when "admins"
      say_to chan, "OK, admins: #{@admins.join " "}."
    when /\Aadd-?admin|admin-?add\Z/
      mgmt_cmd.call(
        cond: !@admins.include?(arg),
        okmsg: "made #{arg} an admin",
        failmsg: "#{arg} is already an admin") {
        @admins << arg
      }
    when /\Aremove-?admin|admin-?remove\Z/
      mgmt_cmd.call(
        cond: @admins.include?(arg),
        okmsg: "#{arg} is not an admin anymore",
        failmsg: "#{arg} is not an admin") {
        @admins.delete arg
      }
    when "channels"
      say_to chan, "OK, channels: #{@channels.to_a.join " "}."
    when "join"
      mgmt_cmd.call(
        kind: "channel",
        cond: !@channels.include?(arg),
        okmsg: "joined #{arg}",
        failmsg: "already in #{arg}") {
        join arg
      }
    when "part"
      mgmt_cmd.call(
        kind: "channel",
        cond: @channels.include?(arg),
        okmsg: "parted from #{arg}",
        failmsg: "not in #{arg}") {
        part arg
      }
    when "quit"
      say_to chan, "OK, quitting..."
      quit
    when /\A(save-?cache|cache-?save)\Z/
      if arg =~ %r@\A/@
        say_to chan, "Hey #{nick}, please specify a relative path to save the cache to."
      else
        saveopts = arg.empty? ? {} : {cache_file: arg}
        ok,msg = save_cache **saveopts
        prefix = ok ? "OK" : "Hey #{nick}"
        say_to chan, "#{prefix}, #{msg}."
      end
    else
      say_to chan, "Hey #{nick}, I don't undestand command #{cmd}."
    end
  end

  def react_to chan, nick, content
    hushed = proc { |service,id|
      @hush and (@accesslog[[service, id]]||Time.at(0)) + @hush > Time.now
    }

    # Bugzilla #1...
    process_bugzilla = proc { |bz,decor=""|
      buginfo = cache_fetch(:bugzilla, bz)
      unless hushed[:bugzilla, bz]
        @accesslog[[:bugzilla, bz]] = Time.now
        say_to chan, decor + bugzilla_url(bz), buginfo
      end
    }
    bugs = content.scan(_BUGZILLA_RX).flatten.uniq

    # Gerrit...
    content.scan(_GERRIT_RX).flatten.uniq.each { |change|
      changeinfo = cache_fetch(:gerrit, change)
      if hushed[:gerrit, change]
        next
      else
        @accesslog[[:gerrit, change]] = Time.now
      end
      case changeinfo
      when Hash
        say_to chan, *changeinfo.values_at("url", "subject")
        gerrit_get_bugs(changeinfo) {|bz|
          process_bugzilla[bz, "`-> "]
          # We don't need to report this bz once more.
          bugs.delete bz
        }
      else
        say_to chan, "#{@gerrit}: change #{change} not found"
      end
    }

    # Bugzilla #2
    bugs.each &process_bugzilla
  end

end


######################################################################################


if __FILE__ == $0
  BOT_OPTS = {
    greeting: true,
    bugzilla_alt: [],
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
  }
  MAIN_OPTS = {
    cache_prefetch: [],
    cache_prefetch_gen: "",
    config_file: "",
    pid_file: "",
    channels: Array,
  }
  # at the bottom, so that
  # "--port" gets the "-p"
  # shortened form
  BOT_OPTS2 = {
    port: 6667,
  }

  opts = SimpleOpts.get [BOT_OPTS, MAIN_OPTS, BOT_OPTS2],
                        config_file_opt: :config_file

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

end
