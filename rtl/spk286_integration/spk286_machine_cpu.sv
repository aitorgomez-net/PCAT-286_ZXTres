// SPK286 production wrapper for the XT-derived MiSTer machine.
// Setup/debug mutation inputs are disabled; diagnostics remain observable.
`timescale 1ns/1ps

module spk286_machine_cpu (
    input  logic         clk,
    input  logic         reset,
    input  logic         execute_enable,
    input  logic         ready,
    input  logic [15:0]  data_in,
    input  logic         intr,
    input  logic         nmi,
    input  logic         hold_request,

    output logic [23:0]  address,
    output logic [15:0]  data_out,
    output logic         data_oe,
    output logic         bus_valid,
    output logic         bus_write,
    output logic         bus_bhe_n,
    output logic [3:0]   bus_status,
    output logic         bus_lock,
    output logic         hlda,

    output logic         halted,
    output logic         shutdown,
    output logic         control_error,
    output logic         unsupported_opcode,
    output logic         microcode_fault,
    output logic         operand_blocked,
    output logic         event_completed,
    output logic [7:0]   debug_event_vector,
    output logic [2:0]   debug_event_kind,
    output logic [7:0]   debug_opcode,
    output logic [15:0]  debug_cs,
    output logic [23:0]  debug_cs_base,
    output logic [15:0]  debug_ip,
    output logic [15:0]  debug_flags,
    output logic [127:0] debug_gpr,
    output logic [63:0]  debug_segment_selectors,
    output logic         debug_instruction_retired,
    output logic [15:0]  debug_instruction_ip,
    output logic [95:0]  debug_segment_bases,
    output logic         fetch_blocked,
    output logic [16:0]  debug_fetch_cursor,
    output logic [11:0]  debug_micro_pc,
    output logic [11:0]  debug_micro_entry,
    output logic [7:0]   debug_micro_instruction,
    output logic         debug_micro_active,
    output logic [3:0]   debug_prefetch_count,
    output logic [3:0]   debug_bus_state,
    output logic [7:0]   debug_biu_detail
);
    logic [15:0] unused_gpr_read_a_data;
    logic [15:0] unused_gpr_read_b_data;
    logic [15:0] unused_segment_selector;
    logic [23:0] unused_segment_base;
    logic [15:0] unused_segment_limit;
    logic [7:0]  unused_segment_access;
    logic [23:0] unused_segment_address;
    logic        unused_debug_nmi_pending;
    logic        unused_debug_nmi_blocked;
    logic        unused_debug_sti_shadow;
    logic [7:0]  unused_debug_modrm;
    logic [15:0] unused_debug_displacement;
    logic [15:0] unused_debug_effective_offset;
    logic [1:0]  unused_debug_operand_segment;
    logic        unused_fetch_request_ready;
    logic        unused_fetch_valid;
    logic [15:0] unused_fetch_data;
    logic [15:0] unused_fetch_ip;
    logic [1:0]  unused_fetch_count;
    logic [63:0] unused_debug_segment_limits;
    logic [31:0] unused_debug_segment_access;

    spk286 cpu (
        .clk(clk),
        .reset(reset),
        .ready(ready),
        .data_in(data_in),
        .execute_enable(execute_enable),
        .intr(intr),
        .nmi(nmi),
        .hold_request(hold_request),
        .halted(halted),
        .shutdown(shutdown),
        .event_completed(event_completed),
        .debug_event_vector(debug_event_vector),
        .debug_event_kind(debug_event_kind),
        .debug_instruction_ip(debug_instruction_ip),
        .debug_nmi_pending(unused_debug_nmi_pending),
        .debug_nmi_blocked(unused_debug_nmi_blocked),
        .debug_sti_shadow(unused_debug_sti_shadow),

        .gpr_read_a_index(3'd0),
        .gpr_read_b_index(3'd0),
        .gpr_read_a_byte(1'b0),
        .gpr_read_b_byte(1'b0),
        .gpr_read_a_data(unused_gpr_read_a_data),
        .gpr_read_b_data(unused_gpr_read_b_data),
        .gpr_write_en(1'b0),
        .gpr_write_byte(1'b0),
        .gpr_write_index(3'd0),
        .gpr_write_data(16'd0),
        .ip_write_en(1'b0),
        .ip_write_data(16'd0),
        .flags_write_en(1'b0),
        .flags_write_data(16'd0),
        .flags_write_mask(16'd0),
        .segment_load_en(1'b0),
        .segment_load_index(2'd0),
        .segment_load_selector(16'd0),
        .segment_read_index(2'd0),
        .segment_offset(16'd0),
        .segment_selector(unused_segment_selector),
        .segment_base(unused_segment_base),
        .segment_limit(unused_segment_limit),
        .segment_access(unused_segment_access),
        .segment_address(unused_segment_address),
        .redirect(1'b0),
        .control_error(control_error),
        .unsupported_opcode(unsupported_opcode),
        .debug_opcode(debug_opcode),
        .instruction_retired(debug_instruction_retired),
        .microcode_fault(microcode_fault),
        .operand_blocked(operand_blocked),
        .debug_modrm(unused_debug_modrm),
        .debug_displacement(unused_debug_displacement),
        .debug_effective_offset(unused_debug_effective_offset),
        .debug_operand_segment(unused_debug_operand_segment),

        .fetch_request(1'b0),
        .fetch_request_ready(unused_fetch_request_ready),
        .fetch_ready(1'b1),
        .fetch_valid(unused_fetch_valid),
        .fetch_data(unused_fetch_data),
        .fetch_ip(unused_fetch_ip),
        .fetch_count(unused_fetch_count),
        .fetch_blocked(fetch_blocked),

        .address(address),
        .data_out(data_out),
        .data_oe(data_oe),
        .bus_valid(bus_valid),
        .bus_write(bus_write),
        .bus_bhe_n(bus_bhe_n),
        .bus_status(bus_status),
        .bus_lock(bus_lock),
        .hlda(hlda),
        .debug_biu_detail(debug_biu_detail),

        .debug_cs(debug_cs),
        .debug_cs_base(debug_cs_base),
        .debug_ip(debug_ip),
        .debug_flags(debug_flags),
        .debug_gpr(debug_gpr),
        .debug_segment_selectors(debug_segment_selectors),
        .debug_segment_bases(debug_segment_bases),
        .debug_segment_limits(unused_debug_segment_limits),
        .debug_segment_access(unused_debug_segment_access),
        .debug_fetch_cursor(debug_fetch_cursor),
        .debug_micro_pc(debug_micro_pc),
        .debug_micro_entry(debug_micro_entry),
        .debug_micro_instruction(debug_micro_instruction),
        .debug_micro_active(debug_micro_active),
        .debug_prefetch_count(debug_prefetch_count),
        .debug_bus_state(debug_bus_state)
    );
endmodule
