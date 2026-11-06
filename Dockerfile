# The image of the Campfire benchmark (basecamp/once-campfire-verification): plain HTTP, the Rails-style
# environment and the /rails/storage volumes mapped by docker/entrypoint.sh. Build: docker build -t
# once-campfire-agentica:app .

# Stage 1 holds the tools that must not reach the image: curl and git (`agentica install` fetches with git).
FROM debian:13-slim AS build

# Change the version and the sha256 together, and the same pair in .github/workflows/ci.yml. The image is x86_64
# only (the release archive of linux-x86_64).
ARG AGENTICA_VERSION=0.25.0
# From the SHA256SUMS of the release.
ARG AGENTICA_SHA256=4ecf226a4a8c1ac2573bfe23674c387a40b0cc69f97ecbf408d9a7888ec9da3d

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git \
 && rm -rf /var/lib/apt/lists/*

RUN archive="agentica-${AGENTICA_VERSION}-linux-x86_64.tar.gz" \
 && curl -fsSL -o "/tmp/$archive" \
      "https://github.com/agentica-lang/agentica/releases/download/${AGENTICA_VERSION}/$archive" \
 && echo "${AGENTICA_SHA256}  /tmp/$archive" | sha256sum -c - \
 && mkdir /opt/agentica \
 && tar -xzf "/tmp/$archive" -C /opt/agentica --strip-components=1

WORKDIR /app
COPY agentica.toml agentica.lock ./
# The packages of the lock go to deps/, checked against the hashes of the lock; nothing is fetched at run time.
RUN /opt/agentica/bin/agentica install

COPY campfire.agc ./
COPY src ./src
# The built stylesheet and script are committed (`make assets`), so this image needs no Node.
COPY public ./public
# A compressed copy next to each stylesheet and script: Bond sends it to a client that takes gzip (and does not
# compress at run time). `-n` keeps the name and time out of the file so the build is the same each time, and `-k`
# keeps the original, which a client that does not take gzip gets. `gzip` keeps the time of change of the original, and
# Bond ignores a `.gz` that is older.
RUN find public/assets -type f \( -name '*.css' -o -name '*.js' \) -exec gzip -9 -k -n {} +

# Stage 2: the binary and the app. libsqlite3 is the database (agentica-db opens the system one) and libcrypt1
# (already in the base) checks the bcrypt digests of a Rails Campfire.
FROM debian:13-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends libsqlite3-0 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 1000 --create-home --shell /usr/sbin/nologin campfire \
 && mkdir -p /rails/storage/db /rails/storage/files /rails/storage/logs \
 && chown -R campfire:campfire /rails/storage

COPY --from=build /opt/agentica/bin/agentica /usr/local/bin/agentica
COPY --from=build /app /app
COPY docker/entrypoint.sh /usr/local/bin/campfire-entrypoint

WORKDIR /app
ENV HOME=/home/campfire
EXPOSE 3000

# The entrypoint starts as root only to hand /rails/storage/db to the user (a bind mount keeps the owner of the
# host), then runs the app as `campfire`. With `--user` it runs as that user as it is. The app is PID 1: run with
# `--init` for a clean stop on SIGTERM.
ENTRYPOINT ["campfire-entrypoint"]
CMD ["agentica", "campfire.agc"]
