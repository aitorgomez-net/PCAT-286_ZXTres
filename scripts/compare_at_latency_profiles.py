"""Compare two frozen physical SDRAM workload runs without relaxing state checks."""
import argparse
import hashlib
import json
from pathlib import Path
import re

from report_checkit_profile import WORKLOADS, fields, read_run


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def physical_run(path):
    run = read_run(path)
    signature = run["signature"]
    if set(signature) != {"gpr", "flags", "memory", "ideal_owner"}:
        raise ValueError(f"Incomplete architectural signature: {path}")
    for key, width in (("gpr", 32), ("flags", 4), ("memory", 16)):
        if not re.fullmatch(rf"[0-9a-fA-F]{{{width}}}", signature[key]):
            raise ValueError(f"Malformed architectural signature {key}: {path}")
    buffers = [fields(line) for line in path.read_text().splitlines()
               if line.startswith("RAM_BUFFER_RESULT ")]
    if len(buffers) != 1 or buffers[0]["enabled"] != "1":
        raise ValueError(f"Production RAM buffer must be enabled: {path}")
    run["physical_data_buffer"] = {key: int(value) for key, value in buffers[0].items()}
    return run


def compare(baseline, candidate):
    macros = (baseline / "performance-macros.txt").read_text().split()
    if macros != (candidate / "performance-macros.txt").read_text().split():
        raise ValueError("Production performance options differ")
    manifests = []
    for build in (baseline, candidate):
        verified = (build / "sources-verified.log").read_text().splitlines()
        manifest = {}
        for line in (build / "compiled-sources.sha256").read_text().splitlines():
            match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
            if not match or match[2] in manifest:
                raise ValueError(f"Malformed or duplicate compiled source: {build}")
            manifest[match[2]] = match[1]
        required = {"config.tcl", "vendor/spk286/rtl/spk286.sv",
                    "rtl/spk286_integration/spk286_at_bus_bridge.sv",
                    "rtl/spk286_integration/spk286_at_mister_sdram_owner.sv",
                    "sim/spk286_integration/spk286_checkit_workload_tb.sv"}
        if not required.issubset(manifest):
            raise ValueError(f"Incomplete compiled-source manifest: {build}")
        if verified != [f"{name}: OK" for name in manifest]:
            raise ValueError(f"Incomplete compiled-source verification: {build}")
        manifests.append(manifest)
    before_sources, after_sources = manifests
    if before_sources.keys() != after_sources.keys():
        raise ValueError("Compared runs have different compiled source sets")
    changed = {name for name in before_sources if before_sources[name] != after_sources[name]}
    allowed = {"rtl/spk286_integration/spk286_at_bus_bridge.sv",
               "rtl/spk286_integration/spk286_at_mister_sdram_owner.sv"}
    if not changed.issubset(allowed):
        raise ValueError(f"Uncontrolled CPU/firmware/configuration/harness changes: {sorted(changed - allowed)}")
    rom_hashes = {}
    for workload in WORKLOADS:
        name = f"checkit-{workload}.rom"
        before_hash, after_hash = digest(baseline / name), digest(candidate / name)
        if before_hash != after_hash:
            raise ValueError(f"Executable workload differs: {name}")
        rom_hashes[name] = before_hash
    rows = []
    for workload in WORKLOADS:
        for p03 in (0, 1):
            name = f"{workload}-p03-{p03}.log"
            before, after = physical_run(baseline / name), physical_run(candidate / name)
            if before["signature"] != after["signature"]:
                raise ValueError(f"Architectural state differs: {name}")
            if before["signature"]["ideal_owner"] != "0":
                raise ValueError(f"Comparison requires physical SDRAM: {name}")
            for key in ("retired", "writes", "sdram_writes"):
                if before["result"][key] != after["result"][key]:
                    raise ValueError(f"{key} differs: {name}")
            for run in (before, after):
                if run["result"]["p03"] != p03 or run["result"]["workload"] != workload:
                    raise ValueError(f"Wrong workload/options: {name}")
            b, a = before["result"]["cycles"], after["result"]["cycles"]
            row = dict(workload=workload, p03=p03, baseline=before, candidate=after,
                       state_and_write_counts_match=True,
                       fewer_cycles_percent=100 * (1 - a / b),
                       throughput_gain_percent=100 * (b / a - 1))
            rows.append(row)
            print(f"LATENCY_COMPARE_PASS {workload} p03={p03}: "
                  f"{b} -> {a} cycles, throughput {row['throughput_gain_percent']:+.3f}%")
    return dict(scope="Four synthetic kernels, physical SDRAM with refresh; no DMA/HPS/IRQ contention. "
                      "These cycle counts are not DOS CheckIT scores. Speculative read counts may differ.",
                clock_mhz=50, performance_macros=macros,
                changed_source_inputs=sorted(changed), firmware_sha256=rom_hashes,
                baseline=str(baseline), candidate=str(candidate),
                compiled_manifest_sha256={"baseline": digest(baseline / "compiled-sources.sha256"),
                                          "candidate": digest(candidate / "compiled-sources.sha256")},
                runs=rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = compare(args.baseline.resolve(), args.candidate.resolve())
    # Do not overwrite an earlier receipt with results from a later build.
    with args.output.open("x") as output:
        json.dump(result, output, indent=2)
        output.write("\n")


if __name__ == "__main__":
    main()
