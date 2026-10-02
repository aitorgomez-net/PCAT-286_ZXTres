#!/usr/bin/env python3
"""Directed controls for FF binding checks, using a real fitted inventory."""
import argparse
import hashlib
import json
from pathlib import Path

from check_at_video_register_placement import (
    HDMI_PREFIX, STATS_PREFIX, analyze_locations,
)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inventory", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError("Output already exists")
    args.output.mkdir(parents=True)
    original_sha256 = sha(args.inventory)
    original = args.inventory.read_text()
    rows = original.splitlines()
    locations = {name: loc for loc, name in (line.split("\t") for line in rows[1:])}
    names = sorted(STATS_PREFIX + f"{bank}[{bit}]"
                   for bank in ("payload_q", "dst_data") for bit in range(163))
    lines = [f'set_location_assignment {locations[name]} -to "{name}"' for name in names]
    qsf = args.output / "requested-known-fitted-locations.qsf"
    qsf.write_text("\n".join(lines) + "\n")
    results = []

    def check(label, candidate_qsf, candidate_inventory, count, expected_error=None):
        try:
            result = analyze_locations(candidate_qsf, candidate_inventory, count)
        except ValueError as error:
            if expected_error is None or expected_error not in str(error):
                raise
            results.append({"case": label, "status": "EXPECTED_REJECTION", "reason": str(error)})
        else:
            if expected_error is not None:
                raise ValueError("Mutation accepted: " + label)
            if result["assigned_registers"] != count:
                raise ValueError("Wrong successful assignment count")
            results.append({"case": label, "status": "KNOWN_FITTED_LOCATIONS_MATCH", "count": count})

    check("known_326", qsf, args.inventory, 326)
    plus = args.output / "requested-known-fitted-locations-328.qsf"
    plus.write_text(qsf.read_text() + "".join(
        f'set_location_assignment {locations[HDMI_PREFIX + name]} -to "{HDMI_PREFIX + name}"\n'
        for name in ("scaled_q[25]", "direct_q2[25]")))
    check("known_328", plus, args.inventory, 328)

    changes = {
        "wrong_site": ([lines[0].replace(locations[names[0]], "FF_X0_Y0_N1")] + lines[1:],
                       "Placement did not bind"),
        "missing_request": (lines[1:], "Missing or unexpected requested"),
        "duplicate_request": (lines + [lines[0]], "Duplicate requested"),
        "foreign_request": ([lines[0].replace(names[0], "unrelated:node|q[0]")] + lines[1:],
                            "Missing or unexpected requested"),
        "duplicate_site": ([lines[0], lines[1].replace(locations[names[1]], locations[names[0]])]
                           + lines[2:], "same FF site"),
        "unquoted_request": ([lines[0].replace('"', '')] + lines[1:], "Unsupported FF"),
    }
    for label, (candidate, error) in changes.items():
        path = args.output / (label + ".qsf")
        path.write_text("\n".join(candidate) + "\n")
        check(label, path, args.inventory, 326, error)
    for label, candidate, error in (
        ("missing_fitted", [row for row in rows if not row.endswith("\t" + names[0])],
         "changed fitted statistics bank"),
        ("duplicate_fitted", rows + [next(row for row in rows if row.endswith("\t" + names[0]))],
         "Duplicate fitted register"),
        ("malformed_inventory", rows + ["invalid\trow\textra"], "Malformed fitted inventory"),
    ):
        path = args.output / (label + ".tsv")
        path.write_text("\n".join(candidate) + "\n")
        check(label, qsf, path, 326, error)
    if sha(args.inventory) != original_sha256:
        raise ValueError("Original fitted inventory changed")
    receipt = {"status": "PLACEMENT_BINDING_CONTROLS_PASS", "cases": results,
               "scope": "Known baseline FF locations plus rejection mutations; not a newly placed fit or timing closure",
               "inventory_sha256": sha(args.inventory),
               "checker_sha256": sha(Path(__file__).with_name("check_at_video_register_placement.py")),
               "extractor_sha256": sha(Path(__file__).with_name("report_at_video_register_placement.tcl")),
               "runner_sha256": sha(Path(__file__))}
    (args.output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(receipt["status"], "cases=" + str(len(results)))


if __name__ == "__main__":
    main()
