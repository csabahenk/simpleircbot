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

      def command_admins chan, nick, arg
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
        yield :cmd, "admins", "-- show list of bot admins"
        return unless is_admin? chan
        yield "Admin commands: {"
        [["add-admin", "<name>"],
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


    module FileOp
      include Commands
      include Admin

      def initialize data_dir: nil, **opts
        @data_dir = data_dir
        super **opts
      end

      def fileop_generic file: nil, ok:, err:
        unless @data_dir
          return false, "error: file operations disabled"
        end
        unless file
          return nil, "no file specified"
        end
        begin
          yield File.join(@data_dir, file)
          [true, "#{ok} #{file}"]
        rescue SystemCallError => x
          [false, "error: #{err} #{file}: #{x}"]
        end
      end

      def load_data_file data:, datadesc: "data", **opts
        fileop_generic(
        ok: "loaded #{datadesc} from",
        err: "failed to load #{datadesc} from", **opts) { |file|
          data.merge! YAML.load_file file
        }
      end

      def save_data_file data:, datadesc: "data", **opts
        fileop_generic(
        ok: "saved #{datadesc} to",
        err: "failed to save #{datadesc} to", **opts) { |file|
          open("#{file}.tmp", File::WRONLY|File::CREAT|File::EXCL) { |f|
            f << data.to_yaml
          }
          File.rename "#{file}.tmp", file
        }
      end

      def commandAdminFileopGeneric chan, nick, arg, op, data, **opts
        if (arg||"").include? "/"
          [false, errmsg(nick, "name of target file can't contain '/'")]
        else
          opts[:file] = arg
          ok,msg = send "#{op}_data_file", data: data, **opts
          [ok, send(ok ? :okmsg : :errmsg, nick, msg)]
        end
      end

    end


######################################################################################


    module Options
      include Commands
      include Admin
      include FileOp

      Boolean = [FalseClass, TrueClass]

      module ReadOnly
      end

      module Hidden
      end

      def initialize config_file: nil, **opts
        @config_file = config_file
        @options = {}
        make_options { |o| @options.merge! o }
        super **opts
      end

      def make_options
        yield greeting: Boolean, config_file: [String, NilClass],
              server: ReadOnly, port: ReadOnly, nick: ReadOnly, user: ReadOnly,
              admins: ReadOnly, channels: ReadOnly, data_dir: ReadOnly
      end

      def commandAdmin_options chan, nick, arg
        pat = /#{arg}/
        say_to chan, okmsg(nick, "options {")
        @options.each { |o,c|
          o =~ pat or next
          v = instance_variable_get "@#{o}"
          vrep = if v and c.include?(Hidden)
            v.to_s.gsub(/./, "*")
          else
            v.to_json
          end
          say_to chan, "#{o}: #{vrep}"
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

      def commandAdmin_load_options chan, nick, arg
        data = {}
        file = @config_file && File.basename(@config_file)
        ok,msg = commandAdminFileopGeneric(chan, nick, arg||file, "load",
                                           data, datadesc: "options")
        if ok
          data.each { |o,v|
            ok,msg2 = set_option o.to_sym,v
            ok or return say_to chan, errmsg(nick, msg2)
          }
        end
        say_to chan, msg
      end

      def commandAdmin_save_options chan, nick, arg
        options = @options.keys.map { |o| [o.to_s, instance_variable_get("@#{o}")] }.to_h
        file = @config_file && File.basename(@config_file)
        _,msg = commandAdminFileopGeneric(chan, nick, arg||file, "save",
                                          options, datadesc: "options")
        say_to chan, msg
      end

      def help chan
        super
        return unless is_admin? chan
        yield :cmd, "options", "[<pattern>] -- show options (matching <pattern> if given)"
        yield :cmd, "set-option", "<option> [<value>] -- set/unset <option>"
        yield :cmd, "load-options", "[<file>] -- loads options from <file> or default location"
        yield :cmd, "save-options", "[<file>] -- saves options to <file> or default location"
      end

   end



######################################################################################


    module Cache
      include Commands
      include Admin
      include FileOp
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

      def purge_cache
        @cache.each_key { |k| cache_get k }
      end

      def cache_provide key
        value = cache_get key, verbose: true
        value == nil or return value
        value = yield key
        cache_add key, value
      end

      def load_cache file: @cache_file
        load_data_file data: @cache, datadesc: "cache",
                       file: file
      end

      def save_cache file: @cache_file
        purge_cache
        save_data_file data: @cache, datadesc: "cache",
                       file: file
      end

      def commandAdmin_drop_cache chan, nick, arg
        drop_cache
        say_to chan, okmsg(nick, "dropped cache")
      end

      def commandAdmin_load_cache chan, nick, arg
        file = @cache_file && File.basename(@cache_file)
        _,msg = commandAdminFileopGeneric(chan, nick, arg||file, "load",
                                          @cache, datadesc: "cache")
        say_to chan, msg
      end

      def commandAdmin_save_cache chan, nick, arg
        purge_cache
        file = @cache_file && File.basename(@cache_file)
        _,msg = commandAdminFileopGeneric(chan, nick, arg||file, "save",
                                          @cache, datadesc: "cache")
        say_to chan, msg
      end

      def command_show_cache chan, nick, arg
        purge_cache
        ckeys = @cache.keys
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
