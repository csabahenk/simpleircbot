require 'socket'


######################################################################################


class SimpleIrcBot

  def self.regexp_join *a
    a.flatten.map{ |e| Regexp.escape e }.join("|")
  end

  def say(msg)
    puts msg
    @socket.puts msg
    nil
  end

  def initialize(server:, port: 6667, nick:, greeting: true)
    @server = server
    @port = port
    @nick = nick
    @greeting = greeting
    @channels = []
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

      earlymatch = true
      case msg
      when /^PING :(.*)$/
        say "PONG #{$1}"
      when /^:#{Regexp.escape @nick}!.* NICK :(.*)$/
        @nick = $1.rstrip
        puts "nick changed to #{@nick}"
      else
        earlymatch = false
      end
      earlymatch and next

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

  def read_msg chan, nick, content
  end

  def part chan
    chan =~ /^#/ and say "PART #{chan} :Daisy, Daisy, give me your answer do"
    @channels.delete chan
  end

end
