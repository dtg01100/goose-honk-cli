SHELL := /bin/bash
SHELLCHECK ?= shellcheck

.PHONY: all check lint syntax test doctor install uninstall

all: check test

syntax:
	bash -n honk install.sh lib/*.sh tests/*.sh tools/*.sh

lint:
	$(SHELLCHECK) -s bash -x honk install.sh lib/*.sh tests/*.sh tools/*.sh

check: syntax lint

doctor:
	@bash ./tools/doctor.sh

test:
	./tests/smoke.sh

install:
	./install.sh

uninstall:
	@bash ./tools/uninstall.sh
