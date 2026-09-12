// AT transaction adapter for the same KF8253 counters used by PCXT.
// The payload remains stable through the rising /WR edge and read release.
// 8254 read-back commands are not implemented by this 8253-compatible backend.
`timescale 1ns/1ps

module spk286_at_pit (
    input  logic        clk,
    input  logic        reset,
    input  logic        counter_clock,
    input  logic        counter_2_gate,

    input  logic        request_valid,
    input  logic        request_command_valid,
    input  logic        request_write,
    input  logic        request_io,
    input  logic [23:0] request_address,
    input  logic [1:0]  request_byte_enable,
    input  logic [15:0] request_data_out,
    output logic        request_accept,
    output logic        request_ready,
    output logic [15:0] request_read_data,
    output logic        request_read_data_valid,

    output logic        irq0,
    output logic [2:0]  counter_out,
    output logic        protocol_error
);
    typedef enum logic [1:0] {IDLE, STROBE, RELEASE, DONE} state_t;
    state_t state_q;
    logic write_q, high_lane_q;
    logic [1:0] address_q;
    logic [7:0] data_q, read_q;
    wire [7:0] timer_data;
    wire selected = request_valid && request_command_valid && request_io &&
                    request_address[15:2] == 14'h0010;
    wire lane_valid = request_byte_enable == (request_address[0] ? 2'b10 : 2'b01);
    assign request_accept = (state_q == IDLE) && selected && lane_valid;
    assign request_ready = (state_q == DONE);
    assign request_read_data_valid = request_ready && !write_q;
    assign request_read_data = high_lane_q ? {read_q,8'h00} : {8'h00,read_q};
    assign irq0 = counter_out[0]; // AT IRQ0 is the timer OUT level.

    KF8253 u_timer (
        .clock(clk), .reset(reset),
        .chip_select_n(state_q == IDLE),
        .read_enable_n(!(state_q == STROBE && !write_q)),
        .write_enable_n(!(state_q == STROBE && write_q)),
        .address(address_q), .data_bus_in(data_q), .data_bus_out(timer_data),
        .counter_0_clock(counter_clock), .counter_0_gate(1'b1), .counter_0_out(counter_out[0]),
        .counter_1_clock(counter_clock), .counter_1_gate(1'b1), .counter_1_out(counter_out[1]),
        .counter_2_clock(counter_clock), .counter_2_gate(counter_2_gate), .counter_2_out(counter_out[2])
    );
    always_ff @(posedge clk) begin
        if(reset) begin
            state_q <= IDLE; write_q <= 0; high_lane_q <= 0;
            address_q <= 0; data_q <= 0; read_q <= 0; protocol_error <= 0;
        end else begin
            case(state_q)
                IDLE: if(request_accept) begin
                    state_q <= STROBE;
                    write_q <= request_write;
                    high_lane_q <= request_address[0];
                    address_q <= request_address[1:0];
                    data_q <= request_address[0] ? request_data_out[15:8] : request_data_out[7:0];
                end
                STROBE: begin
                    if(!write_q) read_q <= timer_data;
                    state_q <= RELEASE;
                end
                // KF8253 commits the write / read pointer on this edge.
                RELEASE: state_q <= DONE;
                DONE: state_q <= IDLE;
                default: state_q <= IDLE;
            endcase
            if(selected && !lane_valid) protocol_error <= 1;
        end
    end
endmodule
