SHELL := /usr/bin/env bash

.PHONY: help env lint unit smoke microcode-check

help:
	@echo "Portable CPU targets: env lint unit smoke microcode-check"

env:
	bash scripts/env_check.sh

lint:
	bash scripts/lint.sh

unit:
	bash scripts/test_units.sh

smoke:
	bash scripts/test_iverilog.sh

microcode-check:
	python3 -m tools.microcode.compile_microcode --check
