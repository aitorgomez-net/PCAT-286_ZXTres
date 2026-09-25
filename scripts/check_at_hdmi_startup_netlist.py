#!/usr/bin/env python3
"""Check cold scaled-mode startup in a Quartus functional Verilog netlist.

Export the user's fitted database with quartus_eda --simulation --functional=on
--tool=modelsim --format=verilog. This evaluates the actual LUT masks, FF
power-up values and controls of the SYS-domain transmitter controller. For
extended LUTs it evaluates Quartus's exported Boolean equations. It is
not a model of routing delays, the clock mux, or the HDMI electrical interface.
Unsupported atoms/controls fail explicitly instead of assuming a value.
"""
import argparse
import re
from pathlib import Path


def check(path):
    check_text(path.read_text())


def check_text(text):
    prefix = r"\u_at_hdmi_output|"
    components, drivers, ff, equations = {}, {}, {}, {}
    pattern = (r"(dffeas|cyclonev_lcell_comb)\s+"
               r"(\\u_at_hdmi_output\|[^\s]+)\s*\((.*?)\);"
               r"(.*?)// synopsys translate_on")
    for match in re.finditer(pattern, text, re.S):
        kind, name, body, params = match.groups()
        ports = {p: v.strip() for p, v in re.findall(r"\.(\w+)\(([^()]*)\)", body)}
        components[name] = (kind, ports, params)
        if kind == "dffeas":
            power = re.search(r'\.power_up = "(low|high)"', params)
            if not power:
                raise ValueError(f"Missing power-up: {name}")
            ff[ports["q"]] = int(power[1] == "high")
            drivers[ports["q"]] = name
        else:
            drivers[ports["combout"]] = name
            comments = " ".join(line.strip()[2:].strip() for line in body.splitlines()
                                if line.strip().startswith("//"))
            equation = comments.split("=", 1)[1].strip() if "=" in comments else ""
            if ".extended_lut = \"on\"" in params:
                # Quartus exports the Boolean function before its physical
                # input inversions. A 7-input extended LUT cannot be indexed
                # as an ordinary 6-input, 64-bit truth table.
                equations[name] = equation
    # No mode change at boot: direct_video=0, vga_fb=0, UIO idle.
    external = {"gnd": 0, "vcc": 1, "devclrn": 1, "devpor": 1,
                "cfg[10]": 0, "cfg[12]": 0, r"\io_uio~combout": 0}
    control = [name for name, (kind, ports, _) in components.items()
               if kind == "dffeas" and "FPGA_CLK2_50" in ports["clk"]
               and not name.startswith(prefix + "csync_")]
    if not control:
        raise ValueError("No SYS-domain transmitter controller found")
    reset_n = prefix + "switch_reset_q~q"
    select = prefix + "select_direct~q"
    if reset_n not in ff or select not in ff:
        raise ValueError("Expected fitted controller outputs missing")

    def equation_value(equation, memo):
        tokens = re.findall(r"\\[^\s()!&#$]+(?:\s+\[\d+\])?|[()!&#$]|[01]", equation)
        if "".join(tokens).replace(" ", "") != re.sub(r"\s", "", equation):
            raise ValueError(f"Unsupported Boolean equation: {equation}")
        pos = 0

        def parse(min_precedence=0):
            nonlocal pos
            token = tokens[pos]
            pos += 1
            if token == "!":
                left = 1 - parse(4)
            elif token == "(":
                left = parse()
                if tokens[pos] != ")":
                    raise ValueError("Unbalanced Boolean equation")
                pos += 1
            else:
                left = int(token) if token in ("0", "1") else value(token, memo)
            precedence = {"#": 1, "$": 2, "&": 3}
            while pos < len(tokens) and tokens[pos] in precedence and precedence[tokens[pos]] >= min_precedence:
                op = tokens[pos]
                pos += 1
                right = parse(precedence[op] + 1)
                left = {"#": left | right, "$": left ^ right, "&": left & right}[op]
            return left

        result = parse()
        if pos != len(tokens):
            raise ValueError("Trailing Boolean equation tokens")
        return result

    def value(expr, memo):
        expr = expr.strip()
        if expr.startswith("!"):
            return 1 - value(expr[1:], memo)
        if expr in external:
            return external[expr]
        if expr in ff:
            return ff[expr]
        if expr in memo:
            return memo[expr]
        if expr not in drivers:
            raise ValueError(f"Unmodelled controller input: {expr}")
        name = drivers[expr]
        kind, ports, params = components[name]
        if kind != "cyclonev_lcell_comb" or '.shared_arith = "off"' not in params:
            raise ValueError(f"Unsupported combinational atom: {name}")
        if name in equations:
            memo[expr] = equation_value(equations[name], memo)
            return memo[expr]
        if '.extended_lut = "off"' not in params:
            raise ValueError(f"Unsupported LUT mode: {name}")
        mask = re.search(r"\.lut_mask = 64'h([0-9A-Fa-f]+)", params)
        if not mask or any(value(ports[p], memo) for p in ("datag", "cin", "sharein")):
            raise ValueError(f"Unsupported LUT/carry mode: {name}")
        index = sum(value(ports["data" + letter], memo) << i
                    for i, letter in enumerate("abcdef"))
        memo[expr] = (int(mask[1], 16) >> index) & 1
        return memo[expr]

    released = None
    for cycle in range(128):
        next_ff, memo = {}, {}
        for name in control:
            _, p, _ = components[name]
            if not value(p["prn"], memo) or value(p["aload"], memo):
                raise ValueError(f"Unsupported async controller control: {name}")
            q = p["q"]
            if not value(p["clrn"], memo):
                next_ff[q] = 0
            elif value(p["ena"], memo):
                next_ff[q] = (0 if value(p["sclr"], memo) else
                              value(p["asdata"] if value(p["sload"], memo) else p["d"], memo))
        ff.update(next_ff)
        # Cyclone V maps the active-high RTL resets to inverted FFs and CLRN.
        if ff[reset_n] and not ff[select] and released is None:
            released = cycle + 1
    if released is None or not ff[reset_n] or ff[select]:
        raise AssertionError("Fitted HDMI startup stuck: reset remains asserted "
                             "or scaled clock is not selected after 128 SYS edges")
    print(f"AT_HDMI_FITTED_STARTUP_PASS reset_released_sys_edge={released} "
          f"controller_registers={len(control)} extended_lut_equations={len(equations)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("netlist", type=Path)
    args = parser.parse_args()
    check(args.netlist)
