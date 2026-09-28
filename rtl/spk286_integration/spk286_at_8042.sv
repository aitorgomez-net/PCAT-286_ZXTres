// Functional AT 8042 keyboard-controller boundary.
//
// CPU-visible keyboard bytes are supplied through a ready/valid handshake.
// The HPS event adapter uses keyboard_translate_set1 to format them according
// to command-byte bit 6. Controller replies bypass that conversion.
`timescale 1ns/1ps

module spk286_at_8042 #(
    // One PS/2 frame is about 1 ms. Keep a second keyboard byte out of
    // port 60h while a chained IRQ1 handler is still processing the first.
    parameter integer KEYBOARD_GAP_CYCLES = 50_000
) (
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
    output logic        keyboard_num_lock,
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
    // Keep command replies behind the host's IBF-completion poll.  The
    // controller is asynchronous to the 286 bus and must not expose AA/C0/
    // D0/E0 replies in the same polling window that clears IBF.
    localparam logic [11:0] RESPONSE_DELAY_CYCLES = 12'd1023;

    logic       io_state_q;
    logic [1:0] io_byte_enable_q;
    logic [7:0] io_read_data_q;
    logic       io_read_data_valid_q;
    logic [7:0] output_buffer_q;
    logic       output_buffer_valid_q;
    logic       output_buffer_keyboard_q;
    logic [15:0] keyboard_gap_q;
    logic       input_buffer_full_q;
    logic       response_pending_q;
    logic [7:0] response_pending_data_q;
    logic [11:0] response_delay_q;
    // Follow-up bytes after the first keyboard reply: BAT or 101-key ID.
    logic [1:0] keyboard_reply_followup_q;
    logic [7:0] command_byte_q;
    logic       system_flag_q;
    logic [7:0] output_port_q;
    logic       write_command_byte_q;
    logic       write_output_port_q;
    logic       write_keyboard_leds_q;
    logic       keyboard_num_lock_q;
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
                            lane_valid &&
                            (!request_write || !input_buffer_full_q);
    assign request_ready = (io_state_q == IO_DONE);
    assign request_read_data_valid = request_ready && io_read_data_valid_q;
    assign request_read_data = io_byte_enable_q[1] ?
                               {io_read_data_q, 8'h00} :
                               {8'h00, io_read_data_q};
    assign keyboard_output_valid = output_buffer_valid_q;
    assign keyboard_output_byte = output_buffer_q;
    assign keyboard_translate_set1 = command_byte_q[6];
    assign keyboard_num_lock = keyboard_num_lock_q;
    // Hold queued keyboard bytes while OBF is full, a controller/device reply
    // is pending, or the interface is inhibited. Host writes have priority.
    assign keyboard_byte_ready = !reset && keyboard_enabled_q &&
                                 !output_buffer_valid_q &&
                                 (keyboard_gap_q == 16'd0) &&
                                 !response_pending_q &&
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
                                 system_flag_q, input_buffer_full_q,
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
            output_buffer_keyboard_q <= 1'b0;
            keyboard_gap_q <= 16'd0;
            input_buffer_full_q <= 1'b0;
            response_pending_q <= 1'b0;
            response_pending_data_q <= 8'h00;
            response_delay_q <= 12'd0;
            keyboard_reply_followup_q <= 2'd0;
            command_byte_q <= 8'h01;
            system_flag_q <= 1'b0;
            // The IBM AT releases the CPU reset line with its A20 gate
            // closed. BIOS POST opens it explicitly through the 8042
            // output-port protocol (P2=01h; only the reset and A20 pins have
            // behavioral effects).
            output_port_q <= 8'h01;
            write_command_byte_q <= 1'b0;
            write_output_port_q <= 1'b0;
            write_keyboard_leds_q <= 1'b0;
            keyboard_num_lock_q <= 1'b0;
            reset_pulse_q <= 1'b0;
            keyboard_enabled_q <= 1'b1;
            last_write_command_q <= 1'b0;
            side_effect_count <= 16'h0000;
            protocol_error <= 1'b0;
        end else begin
            if (io_state_q == IO_DONE)
                io_state_q <= IO_IDLE;
            reset_pulse_q <= 1'b0;
            if (keyboard_gap_q != 16'd0)
                keyboard_gap_q <= keyboard_gap_q - 16'd1;

            // The host input buffer remains busy for at least one controller
            // cycle.  Controller replies are posted only after IBF has
            // cleared, so BIOS code cannot mistake a command response for a
            // pre-existing OBF byte while polling the command completion.
            if (input_buffer_full_q)
                input_buffer_full_q <= 1'b0;
            else if (response_pending_q && !output_buffer_valid_q) begin
                if (response_delay_q != 12'd0)
                    response_delay_q <= response_delay_q - 12'd1;
                else begin
                    output_buffer_q <= response_pending_data_q;
                    output_buffer_valid_q <= 1'b1;
                    output_buffer_keyboard_q <= 1'b0;
                    case (keyboard_reply_followup_q)
                        2'd1: begin
                            // FFh: ACK, then BAT completion.
                            response_pending_data_q <= 8'hAA;
                            response_pending_q <= 1'b1;
                            response_delay_q <= RESPONSE_DELAY_CYCLES;
                            keyboard_reply_followup_q <= 2'd0;
                        end
                        2'd2: begin
                            // F2h: ACK, then the 101-key AT identity AB 83.
                            response_pending_data_q <= 8'hAB;
                            response_pending_q <= 1'b1;
                            response_delay_q <= RESPONSE_DELAY_CYCLES;
                            keyboard_reply_followup_q <= 2'd3;
                        end
                        2'd3: begin
                            response_pending_data_q <= 8'h83;
                            response_pending_q <= 1'b1;
                            response_delay_q <= RESPONSE_DELAY_CYCLES;
                            keyboard_reply_followup_q <= 2'd0;
                        end
                        default: response_pending_q <= 1'b0;
                    endcase
                end
            end

            if (request_accept) begin
                io_state_q <= IO_DONE;
                io_byte_enable_q <= request_byte_enable;
                io_read_data_valid_q <= !request_write;
                side_effect_count <= side_effect_count + 16'h0001;

                if (!request_write) begin
                    io_read_data_q <= current_read_data;
                    if (request_address[15:0] == 16'h0060) begin
                        if (output_buffer_valid_q && output_buffer_keyboard_q)
                            keyboard_gap_q <= KEYBOARD_GAP_CYCLES[15:0];
                        output_buffer_valid_q <= 1'b0;
                    end
                end else if (request_address[15:0] == 16'h0064) begin
                    input_buffer_full_q <= 1'b1;
                    last_write_command_q <= 1'b1;
                    write_command_byte_q <= 1'b0;
                    write_output_port_q <= 1'b0;
                    case (request_byte)
                        8'h20: begin
                            response_pending_data_q <= command_byte_q;
                            response_pending_q <= 1'b1;
                            response_delay_q <= RESPONSE_DELAY_CYCLES;
                        end
                        8'h60: write_command_byte_q <= 1'b1;
                        8'hAA: begin
                            // The AT controller self-test reinitializes its
                            // command byte and output port. In particular it
                            // inhibits keyboard input and IRQ1 while POST
                            // consumes the 55h reply. Keep the status system
                            // flag independent of the new command byte.
                            command_byte_q <= 8'h10;
                            system_flag_q <= 1'b1;
                            keyboard_enabled_q <= 1'b0;
                            output_port_q <= 8'hCF;
                            keyboard_reply_followup_q <= 2'd0;
                            response_pending_data_q <= 8'h55;
                            response_pending_q <= 1'b1;
                            response_delay_q <= RESPONSE_DELAY_CYCLES;
                        end
                        8'hAB: begin
                            // The decoded MiSTer keyboard path has no exposed
                            // stuck-clock/data condition, so its interface
                            // diagnostic result is deterministically healthy.
                            response_pending_data_q <= 8'h00;
                            response_pending_q <= 1'b1;
                            response_delay_q <= RESPONSE_DELAY_CYCLES;
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
                            response_pending_data_q <= 8'hA0;
                            response_pending_q <= 1'b1;
                            response_delay_q <= RESPONSE_DELAY_CYCLES;
                        end
                        8'hD0: begin
                            response_pending_data_q <= output_port_q;
                            response_pending_q <= 1'b1;
                            response_delay_q <= RESPONSE_DELAY_CYCLES;
                        end
                        8'hD1: write_output_port_q <= 1'b1;
                        8'hE0: begin
                            // This profile receives decoded HPS key events and
                            // does not model the 8042's electrical T0/T1 pins.
                            // Return the no-fault value used by Phoenix BIOS
                            // and 86Box for an operational keyboard interface.
                            response_pending_data_q <= 8'h00;
                            response_pending_q <= 1'b1;
                            response_delay_q <= RESPONSE_DELAY_CYCLES;
                        end
                        8'hFE: reset_pulse_q <= 1'b1;
                        default: begin end
                    endcase
                end else begin
                    last_write_command_q <= 1'b0;
                    if (write_command_byte_q) begin
                        command_byte_q <= request_byte;
                        system_flag_q <= request_byte[2];
                        keyboard_enabled_q <= !request_byte[4];
                        write_command_byte_q <= 1'b0;
                    end else if (write_output_port_q) begin
                        output_port_q <= request_byte | 8'h01;
                        reset_pulse_q <= !request_byte[0];
                        write_output_port_q <= 1'b0;
                    end else if (write_keyboard_leds_q) begin
                        // The 101-key keyboard accepts the EDh LED parameter.
                        // Its Num Lock bit controls the fake Shift sequences
                        // sent with the separate cursor cluster.
                        keyboard_num_lock_q <= request_byte[1];
                        write_keyboard_leds_q <= 1'b0;
                        response_pending_data_q <= 8'hFA;
                        response_pending_q <= 1'b1;
                        response_delay_q <= RESPONSE_DELAY_CYCLES;
                    end else if (request_byte == 8'hED) begin
                        write_keyboard_leds_q <= 1'b1;
                        response_pending_data_q <= 8'hFA;
                        response_pending_q <= 1'b1;
                        response_delay_q <= RESPONSE_DELAY_CYCLES;
                    end else if (request_byte == 8'hF2) begin
                        response_pending_data_q <= 8'hFA;
                        response_pending_q <= 1'b1;
                        response_delay_q <= RESPONSE_DELAY_CYCLES;
                        keyboard_reply_followup_q <= 2'd2;
                    end else if (request_byte == 8'hFF) begin
                        // The HPS supplies decoded key events, so there is no
                        // serial keyboard to answer this AT keyboard command.
                        // Emulate the standard reset ACK and BAT completion
                        // bytes at the host-visible 8042 output buffer.
                        response_pending_data_q <= 8'hFA;
                        response_pending_q <= 1'b1;
                        response_delay_q <= RESPONSE_DELAY_CYCLES;
                        keyboard_reply_followup_q <= 2'd1;
                        keyboard_num_lock_q <= 1'b0;
                        write_keyboard_leds_q <= 1'b0;
                    end
                end
            end

            // A host byte is accepted only when the output buffer is free.
            // Reading port 60h therefore remains the sole operation that
            // releases a pending keyboard IRQ.
            if (keyboard_byte_valid && keyboard_byte_ready) begin
                output_buffer_q <= keyboard_byte;
                output_buffer_valid_q <= 1'b1;
                output_buffer_keyboard_q <= 1'b1;
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
