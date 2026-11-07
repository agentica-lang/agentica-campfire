# The image of the Campfire benchmark (basecamp/once-campfire-verification): plain HTTP, the Rails-style
# environment and the /rails/storage volumes mapped by docker/entrypoint.sh. Build: docker build -t
# once-campfire-agentica:app .

# Stage 1 holds the tools that must not reach the image: curl and git (`agentica install` fetches with git) and the C
# compiler that builds the native SQLite driver of agentica-db.
FROM debian:13-slim AS build

# Change the version and the sha256 together, and the same pair in .github/workflows/ci.yml. The image is x86_64
# only (the release archive of linux-x86_64).
ARG AGENTICA_VERSION=0.26.1
# From the SHA256SUMS of the release.
ARG AGENTICA_SHA256=68c3e825cb14148e45c47b21b6ef66036c5ad17a2cdf36948f47e1415bae5524

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git gcc libc6-dev \
 && rm -rf /var/lib/apt/lists/*

RUN archive="agentica-${AGENTICA_VERSION}-linux-x86_64.tar.gz" \
 && curl -fsSL -o "/tmp/$archive" \
      "https://github.com/agentica-lang/agentica/releases/download/${AGENTICA_VERSION}/$archive" \
 && echo "${AGENTICA_SHA256}  /tmp/$archive" | sha256sum -c - \
 && mkdir /opt/agentica \
 && tar -xzf "/tmp/$archive" -C /opt/agentica --strip-components=1

# The package cache, in a fixed folder (not under $HOME) so that stage 2 finds the native library at the same absolute
# path, whichever user runs the app.
ENV XDG_CACHE_HOME=/opt/agentica-cache

WORKDIR /app
COPY agentica.toml agentica.lock ./
# The packages of the lock go to deps/, checked against the hashes of the lock; nothing is fetched at run time.
RUN /opt/agentica/bin/agentica install

COPY campfire.agc ./
COPY src ./src
# Compiling a program that imports pkg/db/db builds the native SQLite driver (libdb_sqlite.so, from the C source of
# agentica-db) into the package cache, and the bytecode stores the absolute path of the library. The build fails if the
# library is not there: at run time a missing one would quietly leave the slower FFI driver. The app runs from this
# bytecode, not from source: a run from source computes the cache key with the C compiler, which stage 2 does not have.
# The grep proves that the path stored in the bytecode is the path that stage 2 copies the library to (same
# XDG_CACHE_HOME). The folders of the cache are made for root alone; the app runs as `campfire`.
RUN /opt/agentica/bin/agentica compile campfire.agc -o campfire.agcb \
 && test "$(find "$XDG_CACHE_HOME/agentica/pkg/native-build" -name libdb_sqlite.so | wc -l)" = 1 \
 && grep -aq "$XDG_CACHE_HOME/agentica/pkg/native-build/.*/libdb_sqlite.so" campfire.agcb \
 && chmod -R a+rX "$XDG_CACHE_HOME/agentica/pkg/native-build"
# The built stylesheet and script are committed (`make assets`), so this image needs no Node.
COPY public ./public
# A compressed copy next to each stylesheet and script: Bond sends it to a client that takes gzip (and does not
# compress at run time). `-n` keeps the name and time out of the file so the build is the same each time, and `-k`
# keeps the original, which a client that does not take gzip gets. `gzip` keeps the time of change of the original, and
# Bond ignores a `.gz` that is older.
RUN find public/assets -type f \( -name '*.css' -o -name '*.js' \) -exec gzip -9 -k -n {} +

# Stage 2: the binary, the app and the native SQLite driver built in stage 1 (no compiler here). libsqlite3 is the
# database (the native driver and agentica-db open the system one) and libcrypt1 (already in the base) checks the bcrypt
# digests of a Rails Campfire.
FROM debian:13-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends libsqlite3-0 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 1000 --create-home --shell /usr/sbin/nologin campfire \
 && mkdir -p /rails/storage/db /rails/storage/files /rails/storage/logs \
 && chown -R campfire:campfire /rails/storage

COPY --from=build /opt/agentica/bin/agentica /usr/local/bin/agentica
COPY --from=build /app /app
# Only the native libraries of the package cache, at the path that the program looks them up in. `native` makes a
# missing library an error of `open` instead of a quiet fall back to the FFI driver.
COPY --from=build /opt/agentica-cache/agentica/pkg/native-build /opt/agentica-cache/agentica/pkg/native-build
# XDG_CACHE_HOME must equal the value of stage 1: the bytecode holds the absolute path of the library.
ENV XDG_CACHE_HOME=/opt/agentica-cache AGENTICA_DB_SQLITE_DRIVER=native
COPY docker/entrypoint.sh /usr/local/bin/campfire-entrypoint

WORKDIR /app
ENV HOME=/home/campfire
EXPOSE 3000

# The entrypoint starts as root only to hand /rails/storage/db to the user (a bind mount keeps the owner of the
# host), then runs the app as `campfire`. With `--user` it runs as that user as it is. The app is PID 1: run with
# `--init` for a clean stop on SIGTERM.
ENTRYPOINT ["campfire-entrypoint"]
CMD ["agentica", "run", "--", "campfire.agcb"]
