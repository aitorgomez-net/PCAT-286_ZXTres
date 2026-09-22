`timescale 1ns/1ps
module spk286_system_0f_integration_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:1114111];
    integer retires=0, cycles=0;
    spk286 dut(.*);

    task automatic tick;
        #1;
        if (bus_valid && address < 24'd1114112)
            data_in={memory[{address[20:1],1'b1}],memory[{address[20:1],1'b0}]};
        #4; if (bus_valid && ready && bus_write) begin
            if (address[0]) memory[address[20:0]]=data_out[15:8];
            else begin
                memory[address[20:0]]=data_out[7:0];
                if (!bus_bhe_n) memory[address+1]=data_out[15:8];
            end
        end
        clk=1; #5; clk=0; #1;
        if (instruction_retired) retires=retires+1;
    endtask
    task automatic service;
        ready=bus_valid; tick();
    endtask

    initial begin
        for (integer i=0;i<1114112;i=i+1) memory[i]=8'h90;
        // CS=1000:0100 -> physical 10100.  SMSW AX is the first real-mode
        // 0F 01 form used by CheckIt before it sets PE with LMSW.
        memory[21'h010100]=8'h0F; memory[21'h010101]=8'h01; memory[21'h010102]=8'hE0;
        reset=1; execute_enable=0; ready=0; tick(); reset=0;
        for (integer r=0;r<8;r=r+1) begin
            gpr_write_en=1; gpr_write_index=3'(r); gpr_write_data=16'hA500+16'(r); tick();
        end
        gpr_write_en=0;
        for (integer s=0;s<4;s=s+1) begin
            segment_load_en=1; segment_load_index=2'(s);
            segment_load_selector=s==1 ? 16'h1000 : (s==2 ? 16'h8000 : 16'h4000);
            redirect=s==1; ip_write_en=s==1; ip_write_data=16'h0100; tick();
        end
        segment_load_en=0; redirect=0; ip_write_en=0; execute_enable=1;
        for (cycles=0; cycles<1200 && retires<1; cycles=cycles+1) service();
        // Intel 80286/80287 Programmer's Reference Manual (1987), section 10.4:
        // RESET initializes MSW to FFF0h; SMSW must preserve its reserved bits.
        if (retires!=1 || debug_ip!==16'h0103 || debug_gpr[15:0]!==16'hFFF0 || unsupported_opcode || halted || shutdown)
            $fatal(1,"0F 01 integration failed retires=%0d IP=%h AX=%h unsupported=%b halted=%b shutdown=%b",
                   retires,debug_ip,debug_gpr[15:0],unsupported_opcode,halted,shutdown);
        $display("SYSTEM_0F_INTEGRATION PASS: SMSW real-mode path"); $finish;
    end
endmodule
