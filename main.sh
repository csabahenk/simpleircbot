#!/bin/sh

# using realpath(1) would be simpler, but alas, that's
# Linux specific
realpath="`ls -l "$0" | sed 's/.* -> *//'`"
export RUBYLIB="`dirname "$0"`/`dirname "$realpath"`"

exec "$0".rb "$@"
