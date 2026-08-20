SHELL := /bin/bash
SHELLCHECK ?= shellcheck

.PHONY: all check lint syntax test

all: check test

syntax:
	bash -n honk install.sh lib/*.sh tests/*.sh

lint:
	$(SHELLCHECK) -s bash -x honk install.sh lib/*.sh tests/*.sh

check: syntax lint

test:
	./tests/smoke.sh
