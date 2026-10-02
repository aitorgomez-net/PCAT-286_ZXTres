`timescale 1ns/1ps
module spk286_event_arbitration_tb;
    logic clk=0, reset=1, cancel=0, enable=1;
    logic protected_mode=0, delivery_commit=0, intr=0, nmi=0, ss_load=0;
    logic repeat_boundary=0, repeat_stepped=0;
    logic instruction_start=0, opcode_dispatch=0, instruction_active=0, retired=0;
    logic [7:0] opcode=8'hFA;
    logic [15:0] ip=16'h1234, cs=16'h1000, flags=16'h0102;
    logic fault_request=0, fault_new_task=0, fault_error_valid=0;
    logic [7:0] fault_vector=13;
    logic [15:0] fault_error_code=0;
    logic software_request=0, halt_request=0, dispatch_ready=0, ack_done=0;
    logic [7:0] software_vector=3, ack_vector=8'h42;
    wire event_active, cancel_operation, dispatch, event_request;
    wire event_completed, event_software, event_external, event_error_valid, event_needs_ack;
    wire [7:0] event_vector;
    wire [15:0] event_ip, event_cs, event_flags, event_error_code, instruction_ip;
    wire halted, shutdown, nmi_pending, nmi_blocked, sti_shadow, ss_shadow;
    wire [2:0] event_kind;
    integer checks=0;
    spk286_events dut(.*);
    task automatic check(input logic condition, input string message);
        checks=checks+1;
        if(condition!==1'b1) $fatal(1,"%s vector=%0d kind=%0d ip=%h",message,event_vector,event_kind,event_ip);
    endtask
    task automatic tick;
        #5; clk=1; #5; clk=0; #1;
    endtask
    task automatic clear;
        reset=1; enable=1; instruction_start=0; instruction_active=0;
        retired=0; fault_request=0; ip=16'h1234; flags=16'h0102;
        tick(); reset=0;
        check(!event_active && !event_request && !shutdown,"reset event arbitration");
    endtask
    initial begin
        // The already completed instruction owes #1. A fault demanding the
        // next opcode is separate, including after execution is paused.
        for(integer paused=0;paused<2;paused=paused+1) begin
            clear(); instruction_start=1; instruction_active=1; tick();
            instruction_start=0; ip=16'h1235; retired=1; tick();
            retired=0; instruction_active=0; fault_request=1;
            if(paused!=0) begin
                enable=0; repeat(4) tick();
                check(!event_request && !event_active,"pause retains event without delivery");
                enable=1;
            end
            #1; check(event_request,"owed trap requested at boundary"); tick();
            check(event_active && event_vector==1 && event_kind==2,
                  "owed trap precedes next-opcode demand fault");
            check(event_ip==16'h1235 && event_cs==cs && event_flags==flags && !event_needs_ack,
                  "owed trap preserves completed boundary context");
        end
        // Without a completed instruction's owed trap, a demanded fault is
        // still delivered, with the next opcode's current boundary IP.
        clear(); flags=2; ip=16'h5678; fault_request=1; #1;
        check(event_request,"unopposed next-opcode demand fault requested"); tick();
        check(event_active && event_vector==13 && event_kind==1 && event_ip==16'h5678,
              "unopposed next-opcode demand fault context");
        // A fault of an active instruction saves its own start and creates
        // no false retirement or new owed trap.
        clear(); instruction_active=1; instruction_start=1; tick();
        instruction_start=0; ip=16'h1237; fault_request=1; #1;
        check(event_request,"active instruction fault requested"); tick();
        check(event_active && event_vector==13 && event_kind==1 && event_ip==16'h1234,
              "active instruction fault preserves instruction start");
        $display("EVENT_ARBITRATION PASS: %0d checks; owed boundary trap and demanded/active faults",checks);
        $finish;
    end
endmodule
