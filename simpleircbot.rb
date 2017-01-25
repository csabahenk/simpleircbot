#!/usr/bin/env ruby

require 'socket'


######################################################################################


module SimpleIrcBot

  def self.regexp_join *a
    a.flatten.map{ |e| Regexp.escape e }.join("|")
  end

  def _get_common_irc_opts nick:, **opts
    @nick = nick
    opts
  end
  private :_get_common_irc_opts

  def say(msg)
    puts msg
    @socket.puts msg
  end

  class ChanMember
  end

  class Bot
    include SimpleIrcBot

    MemberClass = ChanMember

    def initialize(server:, port: 6667,
                   memberclass: self.class.const_get(:MemberClass), **opts)
      @server = server
      @port = port
      @bots = {}
      @memberclass = memberclass
      if @opts
        # upper layer captured opts already,
        # we have to take care to clear our
        # private ones also from that
        %i[server port].each { |o| @opts.delete o }
      else
        @opts = opts
      end
      _get_common_irc_opts **opts
    end

    def connect
      @socket = TCPSocket.open(@server, @port)
      say "NICK #{@nick}"
      say "USER ircbot 0 * #{@nick}"
    end

    def run
      until @socket.eof? do
        msg = @socket.gets
        puts msg

        if msg.match(/^PING :(.*)$/)
          say "PONG #{$~[1]}"
          next
        end

        chans,privs = @bots.keys.partition {|c| c =~ /^#/ }

        #put matchers here
        nick,chan,content = case msg
        when /^:([^!]+)!.*PRIVMSG (#{SimpleIrcBot.regexp_join chans}) :(.*)$/
          [$1,$2,$3]
        when /^:(#{SimpleIrcBot.regexp_join privs})!.*PRIVMSG #{Regexp.escape @nick} :(.*)$/
          [$1,$1,$2]
        end
        chan and @bots[chan].react_to nick,content
      end
    end

    def join *channels
      channels.each { |chan|
        @bots[chan] = @memberclass.new(socket: @socket, channel: chan, **@opts)
        @bots[chan].join
      }
    end

    def quit
      @bots.each_value &:part
      say 'QUIT'
    end

  end


  class ChanMember
    include SimpleIrcBot

    def initialize(channel:, socket:, greeting: true, **opts)
      @channel = channel
      @socket = socket
      @greeting = greeting
      _initialize_chanmember _get_common_irc_opts(**opts)
    end

    # _stub: to make it into keyworded method
    def _initialize_chanmember _stub: nil
    end
    private :_initialize_chanmember

    def greet0
      say_to_chan "#{1.chr}ACTION is here to help#{1.chr}"
    end

    def greet
    end

    def join
      @channel =~ /^#/ and say "JOIN #{@channel}"
      greet0
      return unless @greeting
      greet
    end

    def say_to_chan(*msg)
      say "PRIVMSG #{@channel} :#{msg.join ", "}"
    end

    def react_to nick, content
    end

    def part
      @channel =~ /^#/ and say "PART #{@channel} :Daisy, Daisy, give me your answer do"
    end

  end

end
