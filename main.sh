#!/bin/sh

export RUBYLIB="`dirname "$0"`"

exec $0.rb "$@"
