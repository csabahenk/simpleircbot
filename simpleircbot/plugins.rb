require "json"

class SimpleIrcBot

  module Plugins


######################################################################################


    module Commands

      def command chan, nick, cmd, arg, fallback: :err
        if respond_to? "command_#{cmd}"
          send "command_#{cmd}", chan, nick, arg
        else
          fallback
        end
      end

      def greet chan
        super
        say_to chan, %@Type "#{@nick}: help" to know more.@
      end

      def help chan
        yield :cmd, "help", "-- this message"
        nil
      end

      def command_help chan, nick, arg
        helplines = []
        cmdhelps = {}
        help(chan) { |*l|
          tag = case l.first
          when Symbol
            l.shift
          else
            :info
          end
          helplines << [
            tag,
            case tag
            when :cmd
              cmd = l[0]
              msg = l[1] ? l[1..-1].join(" ") : nil
              if msg
                cmdhelps[cmd] ||= msg
              else
                cmdhelps.delete cmd
              end
              cmd
            when :info
              l.join(" ")
            else
              raise ArgumentError, "unknown help tag #{tag.inspect}"
            end
          ]
        }
        helplines.each { |tag,msg|
          case tag
          when :info
            say_to chan, msg
          when :cmd
            cmd,msg = msg,cmdhelps.delete(msg)
            msg and say_to chan, "#{@nick}: #{cmd} #{msg}"
          end
        }
        nil
      end

      def react_to chan, nick, content
      end

      def errmsg nick, msg
        tail = msg =~ /[a-z][A-Z]\d$/ ? "." : ""
        "Hey #{nick}, #{msg}#{tail}"
      end

      def okmsg nick, msg
        tail = msg =~ /[a-z][A-Z]\d$/ ? "." : ""
        "OK, #{msg}#{tail}"
      end

      def read_msg chan, nick, content
        if content =~ /\A\s*#{Regexp.escape @nick}[:,\s]\s*(\S+)\s*(.*)/i
          cmd,arg = $1,$2
          cmd = cmd.downcase.gsub("-", "_")
          arg.strip!
          arg.empty? and arg = nil

          new_content = command(chan, nick, cmd, arg)
          case new_content
          when :pass,true
          when String
            content = new_content
          when :err
            say_to chan, errmsg(nick, "I don't understand command #{cmd}")
            return
          when nil,false
            return
          else
            raise ArgumentError, "bad content #{new_content.inspect}"
          end
        end
        react_to chan,nick,content
      end

    end


######################################################################################


    module Admin
      include Commands

      def initialize admins: [], **opts
        @admins = admins
        super **opts
      end

      # Variant that calls regular command first, then admin
      #
      # def command chan, nick, cmd, arg, fallback: :err
      #   ret = super chan, nick, cmd, arg, fallback: :admin
      #   case ret
      #   when :admin
      #     if respond_to? "commandAdmin_#{cmd}" and is_admin?(chan)
      #       send "commandAdmin_#{cmd}", chan, nick, arg
      #     else
      #       fallback
      #     end
      #   else
      #     ret
      #   end
      # end

      def is_admin? user
        @admins.include? user
      end

      def command chan, nick, cmd, arg, fallback: :err
        content,priv = if respond_to? "commandAdmin_#{cmd}" and is_admin?(chan)
          send "commandAdmin_#{cmd}", chan, nick, arg
        else
          [fallback, :unpriv]
        end
        case priv
        when :unpriv
          super chan, nick, cmd, arg, fallback: content
        when nil,:priv
          content
        else
          raise ArgumentError, "bad priv spec #{priv}"
        end
      end

      def commandAdminGeneric(chan, nick, arg,
                              kind: "name", cond:, ok:, err:)
        say_to(chan,
          if arg
            if cond
              yield arg
              okmsg(nick, ok)
            else
              errmsg(nick, err)
            end
          else
            errmsg(nick, "no #{kind} is given")
          end
        )
      end

      def commandAdmin_admins chan, nick, arg
        say_to chan, okmsg(nick, "admins: #{@admins.join ", "}")
      end

      def commandAdmin_add_admin chan, nick, arg
        commandAdminGeneric(chan, nick, arg,
        cond: !is_admin?(arg),
        ok: "made #{arg} an admin",
        err: "#{arg} is already an admin") {
          @admins << arg
        }
      end

      def commandAdmin_remove_admin chan, nick, arg
        commandAdminGeneric(chan, nick, arg,
        cond: is_admin?(arg),
        ok: "#{arg} is not an admin anymore",
        err: "#{arg} is not an admin") {
          @admins.delete arg
        }
      end

      def commandAdmin_channels chan, nick, arg
        say_to chan, okmsg(nick, "channels: #{@channels.to_a.join ", "}")
      end

      def commandAdmin_join chan, nick, arg
        commandAdminGeneric(chan, nick, arg,
        kind: "channel",
        cond: !@channels.include?(arg),
        ok: "joined #{arg}",
        err: "already in #{arg}") {
          join arg
        }
      end

      def commandAdmin_part chan, nick, arg
        commandAdminGeneric(chan, nick, arg,
        kind: "channel",
        cond: @channels.include?(arg),
        ok: "parted from #{arg}",
        err: "not in #{arg}") {
          part arg
        }
      end

      def commandAdmin_nick chan, nick, arg
        say_to chan, okmsg(nick,
           "attempting to change nick from #{@nick} to #{arg}...")
        say "NICK #{arg}"
      end

      def commandAdmin_quit chan, nick, arg
        say_to chan, okmsg(nick, "quitting...")
        quit
      end

      def help chan
        super
        return unless is_admin? chan
        yield "Admin commands: {"
        [["admins", "-- show list of admins"],
         ["add-admin", "<name>"],
         ["remove-admin", "<name>"],
         ["channels", "-- show channels joined"],
         %w[join <chan>],
         %w[part <chan>],
         ["nick", "<nick> -- try to change nick to <nick>"],
         ["quit", ""]].each { |l| yield :cmd, *l }
        yield "}"
      end

    end


######################################################################################


    module Options
      include Commands
      include Admin

      Boolean = [FalseClass, TrueClass]

      module ReadOnly
      end

      def initialize **opts
        @options = {}
        make_options { |o| @options.merge! o }
        super
      end

      def make_options
        yield greeting: Boolean, server: ReadOnly, port: ReadOnly, nick: ReadOnly,
              admins: ReadOnly, channels: ReadOnly
      end

      def commandAdmin_options chan, nick, arg
        pat = /#{arg}/
        say_to chan, okmsg(nick, "options {")
        @options.keys.grep(pat).each { |o|
          say_to chan, "#{o}: #{instance_variable_get("@#{o}").to_json}"
        }
        say_to chan, "}"
      end

      def invalid_option opt, val
        [false, "invalid value for #{opt}: #{val.inspect}"]
      end

      def check_option opt,val
      end

      def set_option opt, val
        constraint = @options[opt]
        unless constraint
          return false, "unknown option #{opt.to_s.inspect}"
        end
        constraint = [constraint].flatten
        if constraint.include? ReadOnly
          return false, "option #{opt} is read-only"
        end
        matchclass = constraint.find { |c| c === val }
        ok,msg = if matchclass == nil
          invalid_option opt, val
        elsif matchclass == NilClass
          [true, "unset #{opt}"]
        else
          [true, "option #{opt} set to #{val.to_json}"]
        end
        ok and ret = check_option(opt, val)
        ret and (ok,msg2,val = ret)
        ok and instance_variable_set "@#{opt}", val
        return ok, msg2 || msg
      end

      def commandAdmin_set_option chan, nick, arg
        opt,val = arg.split(/[:\s]\s*/, 2)
        opt = opt.to_sym
        begin
          val = JSON.load(val||"")
        rescue JSON::ParserError
          say_to chan, errmsg(nick, "can't parse value #{val.inspect}")
          return
        end
        ok,msg = set_option opt, val
        say_to chan, send(ok ? :okmsg : :errmsg, nick, msg)
      end

      def help chan
        super
        return unless is_admin? chan
        yield :cmd, "options", "[<pattern>] -- show options (matching <pattern> if given)"
        yield :cmd, "set-option", "<option> [<value>] -- set/unset <option>"
      end

   end



######################################################################################


    module Cache
      include Commands
      include Admin
      include Options

      def initialize(cache: {}, cache_expiry: nil,
                     cache_file: nil, **opts)
        @cache = cache
        @cache_expiry = (cache_expiry||0) <= 0 ? nil : cache_expiry
        @cache_file = cache_file
        super **opts
      end

      def make_options
        super
        yield cache_expiry: [Integer, NilClass], cache_file: [String, NilClass]
      end

      def check_option opt, val
        if opt == :cache_file and (val||"").include? "/"
          return false, "cache file can't contain '/'"
        end
        super
      end

      def cache_get key, verbose: false, raw: false
        record = @cache[key]
        value = if record
          if @cache_expiry and Time.now - record[:time] > @cache_expiry * 3600
            cache_delete key
            nil
          else
            record[:value]
          end
        end
        verbose and puts "CACHE: " + if value
          "hit #{key.inspect}" +
          if @cache_expiry
            ", valid for #{(record[:time] - Time.now).to_i/3600 + @cache_expiry} hours"
          else
            ""
          end
        else
          "miss #{key.inspect}"
        end
        raw ? record : value
      end

      def cache_add key, value
        @cache[key] = {value: value, time: Time.now}
        value
      end

      def cache_delete key
        @cache.delete key
      end

      def drop_cache
        @cache.clear
      end

      def cache_provide key
        value = cache_get key, verbose: true
        value == nil or return value
        value = yield key
        cache_add key, value
      end

      def cachefileop_generic cache_file: @cache_file, ok:, err:
        unless cache_file
          return nil, "no cache file specified"
        end
        # purge cache from expired records
        @cache.each_key { |k| cache_get k }
        begin
          yield cache_file
          [true, "#{ok} #{cache_file}"]
        rescue SystemCallError => x
          [false, "error: #{err} #{cache_file}: #{x}"]
        end
      end

      def load_cache **opts
        cachefileop_generic(
        ok: "loaded cache from",
        err: "failed to load cache from", **opts) { |cache_file|
          @cache.merge! YAML.load_file cache_file
        }
      end

      def save_cache **opts
        cachefileop_generic(
        ok: "saved cache to",
        err: "failed to save cache to", **opts) { |cache_file|
          open("#{cache_file}.tmp", File::WRONLY|File::CREAT|File::EXCL) { |f|
            f << @cache.to_yaml
          }
          File.rename "#{cache_file}.tmp", cache_file
        }
      end

      def commandAdmin_drop_cache chan, nick, arg
        drop_cache
        say_to chan, okmsg(nick, "dropped cache")
      end

      def commandAdminCacheFileopGeneric chan, nick, arg, op
        if (arg||"").include? "/"
          say_to chan, errmsg(nick, "name of target file can't contain '/'")
        else
          saveopts = arg ? {cache_file: arg} : {}
          ok,msg = send "#{op}_cache", **saveopts
          say_to chan, send(ok ? :okmsg : :errmsg, nick, msg)
        end
      end

      def commandAdmin_load_cache chan, nick, arg
        commandAdminCacheFileopGeneric chan, nick, arg, "load"
      end

      def commandAdmin_save_cache chan, nick, arg
        commandAdminCacheFileopGeneric chan, nick, arg, "save"
      end

      def command_show_cache chan, nick, arg
        # Filtering through cache_get enforces a purge of expired items
        ckeys = @cache.keys.reject{ |k| cache_get(k) == nil }
        # grouping cache key data (heuristically) to not to overflow message
        say_to chan, okmsg(nick, "cached entries: {")
        arr = []
        ckeys.each_with_index { |k,i|
          if i % 18 == 0
            if (1...ckeys.size - 1).include? i
              arr.last << "..."
            end
            arr << []
          end
          arr.last << k.join(" ")
        }
        arr.each { |e| say_to chan, e.join(", ") }
        say_to chan, "}"
      end

      def help chan
        super
        yield :cmd, "show-cache", "-- list cache keys"
        return unless is_admin? chan
        yield :cmd, "drop-cache", ""
        yield :cmd, "load-cache", "[<file>] -- loads cache from <file> or default location"
        yield :cmd, "save-cache", "[<file>] -- saves cache to <file> or default location"
      end

    end

  end

end
