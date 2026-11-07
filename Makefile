# Needs Agentica 0.26.1 or later on PATH (`agentica test --jobs` is new in 0.24.1, `std/cache` in 0.24.3, bond-channels
# wants 0.24.4, `T.codec` and Bond 0.9.0 want 0.25.0, and the native SQLite driver of agentica-db 0.6.0 wants 0.26.1) and
# a C compiler: the first run of a program that imports agentica-db builds that driver into the package cache.
# AGENTICA=/path/to/agentica works for the targets, but the mail specs start their SMTP peer with the `agentica` on
# PATH.
AGENTICA ?= agentica
# How many test files run at once (`make test JOBS=1` runs them one by one).
JOBS ?= 4

.PHONY: help install run check fmt-check test assets assets-check

help:
	@echo "install    fetch the packages of agentica.lock into deps/"
	@echo "run        start the app; CAMPFIRE_SESSION_SECRET is required (32 bytes or more, openssl rand -hex 32),"
	@echo "           CAMPFIRE_SECURE_COOKIES=true behind HTTPS (CAMPFIRE_HOST, CAMPFIRE_PORT: 127.0.0.1 and"
	@echo "           3000 by default;"
	@echo "           CAMPFIRE_DATA_DIR, CAMPFIRE_DATABASE_URL: ./data and a SQLite file in it;"
	@echo "           CAMPFIRE_DB_POOL_SIZE, CAMPFIRE_DB_CHECKOUT_MS: 0 (the size of the database, 4 for SQLite; else 3 or more) and 3000;"
	@echo "           CAMPFIRE_CACHE_MB: the cache of rendered messages, 64 by default, 0 for none;"
	@echo "           CAMPFIRE_RESPONSE_CACHE_MB: the cache of whole room pages, 64 by default, 0 for none;"
	@echo "           CAMPFIRE_SEARCH_PAGES: the search pages that a person keeps in it, 8 by default (1 to 64);"
	@echo "           CAMPFIRE_CURSOR_PAGES: the older-message pages (before=, after=) that a person keeps of each, 16 by default (1 to 64);"
	@echo "           CAMPFIRE_SESSION_CACHE_MB: the store of the people of the sessions, 4 by default (1 to 1024);"
	@echo "           CAMPFIRE_MAX_MESSAGE_LENGTH: the most characters of a message, 10000 by default (1 to 80000);"
	@echo "           CAMPFIRE_MAX_CONNECTIONS: the connections the server holds, the /cable WebSockets among them, 4096 by default;"
	@echo "           CAMPFIRE_BCRYPT_LIBRARY: a libxcrypt (path or name) for bcrypt digests; libcrypt.so.1 on Linux by default;"
	@echo "           SECRET_KEY_BASE: the secret of a Rails Campfire, which checks avatar links (unset: they are 404);"
	@echo "           CAMPFIRE_STORAGE_DIR: the Active Storage files, DATA_DIR/files by default;"
	@echo "           CAMPFIRE_ASSETS_DIR: the folder served under /assets/, public/assets by default;"
	@echo "           CAMPFIRE_SMTP_URL: smtp://user:password@host:587, smtps:// or smtp+plain:// (localhost only),"
	@echo "           which needs CAMPFIRE_BASE_URL=https://campfire.example.com; CAMPFIRE_SMTP_FROM,"
	@echo "           CAMPFIRE_SMTP_HOSTNAME, CAMPFIRE_MAIL_QUEUE_SIZE)"
	@echo "check      type-check every .agc file"
	@echo "fmt-check  fail when a file is not formatted (agentica fmt)"
	@echo "test       run the features of specs/ and the tests of test/ (JOBS=4 files at once)"
	@echo "assets     build public/assets/ (Dart Sass and esbuild, fingerprinted) from app/; needs Node 20+ and npm ci"
	@echo "assets-check  build them and fail if that changed a committed file (what CI runs)"

install:
	$(AGENTICA) install

run:
	$(AGENTICA) campfire.agc

check:
	$(AGENTICA) check

fmt-check:
	$(AGENTICA) fmt --check campfire.agc src specs test

test:
	$(AGENTICA) test --jobs $(JOBS)

# The stylesheet and the script, built from app/ into public/assets/ and named by their digest; the names go to
# src/campfire_web/asset_names.agc. The output is committed: CI runs this and fails if it changes anything.
assets:
	node tools/assets.mjs

# The test of CI: the committed build is the build of the sources (and no file of an older build is left).
assets-check: assets
	@changed="$$(git status --porcelain -- public/assets src/campfire_web/asset_names.agc)"; \
	if [ -n "$$changed" ]; then \
	  echo "make assets changed the built files; commit them:" >&2; echo "$$changed" >&2; exit 1; \
	fi
