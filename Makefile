# Needs Agentica 0.23.0 or later on PATH (or AGENTICA=/path/to/agentica).
AGENTICA ?= agentica

.PHONY: help install run check fmt-check test

help:
	@echo "install    fetch the packages of agentica.lock into deps/"
	@echo "run        start the app; CAMPFIRE_SESSION_SECRET is required (32 bytes or more, openssl rand -hex 32),"
	@echo "           CAMPFIRE_SECURE_COOKIES=true behind HTTPS (CAMPFIRE_HOST, CAMPFIRE_PORT: 127.0.0.1 and"
	@echo "           3000 by default;"
	@echo "           CAMPFIRE_DATA_DIR, CAMPFIRE_DATABASE_URL: ./data and a SQLite file in it;"
	@echo "           CAMPFIRE_DB_POOL_SIZE, CAMPFIRE_DB_CHECKOUT_MS: 0 (the database's size, 4 for SQLite) and 3000;"
	@echo "           CAMPFIRE_SMTP_URL: smtp://user:password@host:587, smtps:// or smtp+plain:// (localhost only),"
	@echo "           which needs CAMPFIRE_BASE_URL=https://campfire.example.com; CAMPFIRE_SMTP_FROM,"
	@echo "           CAMPFIRE_SMTP_HOSTNAME, CAMPFIRE_MAIL_QUEUE_SIZE)"
	@echo "check      type-check every .agc file"
	@echo "fmt-check  fail when a file is not formatted (agentica fmt)"
	@echo "test       run the features of specs/ and the tests of test/"

install:
	$(AGENTICA) install

run:
	$(AGENTICA) campfire.agc

check:
	$(AGENTICA) check

fmt-check:
	$(AGENTICA) fmt --check campfire.agc src specs test

test:
	$(AGENTICA) test
