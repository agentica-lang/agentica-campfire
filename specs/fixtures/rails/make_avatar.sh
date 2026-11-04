#!/bin/sh
# Regenerates avatar.sql and storage/ in a throwaway Ruby container (needs docker and network).
set -e
here=$(cd "$(dirname "$0")" && pwd)
docker run --rm -v "$here:/work" -w /work ruby:3.3 sh -c \
  'apt-get update >/dev/null && apt-get install -y --no-install-recommends libvips42 >/dev/null &&
   gem install --no-document rails:8.0.2 image_processing ruby-vips sqlite3 >/dev/null &&
   STORAGE_ROOT=$(mktemp -d) ruby make_avatar.rb /work && chown -R '"$(id -u):$(id -g)"' /work/avatar.sql /work/storage'
