#!/usr/bin/env python3
"""Check every requested video FF location against the fitted inventory.

This is a placement binding check, not a timing closure or functional proof.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

STATS_PREFIX = ("emu_at:emu|hps_io:hps_io_at|video_calc:video_calc|"
                "at_cdc_snapshot:g_at_cdc.video_stats|")
HDMI_PREFIX = "at_hdmi_output:u_at_hdmi_output|"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def analyze_locations(qsf, inventory, expected_count):
    if expected_count not in (326, 328):
        raise ValueError("Expected count must be 326 or 328")
    locations = {}
    lines = inventory.read_text().splitlines()
    if not lines or lines[0] != "location\tname":
        raise ValueError("Incorrect fitted inventory header")
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) != 2:
            raise ValueError("Malformed fitted inventory row")
        location, name = fields
        if name in locations:
            raise ValueError("Duplicate fitted register name: " + name)
        locations[name] = location

    required = {STATS_PREFIX + f"{bank}[{bit}]"
                for bank in ("payload_q", "dst_data") for bit in range(163)}
    if expected_count == 328:
        required |= {HDMI_PREFIX + name for name in ("scaled_q[25]", "direct_q2[25]")}
    for bank in ("payload_q", "dst_data"):
        observed = {name for name in locations if name.startswith(STATS_PREFIX + bank + "[")}
        expected = {STATS_PREFIX + f"{bank}[{bit}]" for bit in range(163)}
        if observed != expected:
            raise ValueError("Missing, duplicated or changed fitted statistics bank: " + bank)

    requested = {}
    pattern = re.compile(r'^set_location_assignment (FF_X\d+_Y\d+_N\d+) -to "([^"]+)"$')
    for line in qsf.read_text().splitlines():
        line = line.strip()
        if not line.startswith("set_location_assignment FF_"):
            continue
        match = pattern.fullmatch(line)
        if not match:
            raise ValueError("Unsupported FF location assignment syntax: " + line)
        location, name = match.groups()
        if name in requested:
            raise ValueError("Duplicate requested register name: " + name)
        requested[name] = location
    if set(requested) != required:
        raise ValueError("Missing or unexpected requested FF endpoints")
    if len(set(requested.values())) != len(requested):
        raise ValueError("Two requested registers occupy the same FF site")
    applied = []
    for name, expected in sorted(requested.items()):
        actual = locations.get(name)
        if actual != expected:
            raise ValueError(f"Placement did not bind: {name}: requested {expected}, fitted {actual}")
        applied.append({"name": name, "location": actual})
    return {"status": "ALL_REQUESTED_VIDEO_FF_LOCATIONS_APPLIED",
            "scope": "Placement binding only; complete timing and source/functional audits required separately",
            "fitted_registers": len(locations), "assigned_registers": len(applied),
            "qsf_sha256": sha(qsf), "inventory_sha256": sha(inventory),
            "applied": applied}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=Path)
    parser.add_argument("--expect-count", required=True, type=int, choices=(326, 328))
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError("Output already exists: " + str(args.output))
    qsf = args.run / "work/PCAT-286.qsf"
    inventory = args.run / "video-register-placement/register-locations.tsv"
    manifest = json.loads((args.run / "manifest.json").read_text())
    if sha(qsf) != manifest["source_sha256"]["PCAT-286.qsf"]:
        raise ValueError("QSF differs from frozen fit input")
    if not re.search(r"Full Compilation was successful\. 0 errors",
                     (args.run / "compile.log").read_text()):
        raise ValueError("No successful complete physical compilation")
    result = analyze_locations(qsf, inventory, args.expect_count)
    result.update(run_directory=str(args.run), manifest_sha256=sha(args.run / "manifest.json"),
                  checker_sha256=sha(Path(__file__)),
                  extraction_script_sha256=sha(Path(__file__).with_name("report_at_video_register_placement.tcl")))
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(result["status"], result["assigned_registers"])


if __name__ == "__main__":
    main()
