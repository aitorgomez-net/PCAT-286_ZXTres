#!/usr/bin/env python3
"""Reject six coherence mutants using the independent multiline model bench.

Only temporary model copies and logs under the build directory are written.
Compile errors and timeouts are audit failures, never successful mutant kills.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess


MUTANTS = [
    ("unaligned_upper_lane", "second_byte = {address[24:1], 1'b1};",
     "second_byte = address + 25'd1;",
     "fetch hit/miss mismatch at 0003006 expected_hit=0"),
    ("cancel_idle_keeps_lines", "if (cancel_cpu) begin",
     "if (cancel_cpu && state_q != STATE_IDLE) begin",
     "fetch hit/miss mismatch at 0010004 expected_hit=0"),
    ("live_word_index", "request_word_index = request_address_q[2:1];",
     "request_word_index = in_address[2:1];",
     "logical data mismatch got=b0b1 expected=b6b7"),
    ("missing_hit_penalty", "hit_wait_q <= (code_hit_extra != 0);",
     "hit_wait_q <= 1'b0;",
     "hit latency differs from configured lookup penalty"),
    ("wrong_lru_hit_update", "lru_way_q[input_set] <= (hit_slot == input_first_slot);",
     "lru_way_q[input_set] <= (hit_slot != input_first_slot);",
     "fetch hit/miss mismatch at 0002002 expected_hit=1"),
    ("cancel_drops_accepted_beats", "(out_ready && out_read_data_valid)",
     "(out_read_data_valid)", "physical owner released before completion"),
]

PRODUCTION_MUTANTS = [
    ("odd_upper_write_keeps_line",
     "wire input_write_hit = in_write && (|in_byte_enable) && input_tag_hit;\n"
     "    wire request_write_hit = request_write_q && (|request_byte_enable_q) && request_tag_hit;",
     "wire input_write_hit = in_write && (|in_byte_enable) && input_tag_hit &&\n"
     "        !(in_address[2:0] == 3'b111 && in_byte_enable == 2'b10);\n"
     "    wire request_write_hit = request_write_q && (|request_byte_enable_q) && request_tag_hit &&\n"
     "        !(request_address_q[2:0] == 3'b111 && request_byte_enable_q == 2'b10);",
     "fetch hit/miss mismatch at 0003006 expected_hit=0"),
    ("cancel_idle_keeps_lines", "if (cancel_cpu) begin",
     "if (cancel_cpu && state_q != STATE_IDLE) begin",
     "fetch hit/miss mismatch at 0010004 expected_hit=0"),
    ("live_word_index", "request_word_index = request_address_q[2:1];",
     "request_word_index = in_address[2:1];",
     "logical data mismatch got=b0b1 expected=b6b7"),
    ("bram_hit_wrong_word", "DATA_ADDRESS_BITS'({input_index, in_address[2:1]})",
     "DATA_ADDRESS_BITS'({input_index, 2'b00})",
     "logical data mismatch got=b6b7 expected=b4b5"),
    ("tag_drops_physical_bit24", "line_tag_q[input_index] == in_address[24:TAG_LOW]",
     "line_tag_q[input_index][23:TAG_LOW] == in_address[23:TAG_LOW]",
     "logical data mismatch got=a6a7 expected=a7a6"),
    ("cancel_drops_accepted_beats", "(out_ready && out_read_data_valid)",
     "(out_read_data_valid)", "physical owner released before completion"),
]


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path,
                        default=root / "build/at-multiline-code-buffer/mutants")
    parser.add_argument("--timeout", type=float, default=15)
    parser.add_argument("--production", action="store_true",
                        help="Audit the synthesizable 64-line direct-mapped buffer")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    work = args.build_dir.resolve()
    work.mkdir(parents=True, exist_ok=True)
    model = root / "sim/spk286_integration/spk286_at_multiline_code_buffer_model.sv"
    if args.production:
        model = root / "rtl/spk286_integration/spk286_at_sdram_read_buffer.sv"
    bench = root / "sim/spk286_integration/spk286_at_multiline_code_buffer_tb.sv"
    source = model.read_text()

    def artifact(path: Path) -> dict:
        try:
            name = path.relative_to(root).as_posix()
        except ValueError:
            name = str(path)
        return {"path": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}

    source_receipts = [artifact(path) for path in (model, bench, Path(__file__).resolve())]
    compile_flags = ["-DPCAT_PRODUCTION_CODE_BUFFER"] if args.production else []
    run_flags = [] if args.production else ["+CODE_LINES=4", "+CODE_WAYS=2", "+CODE_HIT_EXTRA=1"]
    configuration = (dict(ENABLE=1, CODE_LINES=64, CODE_WAYS=1, CODE_HIT_EXTRA=0)
                     if args.production else dict(ENABLE=1, CODE_LINES=4, CODE_WAYS=2, CODE_HIT_EXTRA=1))

    def simulate(name: str, source_path: Path) -> tuple[int, str, dict, dict]:
        binary = work / (name + ".vvp")
        compilation = subprocess.run(
            ["iverilog", "-g2012", "-s", "spk286_at_multiline_code_buffer_tb",
             *compile_flags, "-o", str(binary), str(source_path), str(bench)],
            capture_output=True, text=True, timeout=args.timeout)
        compile_log = work / (name + ".compile.log")
        compile_log.write_text(compilation.stdout + compilation.stderr)
        if compilation.returncode != 0:
            raise RuntimeError(f"{name}: compilation failed; see {compile_log}")
        run = subprocess.run(
            ["vvp", str(binary), *run_flags],
            capture_output=True, text=True, timeout=args.timeout)
        output = run.stdout + run.stderr
        log = work / (name + ".log")
        log.write_text(output)
        return run.returncode, output, artifact(log), artifact(compile_log)

    pristine_code, pristine_output, pristine_log, pristine_compile = simulate("pristine", model)
    pass_prefix = ("MULTILINE_COHERENCE_PASS lines=64 ways=1 extra=0 ENABLE=1 " if args.production
                   else "MULTILINE_COHERENCE_PASS lines=4 ways=2 extra=1 ENABLE=1 ")
    pristine_pass = next((line for line in pristine_output.splitlines() if line.startswith(pass_prefix)), None)
    if pristine_code != 0 or not pristine_pass:
        raise RuntimeError(f"Pristine model failed; see {pristine_log['path']}")
    results = []
    for name, old, new, expected_failure in (PRODUCTION_MUTANTS if args.production else MUTANTS):
        if source.count(old) != 1:
            raise RuntimeError(f"{name}: expected exactly one mutation anchor, found {source.count(old)}")
        mutant = work / (name + ".sv")
        mutant.write_text(source.replace(old, new))
        code, output, log, compile_log = simulate(name, mutant)
        failure = next((line for line in output.splitlines() if line.startswith("MULTILINE_FAIL")), None)
        if code == 0 or failure is None or not failure.endswith(expected_failure):
            raise RuntimeError(f"{name}: expected assertion did not reject mutant; see {log['path']}")
        results.append({"mutant": name, "rejected": True, "old": old, "new": new,
                        "expected_assertion": expected_failure, "observed_failure": failure,
                        "source": artifact(mutant), "log": log, "compile_log": compile_log})
        print(f"{name}: {failure}")
    if source_receipts != [artifact(path) for path in (model, bench, Path(__file__).resolve())]:
        raise RuntimeError("Audit source files changed during execution")
    receipt = {"sources": source_receipts, "simulator": "Icarus Verilog",
               "production": args.production, "configuration": configuration,
               "pristine": {"passed": True, "result": pristine_pass,
                            "log": pristine_log, "compile_log": pristine_compile},
               "mutants": results}
    (work / "results.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"MULTILINE_MUTATION_AUDIT_PASS pristine=1 mutants={len(results)}")


if __name__ == "__main__":
    main()
