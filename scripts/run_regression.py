#!/usr/bin/env python3
"""Run the current PCAT-286 regressions on Linux/WSL.

Use --list to see the test commands and requirements without running them.
Each run writes command logs and summary.json in a fresh build directory.
Third-party firmware, VHDL checks requiring GHDL/Docker, and Quartus/board
checks use their individual scripts and are separate from these suites.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
SIM = ("iverilog", "vvp", "verilator", "make", "g++")


@dataclass(frozen=True)
class Test:
    name: str
    suite: str
    command: tuple[str, ...]
    tools: tuple[str, ...] = ()


def shell(name, suite, script, *, tools=SIM, positional=False):
    return Test(name, suite, ("bash", f"scripts/{script}.sh") +
                (("{work}",) if positional else ()), ("bash", *tools))


def python(name, suite, script, *arguments, tools=()):
    return Test(name, suite, (sys.executable, f"scripts/{script}.py", *arguments), tools)


TESTS = [
    python("project", "smoke", "check_pcat_project"),
    python("diagnostic-rom", "smoke", "build_diag_rom", "--check", tools=("nasm",)),
    python("event-rom", "smoke", "build_event_diag_rom", "--check", tools=("nasm",)),
    python("profile-generation", "smoke", "build_p06_profile_cpu", "--check", "--output", "{work}"),
    shell("cpu-package", "smoke", "test_i1_cpu_package"),
    shell("bus-bridge", "smoke", "test_a1_at_bridge"),
    shell("memory-arbiter", "smoke", "test_a2_memory_arbiter"),
    shell("interrupts", "devices", "test_a3_interrupts"),
    shell("dma-refresh", "devices", "test_a4_dma_refresh_pit"),
    shell("device-routing", "devices", "test_a5_at_devices"),
    shell("dma-registers", "devices", "test_at_dma_registers"),
    shell("ems", "devices", "test_at_ems"),
    shell("keyboard", "devices", "test_at_keyboard"),
    shell("mouse", "devices", "test_at_mouse"),
    shell("rtc", "devices", "test_at_rtc_cmos"),
    shell("pit-ports", "devices", "test_at_pit_ports"),
    shell("pit-irq", "devices", "test_at_pit_irq0"),
    shell("serial", "devices", "test_at_serial"),
    shell("soundblaster", "devices", "test_at_soundblaster"),
    shell("xtide", "devices", "test_at_xtide_machine"),
    python("floppy-write", "devices", "test_at_floppy_write", "--output", "{work}", tools=SIM),
    python("floppy-protection", "devices", "test_at_floppy_write_protect", "--output", "{work}", tools=SIM),
    shell("bridge-response", "memory", "test_at_bridge_response"),
    shell("bridge-cancel", "memory", "test_at_bridge_cancel_pipeline"),
    shell("memory-port", "memory", "test_at_mister_memory_port"),
    shell("sdram-owner", "memory", "test_at_mister_sdram_owner"),
    shell("ddram-owner", "memory", "test_at_mister_ddram_owner"),
    shell("sdram-capture", "memory", "test_at_sdram_capture", tools=("iverilog", "vvp")),
    shell("sdram-phase", "memory", "test_at_sdram_phase", positional=True),
    shell("write-admission", "memory", "test_at_sdram_write_admission"),
    shell("code-buffer", "memory", "test_at_code_buffer_production"),
    shell("data-buffer", "memory", "test_at_ram_read_buffer"),
    shell("posted-write-buffer", "memory", "test_at_posted_write_buffer"),
    shell("rom-loader", "memory", "test_at_hps_rom_loader"),
    shell("data-idle", "memory", "test_at_data_idle"),
    python("fetch-turnaround", "timing", "test_fetch_turnaround", "--output", "{work}", tools=SIM),
    python("cpu-profile", "timing", "test_spk286_at_cpu_profile", "--output", "{work}", tools=(*SIM, "yosys")),
    python("instruction-timing", "timing", "test_spk286_instruction_timing", "--output", "{work}", tools=(*SIM, "yosys")),
    python("target-handoff", "timing", "test_spk286_target_handoff", "--output", "{work}", tools=(*SIM, "yosys")),
    python("encoding-preview", "timing", "test_spk286_encoding_preview", "--output", "{work}", tools=(*SIM, "yosys")),
    shell("profile-bridge", "timing", "test_at_profile_bridge"),
    shell("native-output", "video", "test_at_native_output", tools=("iverilog", "vvp")),
    shell("hdmi-vsync", "video", "test_at_hdmi_vsync", tools=("iverilog", "vvp")),
    shell("frame-shadowmask", "video", "test_at_frame_shadowmask", tools=("iverilog", "vvp")),
    shell("video-options", "video", "test_at_video_options", tools=("iverilog", "vvp")),
    shell("video-window", "video", "test_at_video_window"),
    shell("ega-decode", "video", "test_at_ega_decode"),
    shell("splash", "video", "test_at_splash_control"),
    shell("pause-key", "video", "test_at_pause_key"),
    shell("scaler-config", "video", "test_at_scaler_config", tools=("iverilog", "vvp")),
    shell("machine", "machine", "test_at_machine_boundary", tools=(*SIM, "nasm")),
    shell("first-fetch", "machine", "test_at_bios_first_fetch", tools=(*SIM, "nasm")),
    shell("loadall", "machine", "test_at_loadall_xms", tools=(*SIM, "nasm")),
    shell("memory-map", "machine", "test_at_memory_entry", tools=(*SIM, "nasm")),
    shell("warm-reset", "machine", "test_at_code_buffer_warm_reset", tools=(*SIM, "nasm")),
    shell("soundblaster-machine", "machine", "test_at_soundblaster_machine", tools=(*SIM, "nasm")),
    python("live-speed", "profiles", "test_p06_live_speed", "--output", "{work}", tools=(*SIM, "yosys")),
    python("length-fault", "profiles", "test_p06_length_fault_boundary", "--dual", "--output", "{work}", tools=SIM),
    python("handoff-integration", "profiles", "test_p06_target_handoff_integration", "--dual", "--output", "{work}", tools=SIM),
    python("profile-components", "profiles", "check_p06_profile_components", "--output", "{work}", tools=(*SIM, "yosys")),
    python("profile-compatibility", "profiles", "test_p06_profile_compatibility", "--output", "{work}", tools=SIM),
    python("machine-profiles", "profiles", "test_at_speed_profiles", "--output", "{work}", tools=(*SIM, "nasm")),
    python("repeat-local", "formal", "test_p06_repeat_local_equivalence", "--output", "{work}", tools=("yosys",)),
    python("repeat-selector", "formal", "test_p06_repeat_branch_equivalence", "--output", "{work}", tools=("yosys",)),
]


def main():
    suites = sorted({test.suite for test in TESTS})
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", action="append", choices=[*suites, "all"],
                        help="repeat to combine suites; default: smoke")
    parser.add_argument("--test", action="append", choices=[test.name for test in TESTS],
                        help="select named tests instead of whole suites")
    parser.add_argument("--list", action="store_true", help="list selected tests, commands and tools")
    parser.add_argument("--output", type=Path, help="fresh directory under build/")
    parser.add_argument("--keep-going", action="store_true", help="continue after a failing test")
    parser.add_argument("--timeout", type=int, default=10800, help="seconds allowed per test (default: 10800)")
    args = parser.parse_args()
    chosen_suites = set(args.suite or (["all"] if args.list else ["smoke"]))
    selected = [test for test in TESTS if
                (test.name in args.test if args.test else "all" in chosen_suites or test.suite in chosen_suites)]
    if args.list:
        for test in selected:
            print(f"{test.name:24} [{test.suite}] {shlex.join(test.command)}")
            if test.tools:
                print("  Requires: " + ", ".join(test.tools))
        return
    if os.name == "nt":
        parser.error("run inside Linux/WSL; the simulator runners require Bash and POSIX tools")
    if args.timeout < 1:
        parser.error("--timeout must be positive")
    missing = sorted({tool for test in selected for tool in test.tools if not shutil.which(tool)})
    if missing:
        parser.error("missing required tools: " + ", ".join(missing))
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S-%fZ")
    output = (args.output or ROOT / "build/regression" / stamp).resolve()
    if not output.is_relative_to((ROOT / "build").resolve()) or output == (ROOT / "build").resolve():
        parser.error("--output must be a fresh subdirectory under build/")
    output.mkdir(parents=True, exist_ok=False)
    report = {"status": "RUNNING", "started_utc": stamp, "selected": [t.name for t in selected], "tests": []}

    def save():
        (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")

    save()
    for test in selected:
        work = output / test.name
        command = [item.replace("{work}", str(work)) for item in test.command]
        env = dict(os.environ, PCAT_BUILD_DIR=str(work), PCAT_CODE_BUFFER_BUILD_DIR=str(work),
                   PCAT_CODE_BUFFER_RESET_DIR=str(work), AT_NATIVE_OUTPUT_TEST_OUTPUT=str(work),
                   AT_FRAME_TEST_OUTPUT=str(work), AT_HDMI_VSYNC_OUTPUT=str(work))
        log = output / f"{test.name}.log"
        print(f"RUN  {test.name} ({test.suite})", flush=True)
        started = time.monotonic()
        with log.open("w") as stream:
            process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=stream,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = process.wait(timeout=args.timeout)
            except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                code = 130 if isinstance(error, KeyboardInterrupt) else 124
        record = {"name": test.name, "suite": test.suite, "command": command,
                  "exit_code": code, "status": "PASS" if code == 0 else "FAIL",
                  "seconds": round(time.monotonic() - started, 3), "log": log.name}
        report["tests"].append(record)
        save()
        print(f"{record['status']:4} {test.name} ({record['seconds']}s): {log.relative_to(ROOT)}", flush=True)
        if code and (not args.keep_going or code == 130):
            print("\n".join(log.read_text(errors="replace").splitlines()[-30:]), flush=True)
            break
    report["status"] = "PASS" if len(report["tests"]) == len(selected) and all(
        item["exit_code"] == 0 for item in report["tests"]) else "FAIL"
    save()
    print(f"{report['status']}: {output / 'summary.json'}", flush=True)
    raise SystemExit(0 if report["status"] == "PASS" else 1)


if __name__ == "__main__":
    main()
