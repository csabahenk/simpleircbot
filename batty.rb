#!/usr/bin/env ruby

require 'open-uri'
require 'cgi'
require 'yaml'

require 'simpleopts'
require 'simpleircbot'


######################################################################################


class BugzillaGerritBot < SimpleIrcBot
  include SimpleIrcBot::Commands
  include SimpleIrcBot::Admin
  include SimpleIrcBot::Cache

  def initialize(
        bugzilla_url:, gerrit_url: ,
        bugzilla_alt: [], gerrit_alt: [],
        gerrit_user: nil, gerrit_port: 29418,
        hush: nil,
        **opts)
    @bugzilla = bugzilla_url.sub(%r@\Ahttps?://@, "")
    @bugzilla_alt = bugzilla_alt
    @gerrit_user = gerrit_user
    @gerrit = gerrit_url.sub(%r@\Ahttps?://@, "")
    @gerrit_alt = gerrit_alt
    @gerrit_port = gerrit_port
    @hush = (hush||0) <= 0 ? nil : hush
    @accesslog = {}
    super **opts
  end

  def greet chan
    say_to chan, "Resolving Bugzilla andr Gerrit references."
  end

  def init_cache cache_prefetch: [], **opts
    load_cache **opts
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

  def cache_fetch service, id
    cache_provide [service, id], &method(:fetch)
  end

  def fetch ref
    service,id = ref
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
      false
    end
    case changeinfo
    when Hash
      changeinfo = %w[url subject commitMessage].instance_eval {
        zip(changeinfo.values_at *self).to_h
      }
      changeinfo.values.include? nil and changeinfo = false
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

  def scanitems arg
    p [:scanitems, arg, _BUGZILLA_RX ]
    [[_BUGZILLA_RX, :bugzilla],
     [_GERRIT_RX, :gerrit]
    ].each { |rx, service|
      arg.scan(rx).flatten.uniq.each { |id|
        yield [service, id]
      }
    }
  end

  def command_refetch chan, nick, arg
    items = []
    scanitems(arg||"") { |ref|
      cache_delete ref
      @accesslog.delete ref
      items << ref
    }
    if items.empty?
      say_to chan, errmsg(nick, "nothing to refetch")
    else
      return items.map { |service,id| "#{service}:#{id}" }.join(" ")
    end
  end

  # Extending the show-cache command to
  # be able to show full records for cache
  # keys given in arg.
  #
  # This would be nice to do in Cache module
  # but is problematic there, as there is no
  # consensual way to parse the cache keys from
  # arg. However, in this context we do have
  # our way to parse the commandline, so we
  # can do this.
  def command_show_cache chan, nick, arg
    items = []
    scanitems(arg||"") { |ref| items << ref }
    if items.empty?
      super
    else
      data = {}
      items.each { |ref|
        rec = cache_get ref, raw: true
        rec and data[ref] = rec
      }
      say_to chan, okmsg(nick, "cached items: {")
      data.to_yaml.each_line { |l| say_to chan, l }
      say_to chan, "}"
    end
  end

  def commandAdmin_forget chan, nick, msg
    drop_cache
    @accesslog.clear
    say_to chan, okmsg(nick, "I forgot everything")
  end

  def help chan
    ["This is #{@nick} bot on the mission to resolve Bugzilla and Gerrit references.",
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
     "Besides the following service commands are taken:"].each { |l| yield l }
    [["refetch", "<bugzilla or gerrit ref>, ... -- refetch refs"],
     ["show-cache", "[<ref>...] -- shows cached entries"], ].each { |a|
      yield :cmd, *a
    }
    is_admin?(chan) and yield :cmd, "forget", "-- empty the cache"
    super
    yield " "
    yield "Drop stars to https://github.com/csabahenk/simpleircbot ;)"
    # Suppressing drop-cache help as it would confusingly overlap
    # with forget.
    yield :cmd, "drop-cache", nil
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
