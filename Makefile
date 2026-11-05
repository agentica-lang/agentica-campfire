# Needs Agentica 0.24.3 or later on PATH (`agentica test --jobs` is new in 0.24.1, `std/cache` in 0.24.3).
# AGENTICA=/path/to/agentica works for the targets, but the mail specs start their SMTP peer with the `agentica` on
# PATH.
AGENTICA ?= agentica
# How many test files run at once (`make test JOBS=1` runs them one by one).
JOBS ?= 4

.PHONY: help install run check fmt-check test

help:
	@echo "install    fetch the packages of agentica.lock into deps/"
	@echo "run        start the app; CAMPFIRE_SESSION_SECRET is required (32 bytes or more, openssl rand -hex 32),"
	@echo "           CAMPFIRE_SECURE_COOKIES=true behind HTTPS (CAMPFIRE_HOST, CAMPFIRE_PORT: 127.0.0.1 and"
	@echo "           3000 by default;"
	@echo "           CAMPFIRE_DATA_DIR, CAMPFIRE_DATABASE_URL: ./data and a SQLite file in it;"
	@echo "           CAMPFIRE_DB_POOL_SIZE, CAMPFIRE_DB_CHECKOUT_MS: 0 (the size of the database, 4 for SQLite; else 3 or more) and 3000;"
	@echo "           CAMPFIRE_CACHE_MB: the cache of rendered messages, 64 by default, 0 for none;"
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
