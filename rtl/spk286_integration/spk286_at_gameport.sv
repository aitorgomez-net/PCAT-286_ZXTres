`timescale 1ns/1ps

module spk286_at_gameport (
    input  logic        clk,
    input  logic        reset,
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
    input  logic [1:0]  clk_select,
    input  logic [4:0]  joy_opts,
    input  logic [13:0] joy0,
    input  logic [13:0] joy1,
    input  logic [15:0] joya0,
    input  logic [15:0] joya1,
    output logic [15:0] side_effect_count,
    output logic        protocol_error
);
    localparam logic IO_IDLE = 1'b0;
    localparam logic IO_DONE = 1'b1;

    logic       io_state_q;
    logic [1:0] io_byte_enable_q;
    logic       io_read_data_valid_q;
    logic [7:0] joy_data;
    logic       port_selected;
    logic       lane_valid;

    always_comb begin
        port_selected = request_valid && request_command_valid && request_io &&
                        (request_address[15:0] >= 16'h0200) &&
                        (request_address[15:0] <= 16'h0207);
        lane_valid = (request_byte_enable == 2'b01) ||
                     (request_byte_enable == 2'b10);
    end

    assign request_accept = (io_state_q == IO_IDLE) && port_selected && lane_valid;
    assign request_ready = (io_state_q == IO_DONE);
    assign request_read_data_valid = request_ready && io_read_data_valid_q;
    assign request_read_data = io_byte_enable_q[1] ?
                               {joy_data, 8'h00} : {8'h00, joy_data};
    assign side_effect_count = 16'h0000;
    assign protocol_error = 1'b0;

    tandy_pcjr_joy u_joysticks (
        .clk        (clk),
        .reset      (reset),
        .en         (request_accept && request_write),
        .clk_select (clk_select),
        .joy_opts   (joy_opts),
        .joy0       (joy0),
        .joy1       (joy1),
        .joya0      (joya0),
        .joya1      (joya1),
        .d_out      (joy_data)
    );

    always_ff @(posedge clk) begin
        if (reset) begin
            io_state_q <= IO_IDLE;
            io_byte_enable_q <= 2'b00;
            io_read_data_valid_q <= 1'b0;
        end else begin
            case (io_state_q)
                IO_IDLE: begin
                    io_read_data_valid_q <= 1'b0;
                    if (request_accept) begin
                        io_state_q <= IO_DONE;
                        io_byte_enable_q <= request_byte_enable;
                        io_read_data_valid_q <= !request_write;
                    end
                end
                IO_DONE: io_state_q <= IO_IDLE;
                default: io_state_q <= IO_IDLE;
            endcase
        end
    end
endmodule
