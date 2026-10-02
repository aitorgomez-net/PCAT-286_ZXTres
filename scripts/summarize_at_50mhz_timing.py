#!/usr/bin/env python3
"""Summarize preserved TimeQuest reports; never infer closure from top-N paths."""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import re


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def table_rows(text):
    for line in text.splitlines():
        if line.startswith(";"):
            yield [value.strip() for value in line.strip("; ").split(";")]


def parse_fmax(text):
    # An empty trailing Note column is stripped by table_rows. Those rows
    # still have all three actual values and include the CPU/system clock.
    return {row[2]: float(row[0].split()[0]) for row in table_rows(text)
            if len(row) in (3, 4) and re.fullmatch(r"\d+(?:\.\d+)? MHz", row[0])}


def parse_report(path):
    text = path.read_text(errors="replace")
    summary = text.split("Path #1:", 1)[0]
    rows = []
    for values in table_rows(summary):
        if len(values) == 8 and re.fullmatch(r"-?\d+\.\d+", values[0]):
            rows.append(dict(zip(
                ("slack_ns", "from", "to", "launch_clock", "latch_clock",
                 "relationship_ns", "clock_skew_ns", "data_delay_ns"), values)))
            for key in ("slack_ns", "relationship_ns", "clock_skew_ns", "data_delay_ns"):
                rows[-1][key] = float(rows[-1][key])
    result = {"reported_paths": len(rows),
              "reported_violations": sum(row["slack_ns"] < 0 for row in rows),
              "top_paths": rows[:5],
              "endpoint_families": dict(collections.Counter(
                  re.sub(r"\[\d+\].*", "", row["to"].rsplit("|", 1)[-1])
                  for row in rows))}
    if not rows:
        return result
    first = text.split("Path #1:", 1)[1].split("Path #2:", 1)[0]
    statistics = first.split("; Statistics", 1)[1].split("; Data Arrival Path", 1)[0]
    stat_rows = list(table_rows(statistics))
    result["logic_levels"] = next(int(row[2]) for row in stat_rows
                                  if row[0] == "Number of Logic Levels")
    # Data statistics only: don't combine clock and data interconnect totals.
    data_stats = statistics.split(";   Data", 1)[1].split(";  Required Path", 1)[0]
    for row in table_rows(data_stats):
        if row[0] in ("IC", "Cell") and len(row) == 7:
            result[f"data_{row[0].lower()}_delay_ns"] = float(row[3])
    arrival = first.split("; Data Arrival Path", 1)[1].split("; Data Required Path", 1)[0]
    elements = []
    in_data = False
    for row in table_rows(arrival):
        if len(row) != 7:
            continue
        if row[-1] == "data path":
            in_data = True
        elif in_data and row[3] in ("IC", "CELL"):
            elements.append({"increment_ns": float(row[1]), "type": row[3],
                             "fanout": int(row[4]), "location": row[5], "element": row[6]})
    result["first_path_elements"] = elements
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--fresh-build", action="store_true",
                        help="Read timing/ from a completed build_at_no_debug run")
    args = parser.parse_args()
    run = args.run.resolve()
    reports = run / ("timing" if args.fresh_build else "reports")
    counts = (reports / "path_counts.txt").read_text().splitlines()
    overlay = run / "overlay/SYSTEM.sdc"
    if args.fresh_build and not all((run / name).is_file() for name in
                                    ("compile-started.txt", "bitstreams.sha256", "timing.log")):
        raise ValueError("Fresh-build receipt is incomplete")
    verified = run / "original-artifacts-verified.log"
    if not args.fresh_build and not verified.is_file():
        raise ValueError("Reference-fit artifact verification receipt is missing")
    result = {"schema": 1, "run_directory": str(run),
              "scope": ("new compiled fitted netlist, frozen source snapshot, no SDC overlay"
                        if args.fresh_build else
                        "reference fitted netlist, frozen SYSTEM.sdc overlay, no compilation"
                        if overlay.exists() else
                        "existing fitted netlist, snapshot constraints, no compilation"),
              "system_sdc_overlay_sha256": sha256(overlay) if overlay.exists() else None,
              "coverage": "bounded top-N reports per selector; not a total path census",
              "closure_claim": False,
              "snapshot_manifest_sha256": sha256(run / "manifest.json"),
              "container_image": (run / "container-image.txt").read_text().strip(),
              "original_artifacts_verification":
                  verified.read_text().splitlines() if verified.exists() else [],
              "corners": {}, "corner_metadata": {}, "report_hashes": {}}
    for line in counts:
        corner, group, kind, count, worst = line.split()
        path = reports / corner / f"{group}_{kind}.rpt"
        parsed = parse_report(path)
        parsed["tool_path_count"] = int(count)
        parsed["tool_worst_slack_ns"] = float(worst) if int(count) else None
        if parsed["reported_paths"] != int(count):
            raise ValueError(f"Path count mismatch: {path}")
        if int(count) and abs(parsed["top_paths"][0]["slack_ns"] - float(worst)) > 0.0001:
            raise ValueError(f"Worst slack mismatch: {path}")
        result["corners"].setdefault(corner, {}).setdefault(kind, {})[group] = parsed
    for corner in result["corners"]:
        check = (reports / corner / "check_timing.rpt").read_text()
        checks = {row[0]: int(row[1]) for row in
                  table_rows(check.split("; No Clock", 1)[0])
                  if len(row) == 2 and row[1].isdigit()}
        no_clocks = collections.Counter()
        for row in table_rows(check):
            if len(row) == 2 and row[1] == "No clock feeds this register's clock port.":
                no_clocks[re.split(r"[|~]", row[0], maxsplit=1)[0]] += 1
        fmax = parse_fmax((reports / corner / "fmax.rpt").read_text())
        result["corner_metadata"][corner] = {
            "check_timing_issues": checks, "unclocked_node_families": dict(no_clocks),
            "fmax_mhz": fmax}
    for path in sorted(reports.rglob("*")):
        if path.is_file():
            result["report_hashes"][str(path.relative_to(reports))] = sha256(path)
    output = args.output or run / "summary.json"
    if output.exists():
        raise FileExistsError(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + "\n")
    for corner, kinds in result["corners"].items():
        for group, value in kinds["setup"].items():
            if value["tool_worst_slack_ns"] is not None and value["tool_worst_slack_ns"] < 0:
                first = value["top_paths"][0]
                print(corner, group, first["slack_ns"],
                      first["from"].rsplit("|", 1)[-1], "->",
                      first["to"].rsplit("|", 1)[-1],
                      f"levels={value['logic_levels']}")
    print(f"AT_50MHZ_SUMMARY {output} (no closure claim)")


if __name__ == "__main__":
    main()
