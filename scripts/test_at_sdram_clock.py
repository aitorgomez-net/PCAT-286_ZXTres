#!/usr/bin/env python3
"""Check the actual clock forwarding instance using Quartus altera_mf.v."""
from pathlib import Path
import argparse,re,subprocess,hashlib,json
root=Path(__file__).resolve().parents[1]
ap=argparse.ArgumentParser(description=__doc__)
ap.add_argument('output',type=Path)
ap.add_argument('altera_mf',type=Path,help='Official Quartus eda/sim_lib/altera_mf.v')
args=ap.parse_args()
out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
library=args.altera_mf.resolve()
assert b'module altddio_out (' in library.read_bytes(),'Official primitive not found'
top=(root/'PCAT-286.sv').read_text()
instance=re.search(r'    altddio_out #\(.*?\) sdram_clock_ddr \(.*?\n    \);',top,re.S).group(0)
tb='''`timescale 1ns/1ps
module tb;
reg CLK_50M=0;
wire SDRAM_CLK;
always #10 CLK_50M=~CLK_50M;
'''+instance+'''
integer edges=0;
initial begin
  repeat(2000) begin
    @(CLK_50M); #0.001;
    if(SDRAM_CLK!==CLK_50M) $fatal(1,"Forwarding mismatch edge %d",edges);
    edges=edges+1;
    #4;
    if(SDRAM_CLK!==CLK_50M) $fatal(1,"Pulse instability");
  end
  $display("SDRAM_DDIO_WAVEFORM_PASS edges=%d period_ns=20 phase_ns=0",edges);
  $finish;
end
endmodule
'''
(out/'tb.sv').write_text(tb)
cmd=['iverilog','-g2012','-s','tb','-o',str(out/'test.vvp'),str(library),str(out/'tb.sv')]
result=subprocess.run(cmd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
(out/'build.log').write_text(result.stdout)
assert result.returncode==0,result.stdout[-2000:]
result=subprocess.run(['vvp',str(out/'test.vvp')],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
(out/'run.log').write_text(result.stdout)
assert result.returncode==0 and 'SDRAM_DDIO_WAVEFORM_PASS' in result.stdout,result.stdout
print(result.stdout)
(out/'receipt.json').write_text(json.dumps({'status':'OFFICIAL_LIBRARY_FORWARDING_WAVEFORM_PASS','edges':2000,'period_ns':20,'phase_ns':0,'scope':'actual PCAT instance, official Quartus altera_mf.v; functional waveform, not physical hold signoff','sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (library,out/'tb.sv',out/'build.log',out/'run.log',root/'PCAT-286.sv',Path(__file__))}},indent=2)+'\n')
