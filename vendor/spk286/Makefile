SHELL := /usr/bin/env bash

.PHONY: help env microcode microcode-check microcode-test microcode-audit python-test lint unit smoke test regression synth-check verilator iverilog waveform singlestep-fetch singlestep-smoke singlestep-full

help:
	@echo "SPK286 CPU validation (run from vendor/spk286):"
	@echo "  make microcode-check  verify committed generated microcode"
	@echo "  make python-test      run compiler, reference-model and adapter tests"
	@echo "  make lint             lint portable CPU RTL with Verilator"
	@echo "  make unit             run directed CPU benches in both simulators"
	@echo "  make smoke            run Icarus and Verilator CPU smoke tests"
	@echo "  make test             run microcode, Python, lint, unit and smoke checks"
	@echo "  make regression       run test and Yosys synthesis sanity checks"
	@echo "  make singlestep-fetch fetch the pinned external 80286 capture corpus"
	@echo "  make singlestep-smoke run the immediate MOV capture sample"
	@echo "  make singlestep-full  run the 307 pinned capture families (external corpus)"
	@echo "  SPK286_BUILD_DIR selects the output directory; SPK286_BUILD_JOBS limits builds."
	@echo "  One bench: bash scripts/test_units.sh iverilog spk286_decoder"

env:
	bash scripts/env_check.sh

microcode:
	python3 -m tools.microcode.compile_microcode

microcode-check:
	python3 -m tools.microcode.compile_microcode --check

microcode-test: microcode-check
	python3 -m unittest discover -s tests -p 'test_microcode*.py' -v

microcode-audit: microcode-check
	python3 -m tools.microcode.audit_microcode --output "$${SPK286_BUILD_DIR:-build}/microcode-audit"

python-test: microcode-check
	python3 -m unittest discover -s tests -p 'test_*.py' -v

lint:
	bash scripts/lint.sh

unit:
	bash scripts/test_units.sh

smoke: verilator iverilog

verilator:
	bash scripts/test_verilator.sh

iverilog:
	bash scripts/test_iverilog.sh

test:
	bash scripts/test.sh

regression: test synth-check

synth-check:
	bash scripts/synth_check.sh

waveform:
	bash scripts/test_verilator.sh --trace

singlestep-fetch:
	python3 -m tools.fetch_singlestep

singlestep-smoke:
	bash scripts/build_verilator.sh
	python3 -m tools.run_singlestep --smoke

singlestep-full:
	bash scripts/build_verilator.sh
	python3 -m tools.run_phase7_physical --repo "$${SPK286_SINGLESTEP_ROOT:-.cache/singlestep-80286}" --executable "$${SPK286_BUILD_DIR:-build}/verilator/obj_dir/spk286_smoke" --build-dir "$${SPK286_BUILD_DIR:-build}/singlestep-full"
