#!/usr/bin/env python3
"""Directed full-CPU compatibility of the provisional production speed profiles.

Original architectural assertions are preserved in build-only fixture copies.
Historical profiles get a larger fabric-edge watchdog and one explicitly
declared early code installation in protected_system, avoiding a fixture
self-modification after the tested byte was already prefetched. Fixed delays,
register/FLAGS/memory expectations and event counts are unchanged.
This is functional compatibility, not complete historical/pin timing evidence.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading

from build_p06_profile_cpu import build


ROOT = Path(__file__).resolve().parents[1]
CPU = ROOT / "vendor/spk286"
UNITS = [
    "execution", "microcode_execution", "alu_lifecycle", "data_lifecycle",
    "unary_lifecycle", "prefix", "event_lifecycle", "string_zero_events",
    "string_io_zero_events", "string_io_lifecycle", "scalar_io", "xchg_hold_lock",
    "loadall_integration", "protected_entry", "protected_system", "protected_event_outer",
    "odd_protected_stack", "protected_task", "protected_task_iret",
    "protected_task_state_fault", "protected_task_privilege_outer", "protected_retf",
    "iopl_access", "stack_frame_lifecycle", "far_lifecycle", "muldiv_lifecycle",
]
DUAL = ["execution", "event_lifecycle", "string_io_zero_events", "xchg_hold_lock",
        "loadall_integration", "protected_task", "odd_protected_stack"]
PROFILE_NAMES = ["MAX", "6", "8", "10", "12.5", "16", "20", "25"]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, log, timeout=300, check=True):
    result = subprocess.run([str(item) for item in command], cwd=ROOT,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=timeout)
    log.write_text(result.stdout, newline="\n")
    if check and result.returncode != 0:
        raise RuntimeError(f"command failed ({result.returncode}); see {log}")
    return result


def original_sources():
    packages = ["microcode/generated/spk286_microcode_pkg.sv",
                "microcode/generated/spk286_microcode_rom.sv",
                "microcode/generated/spk286_microcode_sync_rom.sv",
                "rtl/spk286_protected_pkg.sv", "rtl/spk286_tss_pkg.sv"]
    paths = [CPU / name for name in packages]
    return paths + [path for path in sorted((CPU / "rtl").glob("*.sv")) if path not in paths]


OBSERVER = r'''
    // PRE-edge physical command/input snapshot; POST-edge architectural state.
    // This observer cannot drive any CPU input or modify a fixture expectation.
    integer p06_observer_fd = 0, p06_observer_edge = 0;
    string p06_observer_path;
    logic [23:0] p06_pre_address;
    logic [15:0] p06_pre_data_out, p06_pre_data_in;
    logic [3:0] p06_pre_status;
    logic p06_pre_bus, p06_pre_write, p06_pre_bhe, p06_pre_lock, p06_pre_hlda;
    logic p06_pre_reset, p06_pre_execute, p06_pre_ready, p06_pre_intr, p06_pre_nmi;
    logic p06_pre_hold, p06_pre_redirect;
    // Uninitialized fixture memory has four states in Icarus and two states
    // in the other simulator. Canonicalize only the observed INPUT, never the stimulus or
    // any architectural output. Preserve every defined input bit.
    function automatic logic [15:0] p06_observed_input(input logic [15:0] value);
        for (integer bit_index = 0; bit_index < 16; bit_index = bit_index + 1)
            p06_observed_input[bit_index] = value[bit_index] === 1'b1;
    endfunction
    function automatic logic [15:0] p06_input_unknown_mask(input logic [15:0] value);
        for (integer bit_index = 0; bit_index < 16; bit_index = bit_index + 1)
            case (value[bit_index])
                1'b0, 1'b1: p06_input_unknown_mask[bit_index] = 1'b0;
                default: p06_input_unknown_mask[bit_index] = 1'b1;
            endcase
    endfunction
    initial begin
        if ($value$plusargs("profile_trace=%s", p06_observer_path)) begin
            p06_observer_fd = $fopen(p06_observer_path, "w");
            if (p06_observer_fd == 0) $fatal(1, "cannot open profile compatibility trace");
            $fdisplay(p06_observer_fd, "edge,reset,execute,ready,intr,nmi,hold,redirect,bus,address,status,write,bhe,dataout,datain,lock,hlda,gpr,flags,cs,csbase,ip,halted,shutdown,retired,event,eventkind,eventvector,nmi_pending,nmi_blocked,sti_shadow,unsupported,control_error,microcode_fault,operand_blocked,prefetch,micro_active,micro_pc,datain_two_state,datain_unknown_mask");
        end
    end
    always @(posedge clk) begin
        p06_observer_edge = p06_observer_edge + 1;
        p06_pre_reset = reset; p06_pre_execute = execute_enable;
        p06_pre_ready = ready; p06_pre_intr = intr; p06_pre_nmi = nmi;
        p06_pre_hold = hold_request; p06_pre_redirect = redirect;
        p06_pre_bus = bus_valid; p06_pre_address = address;
        p06_pre_status = bus_status; p06_pre_write = bus_write; p06_pre_bhe = bus_bhe_n;
        p06_pre_data_out = data_out; p06_pre_data_in = data_in;
        p06_pre_lock = bus_lock; p06_pre_hlda = hlda;
        #1;
        if (p06_observer_fd != 0)
            $fdisplay(p06_observer_fd, "%0d,%b,%b,%b,%b,%b,%b,%b,%b,%06h,%h,%b,%b,%04h,%04h,%b,%b,%032h,%04h,%04h,%06h,%04h,%b,%b,%b,%b,%0d,%0d,%b,%b,%b,%b,%b,%b,%b,%0d,%b,%03h,%04h,%04h",
                p06_observer_edge, p06_pre_reset, p06_pre_execute, p06_pre_ready,
                p06_pre_intr, p06_pre_nmi, p06_pre_hold, p06_pre_redirect,
                p06_pre_bus, p06_pre_address, p06_pre_status, p06_pre_write, p06_pre_bhe,
                p06_pre_data_out, p06_pre_data_in, p06_pre_lock, p06_pre_hlda,
                debug_gpr, debug_flags, debug_cs, debug_cs_base, debug_ip,
                halted, shutdown, instruction_retired, event_completed,
                debug_event_kind, debug_event_vector, debug_nmi_pending,
                debug_nmi_blocked, debug_sti_shadow, unsupported_opcode, control_error,
                microcode_fault, operand_blocked, debug_prefetch_count,
                debug_micro_active, debug_micro_pc,
                p06_observed_input(p06_pre_data_in), p06_input_unknown_mask(p06_pre_data_in));
    end
    final begin
        if (p06_observer_fd != 0) $fclose(p06_observer_fd);
    end
'''


PROFILE_CONTROL = r'''
    integer p06_profile_argument = 0;
    integer p06_watchdog_multiplier = 1;
    logic [2:0] p06_requested_profile = 3'd0;
    wire [2:0] p06_active_profile;
    wire p06_profile_pending, p06_historical_enable;
    wire p06_phase_enable, p06_phase_two, p06_cpu_boundary;
    initial begin
        if (!$value$plusargs("profile=%d", p06_profile_argument)) p06_profile_argument = 0;
        if (p06_profile_argument < 0 || p06_profile_argument > 7)
            $fatal(1, "invalid compatibility profile argument");
        p06_requested_profile = 3'(p06_profile_argument);
        if (!$value$plusargs("watchdog_multiplier=%d", p06_watchdog_multiplier))
            p06_watchdog_multiplier = 1;
        if (p06_watchdog_multiplier < 1) $fatal(1, "invalid watchdog multiplier");
        if (p06_profile_argument == 0) p06_watchdog_multiplier = 1;
    end
    spk286_at_cpu_profile p06_clock (
        .clk(clk), .reset(reset), .apply(1'b0), .requested(p06_requested_profile),
        .active(p06_active_profile), .pending(p06_profile_pending),
        .historical(p06_historical_enable), .phase_enable(p06_phase_enable),
        .phase_two(p06_phase_two), .cpu_boundary(p06_cpu_boundary)
    );
'''


def fixture(out, name):
    original = CPU / f"sim/unit/spk286_{name}_tb.sv"
    source = original.read_text()
    instance = re.compile(r"\bspk286\s+dut\s*\(\.\*\);", re.MULTILINE)
    if len(instance.findall(source)) != 1:
        raise AssertionError(f"{name}: expected one unmodified full-CPU instance")
    if re.search(r"\bforce\s+dut\.", source):
        raise AssertionError(f"{name}: fixture drives internal CPU state")
    # Watchdogs count fabric edges, whereas nominal profiles now span up to
    # nine fabric edges per CPU boundary. Scaling only bounded watchdogs
    # allows completion without changing fixed stimulus/pause windows.
    watchdog = re.compile(r"\b(timeout_count|cycles|ticks)(\s*(?:<|<=)\s*)([0-9]+)\b")
    changes = []

    def replace_watchdog(match):
        changes.append({"old": match.group(0), "bound": int(match.group(3))})
        return f"{match.group(1)}{match.group(2)}(p06_watchdog_multiplier * {match.group(3)})"

    adapted = watchdog.sub(replace_watchdog, source)
    code_adjustments = []
    if name == "protected_system":
        # The original fixture patches 0197 from HLT to IRET after outer IRET
        # retires. A slower EU allows CODE fetch to retain that byte earlier.
        # Install the same intended byte before the redirect, only in historical
        # modes. Preserve the original later patch and every assertion/delay.
        anchor_restart = "        far_restart(16'h0038, 16'h0190);"
        early_patch = "        if (p06_historical_enable) memory[16'h0197] = 8'hCF;\n"
        if adapted.count(anchor_restart) != 1 or source.count("memory[16'h0197] = 8'hCF;") != 1:
            raise AssertionError("protected_system: prefetch fixture anchor changed")
        adapted = adapted.replace(anchor_restart, early_patch + anchor_restart)
        code_adjustments.append({
            "kind": "historical-only earlier installation of intended code byte",
            "address": "000197", "value": "CF", "insert_before": anchor_restart.strip(),
            "inserted_statement": early_patch.strip(), "original_later_patch": "preserved",
            "reason": "original patch occurs after a retained CODE fetch in a slower EU profile",
            "evidence": {
                "trace": "build/p06-profile-compat-focal2-20261004/protected_system/profile-1-iverilog.csv",
                "code_capture_edge": 97209, "code_address": "000196", "code_payload": "F412",
                "outer_iret_retirement_edge": 97401, "queue_bytes_at_retirement": 6,
                "stale_hlt_retirement_edge": 97418,
            },
            "architectural_expectations": "unchanged", "fixed_delays": "unchanged",
            "max_stimulus": "unchanged",
        })
    profiled = instance.sub("spk286_profiled dut (.historical_enable(p06_historical_enable), "
                            ".cpu_boundary(p06_cpu_boundary), .timing_read_wait_event(1'b0), "
                            ".profile_change_pending(1'b0), .profile_change_ready(), .*);", adapted)
    anchor = '`include "spk286_signals.svh"'
    if source.count(anchor) != 1:
        raise AssertionError(f"{name}: missing shared public signals")
    profiled = profiled.replace(anchor, anchor + "\n" + PROFILE_CONTROL + OBSERVER)
    # The golden fixture adds the same passive observer and scale variable1.
    # Original expectations, control flow, timing and engine are retained.
    golden = source.replace(anchor, anchor + "\n" + OBSERVER)
    directory = out / name
    directory.mkdir()
    profiled_path = directory / f"spk286_{name}_profiled_tb.sv"
    golden_path = directory / f"spk286_{name}_original_tb.sv"
    profiled_path.write_text(profiled, newline="\n")
    golden_path.write_text(golden, newline="\n")
    manifest = {"original": original.relative_to(ROOT).as_posix(), "original_sha256": sha(original),
                "profiled_sha256": sha(profiled_path), "golden_sha256": sha(golden_path),
                "watchdog_changes": changes,
                "functional_expectations": "unchanged", "fixed_delays": "unchanged",
                "code_stimulus_adjustments": code_adjustments,
                "trace_normalization": {"pre_reset": ["address=0", "status=0", "hlda=0"],
                    "input_datain": "observed X/Z input bits map to 0; defined bits preserved; DUT input unchanged",
                    "post_architecture": "none"}}
    (directory / "fixture.json").write_text(json.dumps(manifest, indent=2) + "\n", newline="\n")
    return profiled_path, golden_path


class TraceAccumulator:
    """Hash raw and declared two-state views without discarding any edge."""
    def __init__(self):
        self.raw = hashlib.sha256()
        self.canonical = hashlib.sha256()
        self.stats = {"bytes": 0, "canonical_bytes": 0, "rows": 0,
                      "reset_rows": 0, "input_unknown_rows": 0, "input_unknown_bits": 0}
        self.buffer = b""
        self.header = None

    def update(self, chunk):
        self.raw.update(chunk)
        self.stats["bytes"] += len(chunk)
        lines = (self.buffer + chunk).split(b"\n")
        self.buffer = lines.pop()
        for line in lines:
            fields = line.split(b",")
            if len(fields) != 40:
                raise AssertionError(f"observer stream field count: {len(fields)}")
            if self.header is None:
                self.header = line
            else:
                self.stats["rows"] += 1
                if fields[1] == b"1":
                    self.stats["reset_rows"] += 1
                    # Only these PRE-reset outputs are undefined before reset.
                    fields[9], fields[10], fields[16] = b"000000", b"0", b"0"
                mask = int(fields[39], 16)
                if mask:
                    self.stats["input_unknown_rows"] += 1
                    self.stats["input_unknown_bits"] += mask.bit_count()
                # The bit-precise helper preserves known bits within an X hex
                # nibble; a text-only hex replacement would lose those bits.
                fields[14] = fields[38]
                fields[39] = b"0000"  # Diagnostic mask differs by simulator.
            canonical = b",".join(fields) + b"\n"
            self.canonical.update(canonical)
            self.stats["canonical_bytes"] += len(canonical)

    def finish(self, storage):
        if self.buffer or self.stats["rows"] < 1:
            raise AssertionError("observer stream incomplete or empty")
        return {**self.stats, "sha256": self.raw.hexdigest(),
                "canonical_sha256": self.canonical.hexdigest(), "storage": storage,
                "canonical_rules": {"pre_reset": ["address=0", "status=0", "hlda=0"],
                    "datain": "bit-precise observed two-state input helper",
                    "datain_unknown_mask": "diagnostic mask set to 0 only in canonical view",
                    "architecture": "unchanged"}}


def test_run(command, log, trace, profile, multiplier, storage="digest"):
    args = [*command, f"+profile={profile}", f"+watchdog_multiplier={multiplier}"]
    if storage == "raw":
        result = run([*args, f"+profile_trace={trace}"], log, timeout=300, check=False)
        trace_info(trace)
        return result
    # Keep the exact observer byte stream, but consume it in Linux RAM rather
    # than writing gigabytes through DrvFs. SHA256 covers every byte/edge.
    # The FIFO is owned by this invocation and removed even on an exception.
    with tempfile.TemporaryDirectory(prefix="p06-profile-trace-") as pipe_dir:
        pipe = Path(pipe_dir) / "observer.csv"
        os.mkfifo(pipe)
        anchor = os.open(pipe, os.O_RDWR)
        accumulator = TraceAccumulator()
        prefix = bytearray()
        tail = bytearray()
        errors = []

        def consume():
            try:
                with pipe.open("rb") as source:
                    while chunk := source.read(65536):
                        accumulator.update(chunk)
                        if len(prefix) < 8192:
                            prefix.extend(chunk[:8192 - len(prefix)])
                        tail.extend(chunk)
                        if len(tail) > 65536:
                            del tail[:-65536]
            except BaseException as error:
                errors.append(error)

        reader = threading.Thread(target=consume, name="p06-observer-consumer")
        reader.start()
        try:
            result = run([*args, f"+profile_trace={pipe}"], log, timeout=300, check=False)
        finally:
            os.close(anchor)
            reader.join(timeout=30)
        if reader.is_alive():
            raise RuntimeError("observer FIFO did not close after simulator exit")
        if errors:
            raise RuntimeError(f"observer FIFO failed: {errors}")
        stats = accumulator.finish("streamed raw/canonical SHA256")
        stats["bounded_samples"] = "first 8KiB and last 64KiB; samples are not the comparison input"
        trace.with_suffix(".digest.json").write_text(json.dumps(stats, indent=2) + "\n", newline="\n")
        trace.with_suffix(".prefix.txt").write_bytes(prefix)
        trace.with_suffix(".tail.txt").write_bytes(tail)
        return result


def trace_info(trace):
    metadata = trace.with_suffix(".digest.json")
    if not metadata.exists():
        accumulator = TraceAccumulator()
        with trace.open("rb") as source:
            while chunk := source.read(65536):
                accumulator.update(chunk)
        metadata.write_text(json.dumps(accumulator.finish("raw CSV"), indent=2) + "\n", newline="\n")
    return json.loads(metadata.read_text())


def trace_equal(first, second, canonical=False):
    a, b = trace_info(first), trace_info(second)
    digest_key = "canonical_sha256" if canonical else "sha256"
    byte_key = "canonical_bytes" if canonical else "bytes"
    return (a[digest_key], a[byte_key], a["rows"]) == (b[digest_key], b[byte_key], b["rows"])


def pass_lines(stdout):
    return [line for line in stdout.splitlines() if "PASS" in line]


def aggregate(out, leaves):
    """Accept only disjoint, source-identical shards with the complete matrix."""
    if not out.is_relative_to((ROOT / "build").resolve()):
        raise AssertionError("aggregate output must be under workspace build")
    if (out / "receipt.json").exists():
        raise AssertionError("aggregate receipt already exists")
    results, sources, covered, references, adjustments = [], {}, set(), [], {}
    generated_hashes = None
    for leaf in leaves:
        leaf = leaf.resolve()
        if not leaf.is_relative_to((ROOT / "build").resolve()):
            raise AssertionError("leaf receipt must be under workspace build")
        receipt = json.loads(leaf.read_text())
        if receipt["status"] != "PASS" or receipt["failures"] or receipt["source_changes"]:
            raise AssertionError(f"unaccepted leaf: {leaf}")
        if receipt["profiles"] != list(range(8)):
            raise AssertionError("each final shard must cover profiles 0..7")
        units = set(receipt["units"])
        if len(units) != len(receipt["units"]) or covered & units:
            raise AssertionError("overlapping or duplicate shard units")
        covered |= units
        for name, digest in receipt["source_sha256"].items():
            if name in sources and sources[name] != digest:
                raise AssertionError(f"shard source mismatch: {name}")
            if sha(ROOT / name) != digest:
                raise AssertionError(f"source changed after shard: {name}")
            sources[name] = digest
        hashes = receipt["generated_source_sha256"]
        if generated_hashes is not None and generated_hashes != hashes:
            raise AssertionError("generated CPU mismatch across shards")
        generated_hashes = hashes
        for name, digest in hashes.items():
            if sha(leaf.parent / "generated" / name) != digest:
                raise AssertionError("generated CPU artifact changed")
        for record in receipt["results"]:
            if record["status"] != "PASS":
                raise AssertionError("non-PASS result in accepted leaf")
            unit = record["unit"]
            if unit not in units:
                raise AssertionError("result outside shard unit set")
            if record.get("kind") == "MAX per-edge equivalence":
                if record["original_trace_sha256"] != record["profiled_trace_sha256"]:
                    raise AssertionError("MAX raw stream mismatch")
            else:
                stem = leaf.parent / unit / f"profile-{record['profile']}-{record['simulator']}.csv"
                observed = trace_info(stem)
                if observed != record["trace"]:
                    raise AssertionError("trace metadata changed after shard")
                if stem.exists() and sha(stem) != observed["sha256"]:
                    raise AssertionError("raw trace artifact changed")
            results.append({**record, "artifact_root": leaf.parent.relative_to(ROOT).as_posix()})
        adjustments.update(receipt["code_stimulus_adjustments"])
        references.append({"path": leaf.relative_to(ROOT).as_posix(), "sha256": sha(leaf)})
    if covered != set(UNITS):
        raise AssertionError(f"matrix unit coverage mismatch: {sorted(covered)}")
    actual = [(r["unit"], r.get("simulator", "MAX equivalence"), r.get("profile", 0)) for r in results]
    expected = [(name, "iverilog", profile) for name in UNITS for profile in range(8)]
    expected += [(name, "verilator", profile) for name in DUAL for profile in range(8)]
    expected += [(name, "MAX equivalence", 0) for name in UNITS]
    if len(actual) != len(set(actual)) or set(actual) != set(expected):
        raise AssertionError("matrix result coverage must be exactly 208 Icarus + 56 Verilator + 26 MAX")
    out.mkdir(parents=True, exist_ok=True)
    receipt = {"status": "PASS", "units": UNITS, "profiles": list(range(8)),
        "counts": {"iverilog": 208, "verilator": 56, "max_equivalence": 26},
        "scope": "directed functional compatibility; MAX compares complete RAW byte-stream hashes; dual compares complete declared CANONICAL byte-stream hashes; no hardware historical timing claim",
        "source_sha256": sources, "generated_source_sha256": generated_hashes,
        "leaf_receipts": references, "code_stimulus_adjustments": adjustments,
        "results": results, "failures": [], "source_changes": []}
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", newline="\n")
    print("P06_PROFILE_COMPATIBILITY_AGGREGATE_PASS Icarus=208 Verilator=56 MAX=26", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--units", default=",".join(UNITS))
    parser.add_argument("--profiles", default="0,1,2,3,4,5,6,7")
    parser.add_argument("--dual-units", default=",".join(DUAL),
                        help="empty string disables optional Verilator functional runs")
    parser.add_argument("--watchdog-multiplier", type=int, default=16)
    parser.add_argument("--trace-storage", choices=["digest", "raw"], default="digest",
                        help="digest hashes every raw/canonical byte through a Linux FIFO and stores bounded samples")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--aggregate", nargs="+", type=Path,
                        help="combine disjoint PASS leaf receipts into exactly 208+56+26 results")
    args = parser.parse_args()
    if args.aggregate:
        aggregate(args.output.resolve(), args.aggregate)
        return
    units = [name for name in args.units.split(",") if name]
    profiles = [int(value) for value in args.profiles.split(",")]
    dual = set(name for name in args.dual_units.split(",") if name)
    if not units or len(set(units)) != len(units) or any(name not in UNITS for name in units):
        parser.error("--units must contain unique selected full-CPU unit names")
    if not profiles or len(set(profiles)) != len(profiles) or any(profile not in range(8) for profile in profiles):
        parser.error("--profiles must contain unique profile IDs0..7")
    if args.watchdog_multiplier < 1:
        parser.error("--watchdog-multiplier must be positive")
    out = args.output.resolve()
    if not out.is_relative_to((ROOT / "build").resolve()):
        parser.error("--output must be a fresh directory under the workspace build directory")
    out.mkdir(parents=True, exist_ok=False)
    original = original_sources()
    extras = [ROOT / "scripts/build_p06_profile_cpu.py",
              ROOT / "rtl/spk286_timing/spk286_instruction_schedule.sv",
              ROOT / "rtl/spk286_timing/spk286_instruction_timing.sv",
              ROOT / "rtl/spk286_timing/spk286_target_handoff.sv",
              ROOT / "rtl/spk286_timing/spk286_target_replay.sv",
              ROOT / "rtl/spk286_integration/spk286_at_cpu_profile.sv",
              CPU / "sim/unit/spk286_signals.svh", Path(__file__).resolve()]
    inputs = original + extras + [CPU / f"sim/unit/spk286_{name}_tb.sv" for name in units]
    before = {path.relative_to(ROOT).as_posix(): sha(path) for path in inputs}
    generated = build(out / "generated")
    generated_hashes = {path.name: sha(path) for path in generated.values()}
    selected = [path for path in original if path.name not in {"spk286.sv", "spk286_events.sv"}]
    selected += list(generated.values()) + extras[1:6]
    fixtures = {name: fixture(out, name) for name in units}
    if args.prepare_only:
        (out / "prepared.json").write_text(json.dumps({"status": "PREPARED_NOT_TESTED",
            "source_sha256": before, "units": units, "profiles": profiles}, indent=2) + "\n", newline="\n")
        print("P06_PROFILE_COMPAT_PREPARED", flush=True)
        return
    include = ["-I" + str(CPU / "rtl"), "-I" + str(CPU / "sim/unit")]
    run(["verilator", "--lint-only", "--Wall", "--top-module", "spk286_profiled", *include, *selected],
        out / "lint-profiled.log")
    results, failures = [], []
    for name in units:
        directory = out / name
        profiled, golden = fixtures[name]
        top = f"spk286_{name}_tb"
        run(["iverilog", "-g2012", "-s", top, *include, "-o", directory / "profiled.vvp",
             *selected, profiled], directory / "iverilog-build.log")
        traces = {}
        for profile in profiles:
            trace = directory / f"profile-{profile}-iverilog.csv"
            result = test_run(["vvp", directory / "profiled.vvp"],
                directory / f"profile-{profile}-iverilog.log", trace, profile, args.watchdog_multiplier, args.trace_storage)
            observed = trace_info(trace)
            status = "PASS" if result.returncode == 0 and pass_lines(result.stdout) else "FAIL"
            record = {"unit": name, "profile": profile, "name": PROFILE_NAMES[profile],
                      "simulator": "iverilog", "status": status, "returncode": result.returncode,
                      "pass": pass_lines(result.stdout), "trace_sha256": observed["sha256"],
                      "canonical_trace_sha256": observed["canonical_sha256"], "trace": observed}
            results.append(record); traces[profile] = trace
            if status == "FAIL":
                failures.append(record)
            print(f"PROFILE_COMPAT_{status} {name} {PROFILE_NAMES[profile]} Icarus", flush=True)
        if 0 in profiles:
            run(["iverilog", "-g2012", "-s", top, *include, "-o", directory / "original.vvp",
                 *original, golden], directory / "original-build.log")
            original_trace = directory / "original-max.csv"
            result = test_run(["vvp", directory / "original.vvp"], directory / "original-run.log",
                              original_trace, 0, 1, args.trace_storage)
            equal = result.returncode == 0 and pass_lines(result.stdout) and trace_equal(original_trace, traces[0])
            record = {"unit": name, "status": "PASS" if equal else "FAIL", "kind": "MAX per-edge equivalence",
                      "original_trace_sha256": trace_info(original_trace)["sha256"],
                      "profiled_trace_sha256": trace_info(traces[0])["sha256"],
                      "comparison": "SHA256/byte-count/row-count equality of complete RAW per-edge stream"}
            results.append(record)
            if not equal:
                failures.append(record)
            print(f"PROFILE_MAX_{record['status']} {name}", flush=True)
        if name in dual:
            run(["verilator", "--binary", "--timing", "--assert", "-CFLAGS", "-O0", "-j", "4", "--top-module", top,
                 "--Mdir", directory / "obj", "-o", "profiled-test", *include, *selected, profiled],
                directory / "verilator-build.log", timeout=600)
            for profile in profiles:
                trace = directory / f"profile-{profile}-verilator.csv"
                result = test_run([directory / "obj/profiled-test"],
                    directory / f"profile-{profile}-verilator.log", trace, profile, args.watchdog_multiplier, args.trace_storage)
                observed = trace_info(trace)
                equal = result.returncode == 0 and pass_lines(result.stdout) and trace_equal(trace, traces[profile], canonical=True)
                record = {"unit": name, "profile": profile, "name": PROFILE_NAMES[profile],
                          "simulator": "verilator", "status": "PASS" if equal else "FAIL",
                          "returncode": result.returncode, "pass": pass_lines(result.stdout),
                          "trace_sha256": observed["sha256"], "canonical_trace_sha256": observed["canonical_sha256"],
                          "trace": observed,
                          "comparison": "SHA256/byte-count/row-count equality of complete declared CANONICAL per-edge stream to Icarus"}
                results.append(record)
                if not equal:
                    failures.append(record)
                print(f"PROFILE_COMPAT_{record['status']} {name} {PROFILE_NAMES[profile]} Verilator", flush=True)
    after = {path.relative_to(ROOT).as_posix(): sha(path) for path in inputs}
    changes = [name for name in before if before[name] != after[name]]
    receipt = {"status": "PASS" if not failures and not changes else "FAIL", "source_sha256": before,
               "units": units, "profiles": profiles, "watchdog_multiplier_historical": args.watchdog_multiplier,
               "trace_storage": args.trace_storage,
               "generated_source_sha256": generated_hashes,
               "verilator_cflags": "-O0 (compile-time optimization only; original stimuli/assertions unchanged)",
               "scope": "directed functional compatibility only; declared build-only fixture adaptations in fixture.json; no hardware historical timing claim",
               "code_stimulus_adjustments": {name: json.loads((out / name / "fixture.json").read_text())["code_stimulus_adjustments"] for name in units},
               "results": results, "failures": failures, "source_changes": changes}
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", newline="\n")
    if failures or changes:
        raise RuntimeError(f"profile compatibility failed: {len(failures)} results; source changes={changes}; see {out}")
    print(f"P06_PROFILE_COMPATIBILITY_PASS Icarus={len(units)*len(profiles)} "
          f"Verilator={len(set(units)&dual)*len(profiles)} MAX={len(units) if 0 in profiles else 0}", flush=True)


if __name__ == "__main__":
    main()
