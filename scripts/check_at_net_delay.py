#!/usr/bin/env python3
"""Audit every fitted edge of the bounded 163-bit video-statistics transfer."""
import argparse
import hashlib
import json
from pathlib import Path
import re


CORNERS = ("7_slow_1100mv_100c", "7_slow_1100mv_-40c",
           "MIN_fast_1100mv_100c", "MIN_fast_1100mv_-40c")


def analyze_report(text, budget, width=163):
    commands, edges = [], []
    for line in text.splitlines():
        if not line.startswith(";"):
            continue
        cells = [cell.strip() for cell in line.strip("; ").split(";")]
        if len(cells) != 7 or cells[0] not in ("set_net_delay", "--"):
            continue
        if cells[6] != "max" or abs(float(cells[2]) - budget) > 0.0001:
            raise ValueError("Unexpected net bound or analysis type")
        slack, required, actual = map(float, cells[1:4])
        if abs(required - actual - slack) > 0.002:
            raise ValueError("Inconsistent fitted net-delay arithmetic")
        record = {"slack_ns": slack, "required_ns": required, "actual_ns": actual,
                  "from": cells[4], "to": cells[5]}
        if cells[0] == "set_net_delay":
            commands.append(record)
        else:
            source = re.search(r"\|payload_q\[(\d+)\]$", cells[4])
            target = re.search(r"\|dst_data\[(\d+)\]$", cells[5])
            if not source or not target or source[1] != target[1]:
                raise ValueError("Unexpected source/target bit in bounded transfer")
            record["bit"] = int(source[1])
            edges.append(record)
    if len(commands) != 1 or len(edges) != width:
        raise ValueError("Incomplete or ambiguous net-delay report")
    if sorted(edge["bit"] for edge in edges) != list(range(width)):
        raise ValueError("Missing or duplicate fitted payload bit")
    worst = min(edge["slack_ns"] for edge in edges)
    if abs(commands[0]["slack_ns"] - worst) > 0.0001:
        raise ValueError("Command summary does not describe the worst fitted edge")
    return {"edge_count": len(edges), "worst_slack_ns": worst,
            "maximum_actual_ns": max(edge["actual_ns"] for edge in edges),
            "violated_edges": sum(edge["slack_ns"] < 0 for edge in edges),
            "edges": edges}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", type=Path)
    parser.add_argument("--expected-budget", type=float, default=1.0)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.expected_budget <= 0:
        raise ValueError("The expected physical delay budget must be positive")
    counts = dict(line.split("=", 1) for line in
                  (args.reports / "collections.txt").read_text().splitlines())
    if counts != {"video_stats_payload": "163", "video_stats_capture": "163"}:
        raise ValueError("Fitted transfer collections do not contain all 163 bits")
    result = {"schema": 1, "scope": "All edges of the fitted video_stats payload",
              "expected_budget_ns": args.expected_budget, "corners": {},
              "hashes": {}, "machine_closure_claim": False}
    for corner in CORNERS:
        report = args.reports / f"{corner}_net_delay.rpt"
        result["corners"][corner] = analyze_report(report.read_text(), args.expected_budget)
        result["hashes"][report.name] = hashlib.sha256(report.read_bytes()).hexdigest()
    passed = all(corner["violated_edges"] == 0 for corner in result["corners"].values())
    result["status"] = "PASS" if passed else "FAIL"
    if args.output.exists():
        raise FileExistsError(args.output)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    for name, corner in result["corners"].items():
        print(name, "edges=" + str(corner["edge_count"]),
              "worst=" + str(corner["worst_slack_ns"]),
              "violated=" + str(corner["violated_edges"]))
    print("AT_NET_DELAY_" + result["status"])
    raise SystemExit(0 if passed else 1)


if __name__ == "__main__":
    main()
