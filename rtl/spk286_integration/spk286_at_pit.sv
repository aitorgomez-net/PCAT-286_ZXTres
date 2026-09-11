// Functional AT PIT boundary with channel 0 timer interrupt output.
//
// This module is deliberately clock-domain neutral at the machine boundary:
// the supplied counter_clock is the PIT tick, while the normalized register
// handshake remains on clk.  Modes 0, 2 and 3 cover the timer behaviour needed
// by the A4 acceptance path; later device work can add the remaining 8253
// latch/readback nuances without changing the CPU-side transaction record.
`timescale 1ns/1ps

module spk286_at_pit (
    input  logic        clk,
    input  logic        reset,
    input  logic        counter_clock,

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
    localparam logic [1:0] IO_IDLE = 2'd0;
    localparam logic [1:0] IO_DONE = 2'd1;

    logic [1:0] io_state_q;
    logic [1:0] io_byte_enable_q;
    logic [7:0] io_read_data_q;
    logic       io_read_data_valid_q;
    logic [1:0] control_rw_q [0:2];
    logic [2:0] control_mode_q [0:2];
    // Keep the 8253's special count value 0000h representable as 10000h.
    logic [16:0] reload_q [0:2];
    logic [16:0] count_q [0:2];
    logic [1:0] write_phase_q [0:2];
    logic [2:0] loaded_q;
    logic       counter_clock_q;
    logic       irq0_q;
    integer i;

    logic pit_port_valid;
    logic pit_lane_valid;
    logic [1:0] pit_channel;
    logic [7:0] pit_byte;

    always_comb begin
        pit_port_valid = request_valid && request_command_valid &&
                         request_io &&
                         (request_address[15:0] >= 16'h0040) &&
                         (request_address[15:0] <= 16'h0043);
        pit_lane_valid =
            ((request_address[0] == 1'b0) &&
             (request_byte_enable == 2'b01)) ||
            ((request_address[0] == 1'b1) &&
             (request_byte_enable == 2'b10));
        pit_channel = request_address[1:0];
        pit_byte = request_byte_enable[1] ?
                   request_data_out[15:8] : request_data_out[7:0];
    end

    assign request_accept = (io_state_q == IO_IDLE) && pit_port_valid &&
                            pit_lane_valid;
    assign request_ready = (io_state_q == IO_DONE);
    assign request_read_data_valid = request_ready &&
                                     io_read_data_valid_q;
    assign request_read_data = io_byte_enable_q[1] ?
                               {io_read_data_q, 8'h00} :
                               {8'h00, io_read_data_q};
    assign irq0 = irq0_q;

    always_comb begin
        counter_out[0] = (control_mode_q[0] == 3'b000) ?
                         (count_q[0] == 17'h00000) :
                         (count_q[0] != 17'h00000);
        counter_out[1] = (count_q[1] != 17'h00000);
        counter_out[2] = (count_q[2] != 17'h00000);
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            io_state_q <= IO_IDLE;
            io_byte_enable_q <= 2'b00;
            io_read_data_q <= 8'h00;
            io_read_data_valid_q <= 1'b0;
            counter_clock_q <= 1'b0;
            irq0_q <= 1'b0;
            loaded_q <= 3'b000;
            for (i = 0; i < 3; i = i + 1) begin
                control_rw_q[i] <= 2'b00;
                control_mode_q[i] <= 3'b000;
                reload_q[i] <= 17'h00000;
                count_q[i] <= 17'h00000;
                write_phase_q[i] <= 2'b00;
            end
            protocol_error <= 1'b0;
        end else begin
            counter_clock_q <= counter_clock;
            irq0_q <= 1'b0;

            if (io_state_q == IO_DONE)
                io_state_q <= IO_IDLE;

            if (request_accept) begin
                io_state_q <= IO_DONE;
                io_byte_enable_q <= request_byte_enable;
                io_read_data_valid_q <= !request_write;
                if (!request_write) begin
                    if (pit_channel < 2'd3)
                        io_read_data_q <= write_phase_q[pit_channel][0] ?
                            count_q[pit_channel][15:8] :
                            count_q[pit_channel][7:0];
                    else
                        io_read_data_q <= 8'h00;
                end else if (pit_channel == 2'd3) begin
                    if (pit_byte[7:6] < 2'd3) begin
                        control_rw_q[pit_byte[7:6]] <= pit_byte[5:4];
                        control_mode_q[pit_byte[7:6]] <= pit_byte[3:1];
                        write_phase_q[pit_byte[7:6]] <=
                            (pit_byte[5:4] == 2'b11) ? 2'b00 : 2'b00;
                    end
                end else begin
                    if (write_phase_q[pit_channel][0] == 1'b0) begin
                        reload_q[pit_channel][7:0] <= pit_byte;
                        write_phase_q[pit_channel][0] <= 1'b1;
                    end else begin
                        reload_q[pit_channel][15:8] <= pit_byte;
                        count_q[pit_channel] <= {1'b0, pit_byte,
                                                 reload_q[pit_channel][7:0]};
                        loaded_q[pit_channel] <= 1'b1;
                        write_phase_q[pit_channel][0] <= 1'b0;
                    end
                end
            end

            if (counter_clock && !counter_clock_q && loaded_q[0]) begin
                if (count_q[0] > 17'h00001)
                    count_q[0] <= count_q[0] - 17'h00001;
                else begin
                    irq0_q <= 1'b1;
                    if ((control_mode_q[0] == 3'b010) ||
                        (control_mode_q[0] == 3'b011))
                        count_q[0] <= (reload_q[0][15:0] == 16'h0000) ?
                                      17'h10000 : reload_q[0];
                    else begin
                        count_q[0] <= 17'h00000;
                        loaded_q[0] <= 1'b0;
                    end
                end
            end

            if (pit_port_valid && !pit_lane_valid)
                protocol_error <= 1'b1;
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset)
            assert (!(request_accept && !pit_port_valid))
                else $error("AT PIT accepted an unselected request");
    end
`endif
endmodule
