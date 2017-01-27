#!/usr/bin/env ruby

require 'simpleopts'
require 'simpleircbot/core'
require 'simpleircbot/plugins'


class HelloBot < SimpleIrcBot
  include SimpleIrcBot::Plugins::Commands
  include SimpleIrcBot::Plugins::Admin

  def command_hello chan, nick, arg
    say_to chan, "Hello, #{nick}" + (arg ? ", #{arg}" : "!")
  end

  def help chan
    yield :cmd, "hello", "[<greeting>] -- helloes back"
    super
  end

end


OPTS = {
  nick: String,
  server: String,
  port: 6667,
  channels: [],
  admins: [],
}

opts = SimpleOpts.get **OPTS
channels = opts.delete :channels

bot = HelloBot.new **opts
trap("INT"){ bot.quit }
bot.connect
bot.join *channels
bot.run
