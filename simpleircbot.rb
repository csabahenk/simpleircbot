#!/usr/bin/env ruby

require 'socket'
require 'set'

######################################################################################


class SimpleIrcBot

  def self.regexp_join *a
    a.flatten.map{ |e| Regexp.escape e }.join("|")
  end

  def say(msg)
    puts msg
    @socket.puts msg
  end

  def initialize(server:, port: 6667, nick:, greeting: true)
    @server = server
    @port = port
    @nick = nick
    @greeting = greeting
    @channels = Set.new
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

      chans,privs = @channels.partition {|c| c =~ /^#/ }

      #put matchers here
      nick,chan,content = case msg
      when /^:([^!]+)!.*PRIVMSG (#{SimpleIrcBot.regexp_join chans}) :(.*)$/
        [$1,$2,$3]
      when /^:(#{SimpleIrcBot.regexp_join privs})!.*PRIVMSG #{Regexp.escape @nick} :(.*)$/
        [$1,$1,$2]
      end
      chan and read_msg chan,nick,content
    end
  end

  def join *channels
    channels.each { |chan|
      chan =~ /^#/ and say "JOIN #{chan}"
      greet0 chan
      greet chan if @greeting
      @channels << chan
    }
  end

  def quit
    @channels.dup.each { |chan| part chan }
    say 'QUIT'
  end

  def greet0 chan
    say_to chan, "#{1.chr}ACTION is here to help#{1.chr}"
  end

  def greet chan
  end

  def say_to chan, *msg
    say "PRIVMSG #{chan} :#{msg.join ", "}"
  end

  def respond_to chan, nick, cmd, arg
    :pass
  end

  def react_to chan, nick, content
  end

  def read_msg chan, nick, content
    if content =~ /\A\s*#{Regexp.escape @nick}[:,\s]\s*(\S+)\s*(.*)/i
      cmd,arg = $1.downcase,$2.strip
      new_content = respond_to(chan, nick, cmd, arg)
      case new_content
      when :pass,true
      when String
        content = new_content
      when nil,false
        return
      else
        raise ArgumentError, "bad content"
      end
    end
    react_to chan,nick,content
  end

  def part chan
    chan =~ /^#/ and say "PART #{chan} :Daisy, Daisy, give me your answer do"
    @channels.delete chan
  end

end
