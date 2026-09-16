`timescale 1ns/1ps
module spk286_invalid_opcode_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:1114111];
    integer checks=0, cases=0, retires=0, deliveries=0, writes=0, timeout_count;
    spk286 dut(.*);

    task automatic check(input logic ok, input string message);
        checks=checks+1;
        if (ok !== 1'b1)
            $fatal(1,"%s case=%0d opcode=%h IP=%h CS=%h event=%0d/%0d retires=%0d deliveries=%0d",
                   message,cases,debug_opcode,debug_ip,debug_cs,debug_event_kind,
                   debug_event_vector,retires,deliveries);
    endtask

    task automatic tick;
        #1;
        if (bus_valid && address < 24'd1114112)
            data_in={memory[{address[20:1],1'b1}],memory[{address[20:1],1'b0}]};
        #4;
        if (bus_valid && ready && !reset && bus_write) begin
            writes=writes+1;
            if (address[0]) memory[address[20:0]]=data_out[15:8];
            else begin
                memory[address[20:0]]=data_out[7:0];
                if (!bus_bhe_n) memory[address+1]=data_out[15:8];
            end
        end
        clk=1; #5; clk=0; #1;
        if (instruction_retired) retires=retires+1;
        if (event_completed) deliveries=deliveries+1;
        check(!microcode_fault && debug_prefetch_count<=6,"internal execution invariants");
    endtask

    task automatic service;
        ready=bus_valid;
        tick();
    endtask

    task automatic putword(input integer address_value, input integer word_value);
        memory[address_value]=8'(word_value);
        memory[address_value+1]=8'(word_value>>8);
    endtask

    function automatic logic [15:0] stackword(input integer offset);
        stackword={memory[24'h080000+offset+1],memory[24'h080000+offset]};
    endfunction

    task automatic setup(input logic [7:0] first_byte, input logic [7:0] second_byte);
        reset=1; execute_enable=0; ready=0; redirect=0; ip_write_en=0;
        segment_load_en=0; flags_write_en=0; gpr_write_en=0; retires=0;
        deliveries=0; writes=0; timeout_count=0;
        tick(); reset=0;
        for (integer r=0;r<8;r=r+1) begin
            gpr_write_en=1; gpr_write_index=3'(r);
            gpr_write_data=r==4 ? 16'h0200 : 16'hA500+16'(r);
            tick();
        end
        gpr_write_en=0;
        for (integer s=0;s<4;s=s+1) begin
            segment_load_en=1; segment_load_index=2'(s);
            segment_load_selector=s==1 ? 16'h1000 : (s==2 ? 16'h8000 : 16'h4000);
            redirect=s==1; ip_write_en=s==1; ip_write_data=16'h0100;
            tick();
        end
        segment_load_en=0; redirect=0; ip_write_en=0;
        // Vector 6 -> 1000:0430, with a minimal IRET handler at that entry.
        putword(6*4,16'h0430); putword(6*4+2,16'h1000);
        memory[24'h010430]=8'hCF;
        memory[24'h010100]=first_byte;
        memory[24'h010101]=second_byte;
        execute_enable=1;
    endtask

    task automatic expect_ud(input logic [7:0] first_byte, input logic [7:0] second_byte);
        setup(first_byte,second_byte);
        while (deliveries<1 && timeout_count<900) begin
            service(); timeout_count=timeout_count+1;
        end
        check(timeout_count<900,"invalid opcode reaches vector 6");
        check(deliveries==1 && debug_event_vector==8'd6,"architectural #UD vector");
        check(retires==0 && !halted && !shutdown,"faulting opcode does not retire or freeze CPU");
        check(stackword('h01FA)==16'h0100 && stackword('h01FC)==16'h1000 &&
              stackword('h01FE)==16'h0002,"#UD frame saves the faulting CS:IP and FLAGS");
        check(writes>0,"#UD frame writes CS, IP and FLAGS");
        cases=cases+1;
    endtask

    task automatic expect_unsupported(input logic [7:0] first_byte, input logic [7:0] second_byte);
        setup(first_byte,second_byte);
        while (!unsupported_opcode && timeout_count<900) begin
            service(); timeout_count=timeout_count+1;
        end
        check(unsupported_opcode,"legal but unimplemented opcode remains unsupported");
        check(deliveries==0 && retires==0 && !halted && !shutdown,
              "unsupported opcode neither faults nor retires");
        cases=cases+1;
    endtask

    initial begin
        for (integer i=0;i<1114112;i=i+1) memory[i]=8'h90;
        // 64h is Intel's documented example of an invalid first byte.
        expect_ud(8'h64,8'h90);
        // 66h is not an operand-size prefix on an 80286.
        expect_ud(8'h66,8'h90);
        // 0Fh is a two-byte opcode introducer; an invalid second byte faults.
        expect_ud(8'h0F,8'hFF);
        // 0F05 is the undocumented 286 LOADALL opcode. It is deferred, not #UD.
        expect_unsupported(8'h0F,8'h05);
        $display("INVALID_OPCODE PASS: %0d classification cases; %0d checks",cases,checks);
        $finish;
    end
endmodule
