`timescale 1ns/1ps

module spk286_system_0f_tb;
    logic clk=0, reset=0, cancel=0, start=0;
    logic byte_valid=0; logic [7:0] byte_data=0; wire byte_ready;
    wire active, retired, fault, decode_enable;
    logic decode_done=0, decode_byte_ready=1;
    logic [2:0] operand_reg=0, operand_rm=0; logic operand_register_direct=0;
    logic [15:0] operand_offset=0, rm_read_data=0, msw=0;
    logic [23:0] segment_base=0; logic [15:0] gdtr_limit=0, idtr_limit=0;
    logic [23:0] gdtr_base=0, idtr_base=0;
    wire gpr_write_en, msw_write_en, memory_request, memory_write, memory_byte;
    wire [2:0] gpr_write_index; wire [15:0] gpr_write_data, msw_write_data;
    wire [23:0] memory_address; wire [15:0] memory_write_data;
    logic memory_request_ready=0, memory_response_valid=0; wire memory_response_ready;
    logic [15:0] memory_read_data=0;
    wire gdtr_write_en, idtr_write_en; wire [15:0] gdtr_limit_data, idtr_limit_data;
    wire [23:0] gdtr_base_data, idtr_base_data;
    integer checks=0;

    spk286_system_0f dut(.*);

    task automatic check(input logic ok, input string text);
        checks=checks+1; if (!ok) $fatal(1,"%s",text);
    endtask
    task automatic tick;
        #1; clk=1; #1; clk=0; #1;
    endtask
    task automatic begin_instruction;
        start=1; tick(); start=0;
        check(active && byte_ready,"0F service accepts secondary opcode");
        byte_data=8'h01; byte_valid=1; tick(); byte_valid=0;
        check(active && decode_enable,"0F 01 enters ModR/M decode");
    endtask
    task automatic finish_decode(input logic [2:0] r, input logic [2:0] rm, input logic direct);
        operand_reg=r; operand_rm=rm; operand_register_direct=direct;
        decode_done=1; tick(); decode_done=0;
    endtask
    task automatic memory_cycle(input logic [15:0] response);
        wait(memory_request);
        memory_request_ready=1; tick(); memory_request_ready=0;
        wait(memory_response_ready);
        memory_read_data=response; memory_response_valid=1; tick(); memory_response_valid=0;
    endtask
    task automatic write_cycle(input integer delta, input logic [15:0] expected, input logic is_byte);
        wait(memory_request);
        check(memory_address[15:0] == operand_offset + 16'(delta),"descriptor address sequencing");
        check(memory_write && memory_byte==is_byte && memory_write_data==expected,"descriptor write payload");
        memory_request_ready=1; tick(); memory_request_ready=0;
        wait(memory_response_ready); memory_response_valid=1; tick(); memory_response_valid=0;
    endtask

    initial begin
        reset=1; tick(); reset=0;
        // SGDT m48: limit, base-low word, then base-high byte.
        operand_offset=16'h1000; gdtr_limit=16'h1234; gdtr_base=24'h56789A;
        begin_instruction(); finish_decode(3'd0,3'd0,1'b0);
        write_cycle(0,16'h1234,1'b0);
        write_cycle(2,16'h789A,1'b0);
        write_cycle(4,16'h0056,1'b1);
        check(retired,"SGDT retires"); tick(); check(!active,"SGDT service returns idle");

        // SMSW AX is register-direct and must not issue a memory cycle.
        msw=16'h0005; operand_offset=0; begin_instruction(); finish_decode(3'd4,3'd0,1'b1);
        check(gpr_write_en && gpr_write_index==0 && gpr_write_data==16'h0005,"SMSW register result");
        tick(); check(retired,"SMSW retires"); tick();

        // LGDT m48 captures all three portions and exposes one atomic load.
        operand_offset=16'h2000; begin_instruction(); finish_decode(3'd2,3'd0,1'b0);
        memory_cycle(16'hABCD); memory_cycle(16'h3456);
        wait(memory_request); memory_request_ready=1; tick(); memory_request_ready=0;
        wait(memory_response_ready); memory_read_data=16'h0078; memory_response_valid=1;
        #1; check(gdtr_write_en && gdtr_limit_data==16'hABCD && gdtr_base_data==24'h783456,"LGDT result");
        tick(); memory_response_valid=0; check(retired,"LGDT retires");
        $display("SYSTEM_0F PASS: %0d checks",checks); $finish;
    end
endmodule
