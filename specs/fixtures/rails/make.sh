#!/bin/sh
# Regenerates campfire.sqlite3 in a throwaway Ruby container (needs docker and network).
set -e
here=$(cd "$(dirname "$0")" && pwd)
docker run --rm -v "$here:/work" -w /work ruby:3.3 sh -c \
  'gem install --no-document activerecord:8.0.2 sqlite3 bcrypt >/dev/null && ruby make.rb /work/campfire.sqlite3 && chown '"$(id -u):$(id -g)"' /work/campfire.sqlite3'
