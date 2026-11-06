# Docker

The image has the pinned Agentica release, the app and its packages (no network at run time) on
Debian 13 slim, and a `.gz` copy next to each stylesheet and script, which Bond sends to a client
that takes gzip. The image is x86_64 only.

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

A `CAMPFIRE_*` variable that you set wins. The app listens on `127.0.0.1` unless `CAMPFIRE_HOST`
says otherwise. In the benchmark harness, `bin/seed` writes `SECRET_KEY_BASE`. For the harness
itself, see [bench/README.md](../bench/README.md). The other variables are in
[configuration.md](configuration.md).
