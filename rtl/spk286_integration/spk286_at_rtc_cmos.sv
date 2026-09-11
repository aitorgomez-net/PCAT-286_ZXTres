// Functional AT RTC/CMOS boundary.
//
// Port 70h carries the CMOS index and NMI mask; port 71h carries the selected
// byte.  The time registers are deterministic and may be advanced by the
// supplied second_tick pulse.  This avoids making wall-clock time a hidden
// simulation input.
`timescale 1ns/1ps

module spk286_at_rtc_cmos (
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

    input  logic        periodic_tick,
    input  logic        second_tick,
    output logic        irq8,
    output logic        nmi_mask,
    output logic [15:0] side_effect_count,
    output logic [6:0]  selected_index,
    output logic        protocol_error
);
    localparam logic IO_IDLE = 1'b0;
    localparam logic IO_DONE = 1'b1;

    logic       io_state_q;
    logic [1:0] io_byte_enable_q;
    logic [7:0] io_read_data_q;
    logic       io_read_data_valid_q;
    logic [6:0] index_q;
    logic       nmi_mask_q;
    logic       irq8_q;
    logic       status_c_periodic_q;
    logic [7:0] cmos_q [0:127];
    logic [7:0] request_byte;
    logic [7:0] current_read_data;
    logic       port_selected;
    logic       lane_valid;
    integer i;

    always_comb begin
        port_selected = request_valid && request_command_valid && request_io &&
                        ((request_address[15:0] == 16'h0070) ||
                         (request_address[15:0] == 16'h0071));
        lane_valid = ((request_address[0] == 1'b0) &&
                      (request_byte_enable == 2'b01)) ||
                     ((request_address[0] == 1'b1) &&
                      (request_byte_enable == 2'b10));
        request_byte = request_byte_enable[1] ?
                       request_data_out[15:8] : request_data_out[7:0];
        selected_index = index_q;

        if (request_address[15:0] == 16'h0070)
            current_read_data = {nmi_mask_q, index_q};
        else if (index_q == 7'h0C)
            current_read_data = {irq8_q,
                                 status_c_periodic_q,
                                 cmos_q[7'h0C][5:0]};
        else
            current_read_data = cmos_q[index_q];
    end

    assign request_accept = (io_state_q == IO_IDLE) && port_selected &&
                            lane_valid;
    assign request_ready = (io_state_q == IO_DONE);
    assign request_read_data_valid = request_ready && io_read_data_valid_q;
    assign request_read_data = io_byte_enable_q[1] ?
                               {io_read_data_q, 8'h00} :
                               {8'h00, io_read_data_q};
    assign irq8 = irq8_q;
    assign nmi_mask = nmi_mask_q;

    function automatic logic [7:0] next_bcd_second(input logic [7:0] value);
        begin
            if (value == 8'h59)
                next_bcd_second = 8'h00;
            else if (value[3:0] == 4'h9)
                next_bcd_second = {value[7:4] + 4'h1, 4'h0};
            else
                next_bcd_second = value + 8'h01;
        end
    endfunction

    always_ff @(posedge clk) begin
        if (reset) begin
            io_state_q <= IO_IDLE;
            io_byte_enable_q <= 2'b00;
            io_read_data_q <= 8'h00;
            io_read_data_valid_q <= 1'b0;
            index_q <= 7'h00;
            nmi_mask_q <= 1'b1;
            irq8_q <= 1'b0;
            status_c_periodic_q <= 1'b0;
            side_effect_count <= 16'h0000;
            for (i = 0; i < 128; i = i + 1)
                cmos_q[i] = 8'h00;
            cmos_q[7'h0A] <= 8'h26;
            cmos_q[7'h0B] <= 8'h02;
            cmos_q[7'h0D] <= 8'h80;
        end else begin
            if (io_state_q == IO_DONE)
                io_state_q <= IO_IDLE;

            if (request_accept) begin
                io_state_q <= IO_DONE;
                io_byte_enable_q <= request_byte_enable;
                io_read_data_valid_q <= !request_write;
                side_effect_count <= side_effect_count + 16'h0001;

                if (!request_write) begin
                    io_read_data_q <= current_read_data;
                    if ((request_address[15:0] == 16'h0071) &&
                        (index_q == 7'h0C)) begin
                        status_c_periodic_q <= 1'b0;
                        irq8_q <= 1'b0;
                    end
                end else if (request_address[15:0] == 16'h0070) begin
                    index_q <= request_byte[6:0];
                    nmi_mask_q <= request_byte[7];
                end else if (index_q != 7'h0C && index_q != 7'h0D) begin
                    cmos_q[index_q] <= request_byte;
                end
            end

            if (periodic_tick && cmos_q[7'h0B][6]) begin
                status_c_periodic_q <= 1'b1;
                irq8_q <= 1'b1;
            end

            if (second_tick && !cmos_q[7'h0B][7]) begin
                if (!cmos_q[7'h0B][2])
                    cmos_q[7'h00] <= next_bcd_second(cmos_q[7'h00]);
                else if (cmos_q[7'h00] == 8'd59)
                    cmos_q[7'h00] <= 8'd0;
                else
                    cmos_q[7'h00] <= cmos_q[7'h00] + 8'd1;
            end

            if (port_selected && !lane_valid)
                protocol_error <= 1'b1;
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset)
            assert (!(request_accept && !port_selected))
                else $error("AT RTC accepted an unselected request");
    end
`endif
endmodule
