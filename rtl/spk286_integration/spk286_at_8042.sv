// Functional AT 8042 keyboard-controller boundary.
//
// CPU-visible keyboard bytes are supplied through a ready/valid handshake.
// The HPS event adapter uses keyboard_translate_set1 to format them according
// to command-byte bit 6. Controller replies bypass that conversion.
`timescale 1ns/1ps

module spk286_at_8042 (
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

    input  logic        keyboard_byte_valid,
    input  logic [7:0]  keyboard_byte,
    output logic        keyboard_byte_ready,
    output logic        keyboard_translate_set1,
    output logic        keyboard_output_valid,
    output logic [7:0]  keyboard_output_byte,
    output logic        irq1,
    output logic        a20_enable,
    output logic        cpu_reset_request,
    output logic [15:0] side_effect_count,
    output logic        protocol_error
);
    localparam logic IO_IDLE = 1'b0;
    localparam logic IO_DONE = 1'b1;

    logic       io_state_q;
    logic [1:0] io_byte_enable_q;
    logic [7:0] io_read_data_q;
    logic       io_read_data_valid_q;
    logic [7:0] output_buffer_q;
    logic       output_buffer_valid_q;
    logic [7:0] command_byte_q;
    logic [7:0] output_port_q;
    logic       write_command_byte_q;
    logic       write_output_port_q;
    logic       reset_pulse_q;
    logic       keyboard_enabled_q;
    logic       last_write_command_q;
    logic [7:0] request_byte;
    logic [7:0] current_read_data;
    logic       port_selected;
    logic       lane_valid;

    always_comb begin
        port_selected = request_valid && request_command_valid && request_io &&
                        ((request_address[15:0] == 16'h0060) ||
                         (request_address[15:0] == 16'h0064));
        lane_valid = ((request_address[0] == 1'b0) &&
                      (request_byte_enable == 2'b01)) ||
                     ((request_address[0] == 1'b1) &&
                      (request_byte_enable == 2'b10));
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
    assign keyboard_output_valid = output_buffer_valid_q;
    assign keyboard_output_byte = output_buffer_q;
    assign keyboard_translate_set1 = command_byte_q[6];
    // Hold queued keyboard bytes while OBF is full or the interface is
    // inhibited. Host writes have priority, including changes to the command
    // byte and commands that generate their own output-buffer reply.
    assign keyboard_byte_ready = !reset && keyboard_enabled_q &&
                                 !output_buffer_valid_q &&
                                 !(request_accept && request_write);
    assign irq1 = output_buffer_valid_q && command_byte_q[0];
    assign a20_enable = output_port_q[1];
    // A real 8042 asserts the CPU reset line either through command FE or by
    // writing a zero to output-port bit 0 after command D1.  The CPU-facing
    // boundary models that electrical action as a one-clock pulse; keeping
    // the stored output-port bit high after the pulse lets the emulated CPU
    // leave reset without requiring a full chipset reset (and preserves CMOS,
    // PIT and PIC state exactly as a warm hardware reset would).
    assign cpu_reset_request = reset_pulse_q;

    always_comb begin
        if (request_address[15:0] == 16'h0064)
            // 5170 status: no parity/timeout error, inhibit switch open,
            // last host write command/data, system flag, empty input buffer,
            // and the live controller output-buffer state.
            current_read_data = {3'b000, 1'b1, last_write_command_q,
                                 command_byte_q[2], 1'b0,
                                 output_buffer_valid_q};
        else
            current_read_data = output_buffer_q;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            io_state_q <= IO_IDLE;
            io_byte_enable_q <= 2'b00;
            io_read_data_q <= 8'h00;
            io_read_data_valid_q <= 1'b0;
            output_buffer_q <= 8'h00;
            output_buffer_valid_q <= 1'b0;
            command_byte_q <= 8'h01;
            output_port_q <= 8'h01;
            write_command_byte_q <= 1'b0;
            write_output_port_q <= 1'b0;
            reset_pulse_q <= 1'b0;
            keyboard_enabled_q <= 1'b1;
            last_write_command_q <= 1'b0;
            side_effect_count <= 16'h0000;
            protocol_error <= 1'b0;
        end else begin
            if (io_state_q == IO_DONE)
                io_state_q <= IO_IDLE;
            reset_pulse_q <= 1'b0;

            if (request_accept) begin
                io_state_q <= IO_DONE;
                io_byte_enable_q <= request_byte_enable;
                io_read_data_valid_q <= !request_write;
                side_effect_count <= side_effect_count + 16'h0001;

                if (!request_write) begin
                    io_read_data_q <= current_read_data;
                    if (request_address[15:0] == 16'h0060)
                        output_buffer_valid_q <= 1'b0;
                end else if (request_address[15:0] == 16'h0064) begin
                    last_write_command_q <= 1'b1;
                    write_command_byte_q <= 1'b0;
                    write_output_port_q <= 1'b0;
                    case (request_byte)
                        8'h20: begin
                            output_buffer_q <= command_byte_q;
                            output_buffer_valid_q <= 1'b1;
                        end
                        8'h60: write_command_byte_q <= 1'b1;
                        8'hAA: begin
                            command_byte_q[2] <= 1'b1;
                            output_buffer_q <= 8'h55;
                            output_buffer_valid_q <= 1'b1;
                        end
                        8'hAB: begin
                            // The decoded MiSTer keyboard path has no exposed
                            // stuck-clock/data condition, so its interface
                            // diagnostic result is deterministically healthy.
                            output_buffer_q <= 8'h00;
                            output_buffer_valid_q <= 1'b1;
                        end
                        8'hAD: begin
                            command_byte_q[4] <= 1'b1;
                            keyboard_enabled_q <= 1'b0;
                        end
                        8'hAE: begin
                            command_byte_q[4] <= 1'b0;
                            keyboard_enabled_q <= 1'b1;
                        end
                        8'hC0: begin
                            // AT input port: inhibit switch open, EGA/color,
                            // manufacturing jumper absent, 512 KiB planar RAM.
                            output_buffer_q <= 8'hA0;
                            output_buffer_valid_q <= 1'b1;
                        end
                        8'hD0: begin
                            output_buffer_q <= output_port_q;
                            output_buffer_valid_q <= 1'b1;
                        end
                        8'hD1: write_output_port_q <= 1'b1;
                        8'hE0: begin
                            // T0/T1 observe the idle-high decoded clock/data
                            // interface represented by this boundary.
                            output_buffer_q <= 8'h03;
                            output_buffer_valid_q <= 1'b1;
                        end
                        8'hFE: reset_pulse_q <= 1'b1;
                        default: begin end
                    endcase
                end else begin
                    last_write_command_q <= 1'b0;
                    if (write_command_byte_q) begin
                        command_byte_q <= request_byte;
                        keyboard_enabled_q <= !request_byte[4];
                        write_command_byte_q <= 1'b0;
                    end else if (write_output_port_q) begin
                        output_port_q <= request_byte | 8'h01;
                        reset_pulse_q <= !request_byte[0];
                        write_output_port_q <= 1'b0;
                    end
                end
            end

            // A host byte is accepted only when the output buffer is free.
            // Reading port 60h therefore remains the sole operation that
            // releases a pending keyboard IRQ.
            if (keyboard_byte_valid && keyboard_byte_ready) begin
                output_buffer_q <= keyboard_byte;
                output_buffer_valid_q <= 1'b1;
            end

            if (port_selected && !lane_valid)
                protocol_error <= 1'b1;
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset)
            assert (!(request_accept && !port_selected))
                else $error("AT 8042 accepted an unselected request");
    end
`endif
endmodule
