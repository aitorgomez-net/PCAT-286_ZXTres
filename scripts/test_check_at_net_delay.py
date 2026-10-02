#!/usr/bin/env python3
"""Small parser rejection checks; no Quartus compilation."""
import unittest
from check_at_net_delay import analyze_report


def report(slacks=(0.200, 0.100, 0.300)):
    rows = [f"; set_net_delay ; {min(slacks):.3f} ; 1.000 ; "
            f"{1.0-min(slacks):.3f} ; source ; target ; max ;"]
    for bit, slack in enumerate(slacks):
        rows.append(f"; -- ; {slack:.3f} ; 1.000 ; {1.0-slack:.3f} ; "
                    f"chip|video_stats|payload_q[{bit}] ; "
                    f"chip|video_stats|dst_data[{bit}] ; max ;")
    return "\n".join(rows)


class NetDelayAuditTests(unittest.TestCase):
    def test_complete_positive(self):
        result = analyze_report(report(), 1.0, 3)
        self.assertEqual(result["edge_count"], 3)
        self.assertEqual(result["violated_edges"], 0)

    def test_negative_is_recorded(self):
        result = analyze_report(report((0.1, -0.2, 0.3)), 1.0, 3)
        self.assertEqual(result["violated_edges"], 1)
        self.assertEqual(result["worst_slack_ns"], -0.2)

    def test_missing_edge_rejected(self):
        with self.assertRaises(ValueError):
            analyze_report(report().rsplit("\n", 1)[0], 1.0, 3)

    def test_duplicate_edge_rejected(self):
        with self.assertRaises(ValueError):
            analyze_report(report().replace("[2]", "[1]"), 1.0, 3)

    def test_wrong_bit_rejected(self):
        with self.assertRaises(ValueError):
            analyze_report(report().replace("dst_data[2]", "dst_data[1]"), 1.0, 3)

    def test_weakened_budget_rejected(self):
        with self.assertRaises(ValueError):
            analyze_report(report().replace("1.000", "2.000"), 1.0, 3)

    def test_inconsistent_arithmetic_rejected(self):
        with self.assertRaises(ValueError):
            analyze_report(report().replace("0.700", "0.800"), 1.0, 3)

    def test_optimistic_summary_rejected(self):
        with self.assertRaises(ValueError):
            analyze_report(report().replace("0.100 ; 1.000 ; 0.900 ; source",
                                            "0.200 ; 1.000 ; 0.800 ; source"), 1.0, 3)


if __name__ == "__main__":
    unittest.main()
