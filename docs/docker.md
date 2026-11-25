# Docker

The image has the pinned Agentica release, the app compiled to bytecode and its packages (no network at run time) on
Debian 13 slim, and a `.gz` copy next to each stylesheet and script, which Bond sends to a client
that takes gzip. The image is x86_64 only.

It runs the native SQLite driver of agentica-db. The build stage has a C compiler; `agentica compile` builds the
driver into the package cache (`/opt/agentica-cache`, `XDG_CACHE_HOME`) and stores the absolute path of the library in
`campfire.agcb`, and the build fails if the library is missing. The final image has no compiler: it gets the library at
the same path, and runs the bytecode (`agentica run -- campfire.agcb`). Running from source (`agentica campfire.agc`) in
the image fails with PKG-NATIVE-BUILD, since it has no compiler.
`AGENTICA_DB_SQLITE_DRIVER=native` makes a missing library stop the start instead of a quiet fall back to the FFI driver.

## Build and run

```sh
docker build -t once-campfire-agentica:app .
docker run --rm --init -p 3000:3000 -e CAMPFIRE_HOST=0.0.0.0 -e CAMPFIRE_PORT=3000 \
  -e SECRET_KEY_BASE=$(openssl rand -hex 64) -v "$PWD/storage:/rails/storage" once-campfire-agentica:app
```

## Compose

Compose keeps the data in the `campfire-storage` volume and publishes the port on `127.0.0.1` only:

```sh
[ -f .env ] || echo "SECRET_KEY_BASE=$(openssl rand -hex 64)" > .env
docker compose up -d --build
```

Local settings, such as a network or `CAMPFIRE_BASE_URL`, go in `docker-compose.override.yml`, which
Compose reads on its own. Compose adds an override's `ports` to the base list, so use
`ports: !override [...]` there to change the published address. Git ignores that file and `.env`.

## Environment

`docker/entrypoint.sh` maps the environment of the
[Rails benchmark harness](https://github.com/basecamp/once-campfire-verification) to `CAMPFIRE_*`:

- the database is `/rails/storage/db/production.sqlite3`;
- the Active Storage files are in `/rails/storage/files`;
- `HTTP_PORT` is the port;
- the session secret comes from `SECRET_KEY_BASE`.

To keep the files in an S3 bucket instead (rustfs, MinIO, AWS S3), set `CAMPFIRE_STORAGE_SERVICE=s3` and the
`CAMPFIRE_S3_*` variables of [configuration.md](configuration.md); the browsers must reach the endpoint, and the bucket
must answer a cross-origin `PUT` (CORS) from the address of the app.

The image sets `GC_INITIAL_HEAP_SIZE=33554432` (a 32 MB start heap for the garbage collector,
which cuts its pauses under load); `-e GC_INITIAL_HEAP_SIZE=...` overrides it.

A `CAMPFIRE_*` variable that you set wins. The app listens on `127.0.0.1` unless `CAMPFIRE_HOST`
says otherwise. In the benchmark harness, `bin/seed` writes `SECRET_KEY_BASE`. For the harness
itself, see [bench/README.md](../bench/README.md). The other variables are in
[configuration.md](configuration.md).
