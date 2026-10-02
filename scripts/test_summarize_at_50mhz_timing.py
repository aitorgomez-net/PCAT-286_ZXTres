#!/usr/bin/env python3
"""Focused parser check: Fmax rows with and without a trailing Note."""
import unittest
from summarize_at_50mhz_timing import parse_fmax


class FmaxRows(unittest.TestCase):
    def test_empty_note_and_integer_frequency(self):
        self.assertEqual(parse_fmax("""
; Fmax ; Restricted Fmax ; Clock Name ; Note ;
; 40.35 MHz ; 40.35 MHz ; FPGA_CLK2_50 ; ;
; 50 MHz ; 50 MHz ; integer_clock ; ;
; 864.3 MHz ; 540.54 MHz ; AT_HDMI_TX_SCALED ; pulse width limit ;
"""), {"FPGA_CLK2_50": 40.35, "integer_clock": 50.0, "AT_HDMI_TX_SCALED": 864.3})

    def test_non_data_rows_do_not_become_clocks(self):
        self.assertEqual(parse_fmax("; Fmax Summary ;\n; Fmax ; Restricted Fmax ; Clock Name ; Note ;"), {})


if __name__ == "__main__":
    unittest.main()
