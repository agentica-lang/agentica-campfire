# Needs Agentica 0.23.0 or later on PATH (or AGENTICA=/path/to/agentica).
AGENTICA ?= agentica

.PHONY: help install run check fmt-check test

help:
	@echo "install    fetch the packages of agentica.lock into deps/"
	@echo "run        start the app (CAMPFIRE_HOST, CAMPFIRE_PORT: 127.0.0.1 and 3000 by default;"
	@echo "           CAMPFIRE_DATA_DIR, CAMPFIRE_DATABASE_URL: ./data and a SQLite file in it)"
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
