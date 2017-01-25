#!/usr/bin/env ruby

require 'simpleopts'
require 'simpleircbot'


class HelloMember < SimpleIrcBot::ChanMember

  def respond_to nick, cmd, arg
    say_to_chan "Hello, #{nick}!"
  end

end


OPTS = {
  nick: String,
  server: String,
  port: 6667,
  channels: [],
}

opts = SimpleOpts.get **OPTS
channels = opts.delete :channels

bot = SimpleIrcBot::Bot.new memberclass: HelloMember, **opts
trap("INT"){ bot.quit }
bot.connect
bot.join *channels
bot.run
