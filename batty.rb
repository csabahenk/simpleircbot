#!/usr/bin/env ruby

require 'open-uri'
require 'cgi'
require 'yaml'

require 'simpleopts'
require 'simpleircbot'


######################################################################################


module BugzillaGerritBot

  def initialize **opts
    (@opts||={}).merge! opts
    super **_initialize_bugzillageritbot(**opts)
  end

  def _initialize_bugzillageritbot(
        bugzilla_url:, gerrit_url: ,
        bugzilla_alt: [], gerrit_alt: [],
        gerrit_user: nil, gerrit_port: 29418,
        cache: {}, cache_expiry: nil, hush: nil,
        **opts)
    @bugzilla = bugzilla_url.sub(%r@\Ahttps?://@, "")
    @bugzilla_alt = bugzilla_alt
    @gerrit_user = gerrit_user
    @gerrit = gerrit_url.sub(%r@\Ahttps?://@, "")
    @gerrit_alt = gerrit_alt
    @gerrit_port = gerrit_port
    @cache = cache
    @cache_expiry = (cache_expiry||0) <= 0 ? nil : cache_expiry
    @hush = (hush||0) <= 0 ? nil : hush
    opts
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


  class ChanMember < SimpleIrcBot::ChanMember
  end

  class Bot < SimpleIrcBot::Bot
    include BugzillaGerritBot

    MemberClass = ChanMember

    def init_cache cache_file: nil, cache_prefetch: []
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

  end


  class ChanMember < SimpleIrcBot::ChanMember
    include BugzillaGerritBot

    def initialize **opts
      @accesslog = {}
      super
    end

    def greet
      say_to_chan "Whenever I see references to Bugzilla bugs or Gerrit changes, like..."
      say_to_chan "... BZ 36734, gerrit:531232 ..."
      say_to_chan "... or URLs like..."
      say_to_chan " #{@bugzilla}/36734, #{@gerrit}/531232 ..."
      sleep 1
      say_to_chan " "
      say_to_chan "... I tell it like it is!".upcase
      sleep 1
      say_to_chan " "
      say_to_chan %@Please message "#{@nick}: help" to know more.@
    end

    def react_to nick, content

      # bot admin/inquiry commands...
      if content =~ /\A\s*#{Regexp.escape @nick}[:,\s]\s*(\S+)\s*(.*)/i
        cmd,arg = $1.downcase,$2.strip
        case cmd
        when "forget"
          @cache.clear
          @accesslog.clear
          say_to_chan "OK, I forgot everything!"
        when "refetch"
          items = []
          [[_BUGZILLA_RX, :bugzilla],
           [_GERRIT_RX, :gerrit]
          ].each { |rx, service|
            arg.scan(rx).flatten.uniq.each { |id|
              cache_delete service, id
              @accesslog.delete [service, id]
              items << [service, id]
            }
          }
          if items.empty?
            say_to_chan "Hey #{nick}, nothing to refetch."
          else
            react_to nick, items.map { |service,id| "#{service}:#{id}" }.join(" ")
          end
        when /\A(show-?cache|cache-?show)\Z/
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
          arr.each { |e| say_to_chan e.join(" ") }
        when "help"
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
           "Besides the following service commands are taken:",
           %@"#{@nick}: show-cache" -- shows cached entries@,
           %@"#{@nick}: refetch <bugzilla or gerrit ref>, ..." -- refetch refs@,
           %@"#{@nick}: forget" -- empty the cache@,
           %@"#{@nick}: help" -- shows this message.@,
          " ",
          "Drop stars to https://github.com/csabahenk/simpleircbot ;)"].each {|msg|
            say_to_chan msg
          }
        else
          say_to_chan "Hey #{nick}, I don't undestand command #{cmd}."
        end
        return
      end

      hushed = proc { |service,id|
        @hush and (@accesslog[[service, id]]||Time.at(0)) + @hush > Time.now
      }

      # Bugzilla #1...
      process_bugzilla = proc { |bz,decor=""|
        buginfo = cache_fetch(:bugzilla, bz)
        unless hushed[:bugzilla, bz]
          @accesslog[[:bugzilla, bz]] = Time.now
          say_to_chan decor + bugzilla_url(bz), buginfo
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
          say_to_chan *changeinfo.values_at("url", "subject")
          gerrit_get_bugs(changeinfo) {|bz|
            process_bugzilla[bz, "`-> "]
            # We don't need to report this bz once more.
            bugs.delete bz
          }
        else
          say_to_chan "#{@gerrit}: change #{change} not found"
        end
      }

      # Bugzilla #2
      bugs.each &process_bugzilla
    end

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
    server: "irc.freenode.net",
    nick: "batty",
    hush: 0,
  }
  MAIN_OPTS = {
    cache_prefetch: [],
    cache_prefetch_gen: "",
    config_file: "",
    pid_file: "",
    cache_file: "",
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
  cache_init_opts = %i[cache_file cache_prefetch].map { |o|
    [o, opts.delete(o)]
  }.to_h
  gen = opts.delete :cache_prefetch_gen
  gen and cache_init_opts[:cache_prefetch].concat(
    IO.popen(gen, &:read).strip.split(/\s*,\s*/))
  pid_file = opts.delete :pid_file
  pid_file and open(pid_file, "w") { |f| f.puts $$ }

  opts[:cache] = {}
  bot = BugzillaGerritBot::Bot.new(**opts)

  begin
    trap("INT"){ bot.quit }
    trap("USR1") {
      opts[:cache].each_key { |k| bot.cache_get *k }
      cache_file = cache_init_opts[:cache_file]
      next unless cache_file
      puts begin
        open("#{cache_file}.tmp", File::WRONLY|File::CREAT|File::EXCL) { |f|
          f << opts[:cache].to_yaml
        }
        File.rename "#{cache_file}.tmp", cache_file
        "saved cache to #{cache_file}."
      rescue SystemCallError => x
        "error: failed save cache: #{x}"
      end
    }

    bot.init_cache **cache_init_opts
    bot.connect
    bot.join *channels
    bot.run
  ensure
    pid_file and File.delete(pid_file)
  end

end
