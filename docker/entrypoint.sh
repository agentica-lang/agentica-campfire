#!/bin/sh
# Maps the environment of the benchmark harness (Rails style) to the CAMPFIRE_* variables, then runs the app.
# A CAMPFIRE_* variable that is already set wins, so `docker run -e` can still change any of them.
set -eu

: "${CAMPFIRE_DATABASE_URL:=sqlite:/rails/storage/db/production.sqlite3}"
: "${CAMPFIRE_STORAGE_DIR:=/rails/storage/files}"
: "${CAMPFIRE_ASSETS_DIR:=/app/public/assets}"
# The app makes its data folder at start; the database folder exists and belongs to the user already.
: "${CAMPFIRE_DATA_DIR:=/rails/storage/db}"
# 127.0.0.1 serves the harness (host network). Use 0.0.0.0 with `-p`.
: "${CAMPFIRE_HOST:=127.0.0.1}"
: "${CAMPFIRE_PORT:=${HTTP_PORT:-3000}}"
# 0 is the size of the database (4 for SQLite); a number must be 3 or more.
: "${CAMPFIRE_DB_POOL_SIZE:=0}"

if [ -z "${CAMPFIRE_SESSION_SECRET:-}" ]; then
  if [ -z "${SECRET_KEY_BASE:-}" ]; then
    echo "campfire: set SECRET_KEY_BASE (or CAMPFIRE_SESSION_SECRET, 32 bytes or more)" >&2
    exit 1
  fi
  # 64 hex digits, the same on every start (a new one signs everybody out), and not the Rails secret itself.
  CAMPFIRE_SESSION_SECRET=$(printf 'campfire-session-secret:%s' "$SECRET_KEY_BASE" | sha256sum | cut -d' ' -f1)
fi

export CAMPFIRE_DATABASE_URL CAMPFIRE_STORAGE_DIR CAMPFIRE_ASSETS_DIR CAMPFIRE_DATA_DIR CAMPFIRE_HOST \
  CAMPFIRE_PORT CAMPFIRE_DB_POOL_SIZE CAMPFIRE_SESSION_SECRET
[ -z "${SECRET_KEY_BASE:-}" ] || export SECRET_KEY_BASE

if [ "$(id -u)" = 0 ]; then
  # A bind mount keeps the owner of the host: the user must write the database and its -wal and -shm files.
  mkdir -p /rails/storage/db
  chown -R campfire /rails/storage/db
  export HOME=/home/campfire
  exec setpriv --reuid=campfire --regid=campfire --init-groups -- "$@"
fi

exec "$@"
