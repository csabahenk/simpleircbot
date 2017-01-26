#!/usr/bin/env ruby

require 'simpleopts'
require 'simpleircbot'


class HelloBot < SimpleIrcBot

  def respond_to chan, nick, cmd, arg
    say_to chan, "Hello, #{nick}!"
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

bot = HelloBot.new **opts
trap("INT"){ bot.quit }
bot.connect
bot.join *channels
bot.run
