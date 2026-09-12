`timescale 1ns/1ps
module spk286_at_pit_clock_tb;
 reg clk=0,reset=1; wire pit; always #10 clk=~clk;
 spk286_at_pit_clock dut(.clk(clk),.reset(reset),.counter_clock(pit));
 integer i,edges=0,last=0; reg prior=0;
 initial begin
   repeat(3) @(negedge clk); reset=0;
   for(i=1;i<=500000;i++) begin
     @(negedge clk);
     if(pit!==prior) begin
       if(last!=0 && i-last!=20 && i-last!=21) $fatal(1,"PIT_HALF_PERIOD %0d",i-last);
       edges++; last=i; prior=pit;
     end
   end
   if(edges!=23863) $fatal(1,"PIT_FREQUENCY edges=%0d",edges);
   $display("AT_PIT_CLOCK_PASS cycles=500000 edges=%0d half_period=20_or_21",edges); $finish;
 end
endmodule
