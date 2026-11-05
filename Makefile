# Needs Agentica 0.24.1 or later on PATH (`agentica test --jobs` is new in 0.24.1). AGENTICA=/path/to/agentica works
# for the targets, but the mail specs start their SMTP peer with the `agentica` on PATH.
AGENTICA ?= agentica
# How many test files run at once (`make test JOBS=1` runs them one by one).
JOBS ?= 4
CC ?= cc
CFLAGS ?= -O2

# The C library of packages/html_escape, which its agentica.toml names for the running system. It is built here, not
# committed: every target that compiles the app needs it, so they depend on the file.
HTML_ESCAPE = packages/html_escape
ifeq ($(shell uname -s),Darwin)
HTML_ESCAPE_LIB = $(HTML_ESCAPE)/native/libhtml_escape.dylib
HTML_ESCAPE_LDFLAGS = -dynamiclib
else
HTML_ESCAPE_LIB = $(HTML_ESCAPE)/native/libhtml_escape.so
HTML_ESCAPE_LDFLAGS = -shared -pthread
endif

.PHONY: help install native run check fmt-check test

help:
	@echo "install    fetch the packages of agentica.lock into deps/"
	@echo "native     build the C library of packages/html_escape (run, check and test build it when it is missing)"
	@echo "run        start the app; CAMPFIRE_SESSION_SECRET is required (32 bytes or more, openssl rand -hex 32),"
	@echo "           CAMPFIRE_SECURE_COOKIES=true behind HTTPS (CAMPFIRE_HOST, CAMPFIRE_PORT: 127.0.0.1 and"
	@echo "           3000 by default;"
	@echo "           CAMPFIRE_DATA_DIR, CAMPFIRE_DATABASE_URL: ./data and a SQLite file in it;"
	@echo "           CAMPFIRE_DB_POOL_SIZE, CAMPFIRE_DB_CHECKOUT_MS: 0 (the size of the database, 4 for SQLite; else 3 or more) and 3000;"
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

native: $(HTML_ESCAPE_LIB)

$(HTML_ESCAPE_LIB): $(HTML_ESCAPE)/c/html_escape.c
	mkdir -p $(dir $@)
	$(CC) -std=c11 $(CFLAGS) -Wall -Wextra -Werror -pedantic -fPIC $(HTML_ESCAPE_LDFLAGS) -o $@ $<

run: $(HTML_ESCAPE_LIB)
	$(AGENTICA) campfire.agc

check: $(HTML_ESCAPE_LIB)
	$(AGENTICA) check

fmt-check:
	$(AGENTICA) fmt --check campfire.agc src specs test $(HTML_ESCAPE)

test: $(HTML_ESCAPE_LIB)
	$(AGENTICA) test --jobs $(JOBS)
