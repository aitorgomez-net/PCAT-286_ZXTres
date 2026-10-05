#!/usr/bin/env bash
# Compile once, then execute only the portable diagnostic (not a regression).
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/pm-diag-validation/rtl
source scripts/rtl_sources.sh
verilator --lint-only --timing -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-TIMESCALEMOD -I./sim/unit --top-module pm_diag_tb \
    "${rtl_sources[@]}" research/pm_diag/pm_diag_tb.sv \
    > build/pm-diag-validation/rtl/lint.log 2>&1
iverilog -g2012 -I sim/unit -s pm_diag_tb \
    -o build/pm-diag-validation/rtl/pm_diag.vvp \
    "${rtl_sources[@]}" research/pm_diag/pm_diag_tb.sv \
    > build/pm-diag-validation/rtl/compile.log 2>&1
vvp build/pm-diag-validation/rtl/pm_diag.vvp \
    +IMAGE="${1:-build/pm-diag/PM286.BIN}" \
    +SCREEN=build/pm-diag-validation/rtl/screen.txt \
    | tee build/pm-diag-validation/rtl/run.log
# Reaching HLT is a harness check, not a CPU PASS. Known diagnostic failures
# deliberately leave this command nonzero and must be classified from the log.
grep -q '^COMPLETE failures=0000' build/pm-diag-validation/rtl/run.log
