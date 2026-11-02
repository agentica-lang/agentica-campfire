# Needs Agentica 0.22.0 or later on PATH (or AGENTICA=/path/to/agentica).
AGENTICA ?= agentica

.PHONY: help install run check test

help:
	@echo "install  fetch the packages of agentica.lock into deps/"
	@echo "run      start the app (CAMPFIRE_HOST, CAMPFIRE_PORT: 127.0.0.1 and 3000 by default)"
	@echo "check    type-check every .agc file"
	@echo "test     run the features of specs/ and the tests of test/"

install:
	$(AGENTICA) install

run:
	$(AGENTICA) campfire.agc

check:
	$(AGENTICA) check

test:
	$(AGENTICA) test
