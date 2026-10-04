"""Small parser-only check with independent, synthetic fixed-work CSVs."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TOOL = Path(__file__).resolve().with_name("validate_t286ref.py")
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
OUT = args.output.resolve()
if OUT.exists():
    parser.error("Use a fresh output directory; results cannot be overwritten")
try:
    OUT.relative_to(ROOT)
except ValueError:
    parser.error("Output must stay within the repository")
OUT.mkdir(parents=True)
spec = importlib.util.spec_from_file_location("t286_validator", TOOL)
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


def fixture(mode):
    rows = [
        "meta,version,T286REF2",
        "meta,cpu_contract,REAL_MODE_8086_INSTRUCTIONS_286_TARGET",
        "meta,timer_qualification,NOT_CALIBRATED",
        "meta,timer_divisor,65536",
        "meta,divisor_source,ASSUMED_STANDARD_BIOS",
        "meta,pit_input_hz,1193182_NOMINAL",
        "meta,interrupt_policy,IF_PRESERVED_SHORT_CLI_NO_IRQ_TIMING_CLAIM",
        "meta,window_phase_min,8192",
        "meta,window_phase_max_exclusive,16384",
        "meta,max_sample_ticks,10000",
        "meta,repetitions,7",
        "meta,nominal_mhz,6",
        "meta,code_segment_decimal,4096",
        "meta,aligned_word_offset_decimal,2048",
        f"meta,pit_mode,{mode}",
        f"meta,pit_status_without_out,{52 if mode == 2 else 54}",
        "meta,probe_max_raw_count,65520",
        "meta,probe_observed_raw_zero,0",
        "header_sample,case,kind,rep,loops,status_start,count_start,out_start,phase_start,status_end,count_end,out_end,phase_end,raw_delta,ticks,result_ax,result_bx,result_cx,result_dx,result_di",
        "header_summary,case,kind,loops,min_ticks,median_ticks,max_ticks",
    ]
    for case, duration in (("R0", 500), ("B0", 700), ("M0", 900)):
        for kind in ("baseline", "gross"):
            ticks = []
            for rep in range(1, 8):
                begin = 8192 + rep * 31
                delta = (200 if kind == "baseline" else duration) + rep
                finish = begin + delta
                count_start = (-begin * (1 if mode == 2 else 2)) % 65536
                count_end = (-finish * (1 if mode == 2 else 2)) % 65536
                registers = [4660, 22136, 0, 39612, 57072]
                if kind == "gross" and case == "R0":
                    registers[0:2] = [2484, 22392]
                elif kind == "gross" and case == "M0":
                    registers[0] = 26796
                status = 180 if mode == 2 else 182
                fields = ["sample", case, kind, rep, 256, status, count_start, 1,
                          begin, status, count_end, 1, finish,
                          (count_start - count_end) % 65536, delta] + registers
                rows.append(",".join(map(str, fields)))
                ticks.append(delta)
            rows.append(f"summary,{case},{kind},256,{min(ticks)},{ticks[3]},{max(ticks)}")
    rows.append("result,PASS_RAW_FIXED_WORK")
    return "\r\n".join(rows) + "\r\n"


def change_sample(text, index, value):
    rows = text.splitlines()
    first = next(i for i, row in enumerate(rows) if row.startswith("sample,"))
    fields = rows[first].split(",")
    fields[index] = str(value)
    rows[first] = ",".join(fields)
    return "\r\n".join(rows) + "\r\n"


receipts = {}
for mode in (2, 3):
    text = fixture(mode)
    path = OUT / f"positive-mode{mode}.csv"
    path.write_bytes(text.encode("ascii"))
    receipt = validator.validate_csv(text, "6")
    assert receipt["sample_count"] == 42 and receipt["summary_count"] == 6
    assert receipt["timer_calibrated"] is False and all(receipt["controls"].values())
    result = subprocess.run([sys.executable, "-B", str(TOOL), str(path),
                             "--expected-nominal", "6"], text=True, capture_output=True)
    (OUT / f"cli-mode{mode}.stdout.json").write_text(result.stdout, encoding="utf-8")
    (OUT / f"cli-mode{mode}.stderr.log").write_text(result.stderr, encoding="utf-8")
    assert result.returncode == 0
    receipts[f"positive_mode{mode}"] = "PASS"
good = fixture(3)
first_sample = next(row for row in good.splitlines() if row.startswith("sample,"))
first_fields = first_sample.split(",")
zero = change_sample(good, 10, first_fields[6])
zero = change_sample(zero, 12, first_fields[8])
zero = change_sample(zero, 13, 0)
zero = change_sample(zero, 14, 0)
negative = {
    "missing_sample": good.replace(first_sample + "\r\n", "", 1),
    "duplicate_sample": good.replace(first_sample, first_sample + "\r\n" + first_sample, 1),
    "corrupt_ticks": change_sample(good, 14, 202),
    "truncated_pass": good.replace("PASS_RAW_FIXED_WORK", "PASS_RAW_FIX"),
    "truncated_newline": good.rstrip("\r\n"),
    "wrong_signature": change_sample(good, 15, 4661),
    "out_status_disagree": change_sample(good, 7, 0),
    "wrong_summary": good.replace("summary,R0,baseline,256,201,204,207", "summary,R0,baseline,256,201,205,207"),
    "claimed_calibration": good.replace("NOT_CALIBRATED", "CALIBRATED"),
    "reject_result": good.replace("PASS_RAW_FIXED_WORK", "REJECT_SAMPLE_WINDOW_OR_TIMER_STATUS"),
    "unsupported_mode": good.replace("meta,pit_mode,3", "meta,pit_mode,1"),
    "zero_interval": zero,
}
for name, text in negative.items():
    path = OUT / (name + ".csv")
    path.write_bytes(text.encode("ascii"))
    try:
        validator.validate_csv(text, "6")
    except ValueError as error:
        receipts[name] = {"status": "REJECT_EXPECTED_PASS", "reason": str(error)}
    else:
        raise AssertionError("Negative accepted: " + name)
try:
    validator.validate_csv(good, "12.5")
except ValueError as error:
    receipts["wrong_requested_nominal"] = {"status": "REJECT_EXPECTED_PASS", "reason": str(error)}
else:
    raise AssertionError("Wrong nominal accepted")
hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
          for p in (TOOL, Path(__file__), *sorted(OUT.glob("*.csv")), *sorted(OUT.glob("*.stdout.json")), *sorted(OUT.glob("*.stderr.log")))}
(OUT / "receipt.json").write_text(json.dumps({
    "status": "T286REF_PARSER_DIRECTED_PASS", "cases": receipts, "sha256": hashes,
    "scope": "Synthetic mode2/mode3 parser/API/CLI checks only; no DOS or emulator runtime",
}, indent=2) + "\n", encoding="utf-8")
print(json.dumps(receipts, indent=2))
