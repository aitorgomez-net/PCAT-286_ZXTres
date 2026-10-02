"""Compare architectural work while allowing speculative code-read variation."""
import argparse
from pathlib import Path
import re

def read_log(path):
    rows=[dict(field.split('=',1) for field in line.split()[1:])
          for line in path.read_text().splitlines() if line.startswith('AT_MEMORY_PERF_PASS ')]
    assert len(rows)==1, 'Require exactly one completed workload'
    row=rows[0]
    for key in ('cycles','retired','reads','data_reads','code_reads','other_reads','writes','sdram_writes'):
        assert re.fullmatch(r'[0-9]+',row[key]), key
        row[key]=int(row[key])
    for key,length in (('gpr',32),('flags',4),('cs',4),('ip',4),('memory',8)):
        assert re.fullmatch('[0-9a-fA-F]{'+str(length)+'}',row[key]), key
        row[key]=row[key].lower()
    assert row['reads']==row['data_reads']+row['code_reads']+row['other_reads']
    assert row['retired']>0 and row['cycles']>0
    return row

def compare(before,after,physical_writes=False):
    for key in ('retired','data_reads','other_reads','writes','gpr','flags','cs','ip','memory'):
        assert before[key]==after[key], 'Changed architectural work/state: '+key
    if physical_writes:
        assert before['sdram_writes']==after['sdram_writes'], 'Changed physical stores'
    assert 0<after['cycles']<before['cycles'], 'No cycle reduction'
    return before['cycles']/after['cycles']

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('baseline',type=Path); p.add_argument('candidate',type=Path)
    p.add_argument('--physical-writes',action='store_true')
    a=p.parse_args(); before,after=read_log(a.baseline),read_log(a.candidate)
    speedup=compare(before,after,a.physical_writes)
    print(f'AT_MEMORY_PERF_COMPARISON_PASS speedup={speedup:.3f}x retired={after["retired"]} data_reads={after["data_reads"]} writes={after["writes"]} memory={after["memory"]} code_reads={before["code_reads"]}->{after["code_reads"]}')

if __name__=='__main__': main()
