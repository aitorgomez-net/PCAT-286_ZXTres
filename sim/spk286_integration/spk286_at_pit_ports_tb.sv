`timescale 1ns/1ps
module spk286_at_pit_ports_tb;
  reg clk=0, reset=1, tick=0, valid=0, command=0, wr=0;
  reg [23:0] addr=0; reg [1:0] be=0; reg [15:0] dout=0;
  wire pa,pr,pv,sa,sr,sv; wire [15:0] pd,sd; wire [2:0] outs;
  wire pf,sf,gate2,spk,pending; wire [7:0] portb;
  reg parity=0,channel=0;
  wire accept=pa|sa, ready=pr|sr, rdvalid=pv|sv;
  wire [15:0] din=pr?pd:sd;
  always #10 clk=~clk;
  spk286_at_pit pit(.clk(clk),.reset(reset),.counter_clock(tick),.counter_2_gate(gate2),
    .request_valid(valid),.request_command_valid(command),.request_write(wr),.request_io(1'b1),
    .request_address(addr),.request_byte_enable(be),.request_data_out(dout),
    .request_accept(pa),.request_ready(pr),.request_read_data(pd),.request_read_data_valid(pv),
    .counter_out(outs),.irq0(),.protocol_error(pf));
  spk286_at_system_control sys(.clk(clk),.reset(reset),
    .request_valid(valid),.request_command_valid(command),.request_write(wr),.request_io(1'b1),
    .request_address(addr),.request_byte_enable(be),.request_data_out(dout),
    .request_accept(sa),.request_ready(sr),.request_read_data(sd),.request_read_data_valid(sv),
    .timer_1_out(outs[1]),.timer_2_out(outs[2]),.parity_event(parity),.channel_check_event(channel),
    .timer_2_gate(gate2),.speaker_enable(spk),.check_pending(pending),.port_b(portb),.protocol_error(sf));
  task automatic access(input bit writeop, input [15:0] port, input [7:0] data, output [7:0] result);
    integer waits;
    begin
      @(negedge clk); valid=1; command=1; wr=writeop; addr={8'b0,port};
      be=port[0]?2'b10:2'b01; dout=port[0]?{data,8'h00}:{8'h00,data};
      #1; if(accept !== 1'b1) $fatal(1,"PORT_ACCEPT %h",port);
      @(negedge clk); command=0;
      // Accepted payload must be retained by the target during wait states.
      addr=24'hffffff; dout=16'hdead; be=0;
      waits=0;
      while(ready !== 1'b1 && waits<16) begin @(negedge clk); waits++; end
      if(ready !== 1'b1 || rdvalid !== !writeop) $fatal(1,"PORT_READY %h",port);
      result=port[0]?din[15:8]:din[7:0];
      if(!writeop && (port[0] ? din[7:0]!==0 : din[15:8]!==0)) $fatal(1,"PORT_LANE");
      valid=0; @(negedge clk);
    end
  endtask
  task automatic put(input [15:0] port,input [7:0] data);
    reg [7:0] unused; access(1,port,data,unused);
  endtask
  task automatic ticks(input integer n);
    repeat(n) begin
      @(negedge clk); tick=1; repeat(3) @(negedge clk);
      tick=0; repeat(3) @(negedge clk);
    end
  endtask
  task automatic count_read(input integer ch, output [15:0] val);
    reg [7:0] lo,hi;
    begin
      put(16'h43,8'(ch<<6));
      access(0,16'(16'h40+ch),0,lo);
      access(0,16'(16'h40+ch),0,hi); val={hi,lo};
    end
  endtask
  reg [15:0] value, prior;
  reg [7:0] lo,hi,b;
  integer ch;
  initial begin
    repeat(4) @(negedge clk); reset=0;
    if(pf !== 0 || sf !== 0 || pending !== 0) $fatal(1,"RESET");
    access(0,16'h61,0,b); if(b[7:6]!==0) $fatal(1,"FALSE_PARITY");
    put(16'h61,8'h03); if(!gate2 || !spk) $fatal(1,"PORT61_OUTPUTS");
    for(ch=0;ch<3;ch++) begin
      // Mode 0, load LSB/MSB, all channels must decrement identically.
      put(16'h43,8'((ch<<6)|8'h30));
      put(16'(16'h40+ch),8'h34); put(16'(16'h40+ch),8'h12);
      ticks(1); count_read(ch,value);
      if(value!==16'h1234) $fatal(1,"LOAD ch=%0d count=%h",ch,value);
      // AT software (including Phoenix's F000:9447 wait helper) reads status
      // through 8254 read-back. This must not consume the next count byte.
      put(16'h43,8'(8'he0 | (2<<ch)));
      access(0,16'(16'h40+ch),0,b);
      if(b!==8'h30) $fatal(1,"PIT_READBACK_STATUS ch=%0d got=%h expected=30",ch,b);
      count_read(ch,value);
      if(value!==16'h1234) $fatal(1,"PIT_STATUS_CHANGED_COUNT_PHASE ch=%0d count=%h",ch,value);
      ticks(10); count_read(ch,value);
      if(value!==16'h122a) $fatal(1,"DECREMENT ch=%0d count=%h",ch,value);
      put(16'h43,8'(ch<<6));
      access(0,16'(16'h40+ch),0,lo); ticks(300);
      access(0,16'(16'h40+ch),0,hi);
      if({hi,lo}!==16'h122a) $fatal(1,"LATCH_TORN ch=%0d value=%h",ch,{hi,lo});
      count_read(ch,value); if(value!==16'h10fe) $fatal(1,"LATCH_STOPPED_COUNT ch=%0d value=%h",ch,value);
    end
    count_read(2,prior); put(16'h61,0); ticks(20); count_read(2,value);
    if(value!==prior) $fatal(1,"GATE2_STOP");
    put(16'h61,1); ticks(5); count_read(2,value);
    if(value!==prior-16'd5) $fatal(1,"GATE2_RESUME count=%h expected=%h",value,prior-16'd5);
    // Simultaneous count/status latch for all counters. Repeated requests
    // must preserve the first snapshot while the underlying counters run.
    for(ch=0;ch<3;ch++) begin
      put(16'h43,8'((ch<<6)|8'h30));
      put(16'(16'h40+ch),8'h34); put(16'(16'h40+ch),8'h12);
    end
    ticks(1); put(16'h43,8'hce); ticks(10); put(16'h43,8'hce);
    for(ch=0;ch<3;ch++) begin
      access(0,16'(16'h40+ch),0,b);
      if(b!==8'h30) $fatal(1,"READBACK_MULTI_STATUS ch=%0d data=%h",ch,b);
      access(0,16'(16'h40+ch),0,lo); access(0,16'(16'h40+ch),0,hi);
      if({hi,lo}!==16'h1234) $fatal(1,"READBACK_MULTI_COUNT ch=%0d data=%h",ch,{hi,lo});
      count_read(ch,value);
      if(value!==16'h122a) $fatal(1,"READBACK_COUNTER_STOPPED");
    end
    // A status read between LSB and MSB must not lose the pending MSB.
    put(16'h43,0); access(0,16'h40,0,lo);
    put(16'h43,8'he2); access(0,16'h40,0,b);
    access(0,16'h40,0,hi);
    if(b!==8'h30 || {hi,lo}!==16'h122a) $fatal(1,"READBACK_MID_PAIR");
    // Count-only read-back must not insert a status byte.
    put(16'h43,8'hd2); ticks(10);
    access(0,16'h40,0,lo); access(0,16'h40,0,hi);
    if({hi,lo}!==16'h122a) $fatal(1,"READBACK_COUNT_ONLY");
    // Status and its null-count bit are snapshots, independent of CE changes.
    put(16'h43,8'h36); put(16'h43,8'he2);
    put(16'h40,8'h20); put(16'h40,0); ticks(1);
    put(16'h43,8'he2); access(0,16'h40,0,b);
    if(b!==8'hf6) $fatal(1,"READBACK_STATUS_OVERWRITTEN data=%h",b);
    put(16'h43,8'he2); access(0,16'h40,0,b);
    if(b!==8'hb6) $fatal(1,"READBACK_LOADED_STATUS data=%h",b);
    // Updating CR in mode3 takes effect at reload; the first byte is not a
    // complete new count. A read-back command itself never changes null count.
    put(16'h40,8'h40); put(16'h43,8'he2); access(0,16'h40,0,b);
    if(b[6]!==0) $fatal(1,"READBACK_PARTIAL_WRITE_NULL");
    put(16'h40,0); put(16'h43,8'he2); access(0,16'h40,0,b);
    if(b[6]!==1) $fatal(1,"READBACK_NEW_COUNT_NULL");
    ticks(16); put(16'h43,8'he2); access(0,16'h40,0,b);
    if(b[6]!==0 || b[7]!==0) $fatal(1,"READBACK_RELOAD_OUT data=%h",b);
    // Reprogramming the same RW format restarts the byte phases and releases
    // old count/status latches, just as a new 8254 control word requires.
    put(16'h43,8'hc2); access(0,16'h40,0,b); access(0,16'h40,0,lo);
    put(16'h43,8'h30); put(16'h40,8'h78); put(16'h40,8'h56);
    ticks(1); count_read(0,value);
    if(value!==16'h5678) $fatal(1,"READBACK_REPROGRAM_PHASE count=%h",value);
    // Reload zero means 65536, not a stopped/zero counter.
    put(16'h43,8'h74); put(16'h41,0); put(16'h41,0);
    ticks(3); count_read(1,value);
    if(value!==16'hfffe) $fatal(1,"ZERO_RELOAD value=%h",value);
    // Real OUT1 transitions, not read operations, drive refresh toggle.
    put(16'h43,8'h74); put(16'h41,4); put(16'h41,0);
    ticks(1); b=portb; ticks(4);
    if(portb[4]===b[4]) $fatal(1,"REFRESH_TOGGLE");
    if(portb[5]!==outs[2]) $fatal(1,"OUT2_READ");
    parity=1; repeat(2) @(negedge clk); parity=0;
    access(0,16'h61,0,b); if(b[7:6]!==2'b10 || !pending) $fatal(1,"PARITY_LATCH");
    put(16'h61,8'h05); if(pending) $fatal(1,"PARITY_CLEAR");
    parity=1; ticks(3); if(pending) $fatal(1,"PARITY_DISABLE");
    parity=0; put(16'h61,1);
    channel=1; ticks(1); channel=0;
    access(0,16'h61,0,b); if(b[7:6]!==2'b01 || !pending) $fatal(1,"CHANNEL_LATCH");
    put(16'h61,8'h09); if(pending) $fatal(1,"CHANNEL_CLEAR");
    put(16'h61,8'hf1); if(portb[3:0]!==1) $fatal(1,"UPPER_BITS_WRITABLE");
    if(pf !== 0 || sf !== 0) $fatal(1,"PROTOCOL_ERROR");
    @(negedge clk); valid=1; command=1; addr=24'h61; be=2'b01;
    @(negedge clk); if(sa || sr || sf!==1'b1) $fatal(1,"SYSTEM_INVALID_LANE");
    addr=24'h40; be=2'b10;
    @(negedge clk); if(pa || pr || pf!==1'b1) $fatal(1,"PIT_INVALID_LANE");
    valid=0; command=0; reset=1;
    repeat(3) @(negedge clk);
    if(pf!==0 || sf!==0 || pending!==0) $fatal(1,"SYSTEM_WARM_RESET");
    $display("AT_PIT_PORTS_PASS channels=3 latch=stable gate2=stop_resume reload0=65536 parity=injected_and_cleared");
    $finish;
  end
  initial begin #5000000; $fatal(1,"WATCHDOG"); end
endmodule
