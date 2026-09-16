#!/usr/bin/env python3
"""Check actual PLL-adjuster VHDL signals, including clock/edge isolation."""
from pathlib import Path
import sys

path = Path(sys.argv[1])
scope, names, values = [], {}, {}
prefix = 'at_cdc_vhdl_tb.'
checks = edges = delays = 0

def verify(before, after, time):
    global checks, edges, delays
    def v(name, old=False):
        return (before if old else after).get(prefix + name, 'U')
    def p(name, old=False):
        return v('pll.' + name, old)
    if time == 0:
        return
    assert p('i_clk') == v('i_clk'), f'Gated/spurious PLL input clock at {time}'
    if v('clk', True) == '0' and v('clk') == '1' and p('reset_local_na', True) == '1':
        checks += 1
        if p('cfg_mgmt_sync', True) == '1':
            assert p('ivss') == p('ivss_meta', True), 'Input window bypassed meta stage'
            assert p('ovss') == p('ovss_meta', True), 'Output window bypassed meta stage'
            rise = p('ivss', True) == '1' and p('ivss2', True) == '0'
            expected = str(int(p('itog', True)) ^ int(rise))
            assert p('itog') == expected, 'Input-window event duplicated/lost'
            edges += int(rise)
        else:
            assert p('itog') == '0' and p('otog') == '0', 'Measurements not re-primed'
    if p('i_vss_delay') != p('i_vss_delay', True) and p('cfg_video_sync', True) == '1' and p('video_reset_sync', True) == '1':
        assert v('i_clk', True) == '0' and v('i_clk') == '1', 'Delay changed outside video clock'
        assert int(p('i_delay', True), 2) == 4 * int(p('i_line', True), 2), 'Four-line delay changed'
        delays += 1

with path.open() as stream:
    for line in stream:
        parts = line.split()
        if not parts:
            continue
        if parts[0] == '$scope':
            scope.append(parts[2])
        elif parts[0] == '$upscope':
            scope.pop()
        elif parts[0] == '$var':
            names[parts[3]] = '.'.join(scope + [parts[4]])
        elif parts[0] == '$enddefinitions':
            break
    before, time = {}, 0
    for line in stream:
        line = line.strip()
        if not line:
            continue
        if line[0] == '#':
            verify(before, values, time)
            before = values.copy()
            time = int(line[1:])
        elif line[0] in 'bB':
            value, key = line[1:].split()
            values[names[key]] = value
        elif line[0] in '01xXzZuU':
            values[names[line[1:]]] = line[0]
    verify(before, values, time)
assert checks > 1000 and edges >= 10 and delays >= 10, (checks, edges, delays)
print(f'AT_PLL_CDC_PASS sample_checks={checks} input_events={edges} four_line_events={delays}')
