// Simulation-only replacement for spk286_machine_cpu. Drives the production
// CPU bus pins; the AT bridge, machine decode, router and IDE remain real RTL.
// Do not compile this file together with the production CPU wrapper.
`timescale 1ns/1ps
module spk286_machine_cpu (
    input logic clk, reset, execute_enable, ready,
    input logic [15:0] data_in,
    input logic intr, nmi, hold_request,
    output logic [23:0] address = 0,
    output logic [15:0] data_out = 0,
    output logic data_oe = 0, bus_valid = 0, bus_write = 0,
    output logic bus_bhe_n = 1,
    output logic [3:0] bus_status = 4'hF,
    output wire bus_lock, hlda,
    output wire halted, shutdown, control_error, unsupported_opcode,
                microcode_fault, operand_blocked, event_completed,
    output wire [7:0] debug_event_vector,
    output wire [2:0] debug_event_kind,
    output wire [7:0] debug_opcode,
    output wire [15:0] debug_cs,
    output wire [23:0] debug_cs_base,
    output wire [15:0] debug_ip, debug_flags,
    output wire [127:0] debug_gpr,
    output wire [63:0] debug_segment_selectors,
    output wire debug_instruction_retired,
    output wire [15:0] debug_instruction_ip,
    output wire [95:0] debug_segment_bases,
    output wire fetch_blocked,
    output wire [16:0] debug_fetch_cursor,
    output wire [11:0] debug_micro_pc, debug_micro_entry,
    output wire [7:0] debug_micro_instruction,
    output wire debug_micro_active,
    output wire [3:0] debug_prefetch_count, debug_bus_state,
    output wire [7:0] debug_biu_detail
);
    assign bus_lock = 0;
    assign hlda = hold_request && !bus_valid;
    assign {halted, shutdown, control_error, unsupported_opcode,
            microcode_fault, operand_blocked, event_completed,
            debug_event_vector, debug_event_kind, debug_opcode, debug_cs,
            debug_cs_base, debug_ip, debug_flags, debug_gpr,
            debug_segment_selectors, debug_instruction_retired,
            debug_instruction_ip, debug_segment_bases, fetch_blocked,
            debug_fetch_cursor, debug_micro_pc, debug_micro_entry,
            debug_micro_instruction, debug_micro_active,
            debug_prefetch_count, debug_bus_state, debug_biu_detail} = '0;

    integer idle_cycles = 0;
    initial if ($value$plusargs("CPU_IDLE=%d", idle_cycles)) begin end

    task automatic io_byte(input logic write_cycle, input logic [15:0] port,
                           input logic [7:0] value, output logic [7:0] result);
        integer cycles;
        begin
            @(negedge clk);
            repeat (idle_cycles) @(negedge clk);
            address = {8'h00, port};
            data_out = port[0] ? {value, 8'h00} : {8'h00, value};
            bus_bhe_n = !port[0];
            bus_status = write_cycle ? 4'hA : 4'h9;
            bus_write = write_cycle;
            data_oe = write_cycle;
            bus_valid = 1;
            cycles = 0;
            do begin
                @(negedge clk);
                cycles = cycles + 1;
            end while (!ready && cycles < 256);
            if (!ready) $fatal(1, "CPU I/O timeout at %04h", port);
            result = port[0] ? data_in[15:8] : data_in[7:0];
            // Hold the pins until the edge where the CPU observes READY.
            @(posedge clk);
            @(negedge clk);
            bus_valid = 0;
            bus_status = 4'hF;
            bus_write = 0;
            data_oe = 0;
        end
    endtask

    task automatic io_read(input logic [15:0] port, output logic [7:0] value);
        io_byte(0, port, 0, value);
    endtask
    task automatic io_write(input logic [15:0] port, input logic [7:0] value);
        logic [7:0] unused_value;
        io_byte(1, port, value, unused_value);
    endtask

    // ISA16 I/O helper. The production bridge normally serializes I/O words
    // for 8-bit peripherals, but the AT IDE data register is explicitly
    // advertised as a native x16 target by the machine decode.
    task automatic io_word(input logic write_cycle, input logic [15:0] port,
                           input logic [15:0] value, output logic [15:0] result);
        integer cycles;
        begin
            @(negedge clk);
            repeat (idle_cycles) @(negedge clk);
            address = {8'h00, port};
            data_out = value;
            bus_bhe_n = 1'b0;
            bus_status = write_cycle ? 4'hA : 4'h9;
            bus_write = write_cycle;
            data_oe = write_cycle;
            bus_valid = 1'b1;
            cycles = 0;
            do begin
                @(negedge clk);
                cycles = cycles + 1;
            end while (!ready && cycles < 256);
            if (!ready) $fatal(1, "CPU ISA16 I/O timeout at %04h", port);
            result = data_in;
            @(posedge clk);
            @(negedge clk);
            bus_valid = 1'b0;
            bus_status = 4'hF;
            bus_write = 1'b0;
            data_oe = 1'b0;
        end
    endtask

    task automatic io_read_word(input logic [15:0] port,
                                 output logic [15:0] value);
        io_word(1'b0, port, 16'h0000, value);
    endtask
    task automatic io_write_word(input logic [15:0] port,
                                  input logic [15:0] value);
        logic [15:0] unused_value;
        io_word(1'b1, port, value, unused_value);
    endtask
endmodule
