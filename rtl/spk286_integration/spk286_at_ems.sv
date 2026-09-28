`timescale 1ns/1ps

// LIM EMS 4.0-compatible page-register block.
//
// The visible page frame is E0000h-EFFFFh, split into four 16 KiB windows.
// Each window selects one of 128 16 KiB pages, providing 2 MiB of expanded
// memory.  The backing address translation is deliberately kept at the
// machine/memory boundary; this block owns only the 260h-263h registers.

module spk286_at_ems (
    input  logic        clk,
    input  logic        reset,
    input  logic        ems_enabled,

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

    output logic [6:0]  map_ems[0:3],
    output logic        window_enabled[0:3],
    output logic [15:0] side_effect_count,
    output logic        protocol_error
);
    localparam logic IO_IDLE = 1'b0;
    localparam logic IO_DONE = 1'b1;

    logic       io_state_q;
    logic [1:0] io_byte_enable_q;
    logic [7:0] io_read_data_q;
    logic       io_read_data_valid_q;
    logic       port_selected;
    logic       lane_valid;
    logic [7:0] request_byte;
    integer i;

    always_comb begin
        port_selected = request_valid && request_command_valid && request_io &&
                        ems_enabled &&
                        (request_address[15:0] >= 16'h0260) &&
                        (request_address[15:0] <= 16'h0263);
        lane_valid = (request_byte_enable == 2'b01) ||
                     (request_byte_enable == 2'b10);
        request_byte = request_byte_enable[1] ?
                       request_data_out[15:8] : request_data_out[7:0];
    end

    assign request_accept = (io_state_q == IO_IDLE) && port_selected &&
                            lane_valid;
    assign request_ready = (io_state_q == IO_DONE);
    assign request_read_data_valid = request_ready && io_read_data_valid_q;
    assign request_read_data = io_byte_enable_q[1] ?
                               {io_read_data_q, 8'h00} :
                               {8'h00, io_read_data_q};
    assign side_effect_count = 16'h0000;
    assign protocol_error = 1'b0;

    always_ff @(posedge clk) begin
        if (reset) begin
            io_state_q <= IO_IDLE;
            io_byte_enable_q <= 2'b00;
            io_read_data_q <= 8'hFF;
            io_read_data_valid_q <= 1'b0;
            for (i = 0; i < 4; i = i + 1) begin
                map_ems[i] <= 7'h00;
                window_enabled[i] <= 1'b0;
            end
        end else begin
            // Match the source core: disabling EMS clears the page map, so a
            // later enable cannot expose stale mappings from a previous run.
            if (!ems_enabled) begin
                for (i = 0; i < 4; i = i + 1) begin
                    map_ems[i] <= 7'h00;
                    window_enabled[i] <= 1'b0;
                end
            end

            case (io_state_q)
                IO_IDLE: begin
                    io_read_data_valid_q <= 1'b0;
                    if (request_accept) begin
                        io_state_q <= IO_DONE;
                        io_byte_enable_q <= request_byte_enable;
                        io_read_data_valid_q <= !request_write;

                        if (request_write) begin
                            // 00h-7Fh selects/enables a page; FFh disables
                            // the window.  80h-FEh are reserved and retain
                            // the previous mapping, like the source block.
                            if (request_byte == 8'hFF) begin
                                map_ems[request_address[1:0]] <= 7'h00;
                                window_enabled[request_address[1:0]] <= 1'b0;
                            end else if (request_byte < 8'h80) begin
                                map_ems[request_address[1:0]] <=
                                    request_byte[6:0];
                                window_enabled[request_address[1:0]] <= 1'b1;
                            end
                        end else if (window_enabled[request_address[1:0]]) begin
                            io_read_data_q <= {1'b0,
                                map_ems[request_address[1:0]]};
                        end else begin
                            io_read_data_q <= 8'hFF;
                        end
                    end
                end
                IO_DONE: io_state_q <= IO_IDLE;
                default: io_state_q <= IO_IDLE;
            endcase
        end
    end
endmodule
