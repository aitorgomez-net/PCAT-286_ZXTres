// MiSTer hps_io key events -> CPU-visible AT keyboard bytes.
// hps_io retains set-2 codes but packs F0/E0 into pressed/extended flags.
// Conversion follows the 8042 command-byte translation bit, with whole
// events queued until port 60h has consumed every byte of a sequence.
`timescale 1ns/1ps
module spk286_at_keyboard (
    input  logic        clk,
    input  logic        reset,
    input  logic [10:0] ps2_key,
    input  logic        translate_set1,
    input  logic        keyboard_byte_ready,
    output logic        keyboard_byte_valid,
    output logic [7:0]  keyboard_byte,
    output logic        overflow
);
    localparam integer FIFO_BITS = 5;
    localparam integer FIFO_DEPTH = 1 << FIFO_BITS;
    logic [9:0] event_fifo [0:FIFO_DEPTH-1];
    logic [FIFO_BITS-1:0] read_ptr_q, write_ptr_q;
    logic [FIFO_BITS:0] count_q;
    logic toggle_q = 1'b0;
    logic [63:0] sequence_q, next_sequence;
    logic [3:0] remaining_q, next_length;
    wire event_new = ps2_key[10] ^ toggle_q;
    wire load_event = (remaining_q == 0) && (count_q != 0) &&
                      keyboard_byte_ready;
    wire enqueue = event_new && (!count_q[FIFO_BITS] || load_event);
    wire [9:0] event_head = event_fifo[read_ptr_q];
    wire pressed = event_head[9];
    wire extended = event_head[8];
    wire [7:0] code = event_head[7:0];
    wire [7:0] translated = set1_code(code);

    // Standard AT translation table, checked against 86Box kbc_at.c
    // nont_to_t; the existing XT KFPS2KB uses the same set-2 -> set-1
    // mapping for ordinary keys. No XT PPI or serial protocol is used.
    function automatic [7:0] set1_code(input [7:0] value);
        case (value)
            8'h00: set1_code = 8'hFF;
            8'h01: set1_code = 8'h43;
            8'h02: set1_code = 8'h41;
            8'h03: set1_code = 8'h3F;
            8'h04: set1_code = 8'h3D;
            8'h05: set1_code = 8'h3B;
            8'h06: set1_code = 8'h3C;
            8'h07: set1_code = 8'h58;
            8'h08: set1_code = 8'h64;
            8'h09: set1_code = 8'h44;
            8'h0A: set1_code = 8'h42;
            8'h0B: set1_code = 8'h40;
            8'h0C: set1_code = 8'h3E;
            8'h0D: set1_code = 8'h0F;
            8'h0E: set1_code = 8'h29;
            8'h0F: set1_code = 8'h59;
            8'h10: set1_code = 8'h65;
            8'h11: set1_code = 8'h38;
            8'h12: set1_code = 8'h2A;
            8'h13: set1_code = 8'h70;
            8'h14: set1_code = 8'h1D;
            8'h15: set1_code = 8'h10;
            8'h16: set1_code = 8'h02;
            8'h17: set1_code = 8'h5A;
            8'h18: set1_code = 8'h66;
            8'h19: set1_code = 8'h71;
            8'h1A: set1_code = 8'h2C;
            8'h1B: set1_code = 8'h1F;
            8'h1C: set1_code = 8'h1E;
            8'h1D: set1_code = 8'h11;
            8'h1E: set1_code = 8'h03;
            8'h1F: set1_code = 8'h5B;
            8'h20: set1_code = 8'h67;
            8'h21: set1_code = 8'h2E;
            8'h22: set1_code = 8'h2D;
            8'h23: set1_code = 8'h20;
            8'h24: set1_code = 8'h12;
            8'h25: set1_code = 8'h05;
            8'h26: set1_code = 8'h04;
            8'h27: set1_code = 8'h5C;
            8'h28: set1_code = 8'h68;
            8'h29: set1_code = 8'h39;
            8'h2A: set1_code = 8'h2F;
            8'h2B: set1_code = 8'h21;
            8'h2C: set1_code = 8'h14;
            8'h2D: set1_code = 8'h13;
            8'h2E: set1_code = 8'h06;
            8'h2F: set1_code = 8'h5D;
            8'h30: set1_code = 8'h69;
            8'h32: set1_code = 8'h30;
            8'h33: set1_code = 8'h23;
            8'h34: set1_code = 8'h22;
            8'h35: set1_code = 8'h15;
            8'h36: set1_code = 8'h07;
            8'h37: set1_code = 8'h5E;
            8'h38: set1_code = 8'h6A;
            8'h39: set1_code = 8'h72;
            8'h3A: set1_code = 8'h32;
            8'h3B: set1_code = 8'h24;
            8'h3C: set1_code = 8'h16;
            8'h3D: set1_code = 8'h08;
            8'h3E: set1_code = 8'h09;
            8'h3F: set1_code = 8'h5F;
            8'h40: set1_code = 8'h6B;
            8'h41: set1_code = 8'h33;
            8'h42: set1_code = 8'h25;
            8'h43: set1_code = 8'h17;
            8'h44: set1_code = 8'h18;
            8'h45: set1_code = 8'h0B;
            8'h46: set1_code = 8'h0A;
            8'h47: set1_code = 8'h60;
            8'h48: set1_code = 8'h6C;
            8'h49: set1_code = 8'h34;
            8'h4A: set1_code = 8'h35;
            8'h4B: set1_code = 8'h26;
            8'h4C: set1_code = 8'h27;
            8'h4D: set1_code = 8'h19;
            8'h4E: set1_code = 8'h0C;
            8'h4F: set1_code = 8'h61;
            8'h50: set1_code = 8'h6D;
            8'h51: set1_code = 8'h73;
            8'h52: set1_code = 8'h28;
            8'h53: set1_code = 8'h74;
            8'h54: set1_code = 8'h1A;
            8'h55: set1_code = 8'h0D;
            8'h56: set1_code = 8'h62;
            8'h57: set1_code = 8'h6E;
            8'h58: set1_code = 8'h3A;
            8'h59: set1_code = 8'h36;
            8'h5A: set1_code = 8'h1C;
            8'h5B: set1_code = 8'h1B;
            8'h5C: set1_code = 8'h75;
            8'h5D: set1_code = 8'h2B;
            8'h5E: set1_code = 8'h63;
            8'h5F: set1_code = 8'h76;
            8'h60: set1_code = 8'h55;
            8'h61: set1_code = 8'h56;
            8'h62: set1_code = 8'h77;
            8'h63: set1_code = 8'h78;
            8'h64: set1_code = 8'h79;
            8'h65: set1_code = 8'h7A;
            8'h66: set1_code = 8'h0E;
            8'h67: set1_code = 8'h7B;
            8'h68: set1_code = 8'h7C;
            8'h69: set1_code = 8'h4F;
            8'h6A: set1_code = 8'h7D;
            8'h6B: set1_code = 8'h4B;
            8'h6C: set1_code = 8'h47;
            8'h6D: set1_code = 8'h7E;
            8'h6E: set1_code = 8'h7F;
            8'h70: set1_code = 8'h52;
            8'h71: set1_code = 8'h53;
            8'h72: set1_code = 8'h50;
            8'h73: set1_code = 8'h4C;
            8'h74: set1_code = 8'h4D;
            8'h75: set1_code = 8'h48;
            8'h76: set1_code = 8'h01;
            8'h77: set1_code = 8'h45;
            8'h78: set1_code = 8'h57;
            8'h79: set1_code = 8'h4E;
            8'h7A: set1_code = 8'h51;
            8'h7B: set1_code = 8'h4A;
            8'h7C: set1_code = 8'h37;
            8'h7D: set1_code = 8'h49;
            8'h7E: set1_code = 8'h46;
            8'h7F: set1_code = 8'h54;
            8'h83: set1_code = 8'h41;
            8'h84: set1_code = 8'h54;
            default: set1_code = value;
        endcase
    endfunction

    // Little-endian packed byte sequences, first byte in bits [7:0].
    // hps_io collapses Print Screen and Pause to E0:7C and E0:77.
    always_comb begin
        next_sequence = 64'h0;
        next_length = 4'd0;
        if (extended && code == 8'h77) begin
            // Pause has one make event and no independent break event.
            if (pressed) begin
                if (translate_set1) begin
                    next_sequence = 64'h0000_C59D_E145_1DE1;
                    next_length = 4'd6;
                end else begin
                    next_sequence = 64'h77F0_14F0_E177_14E1;
                    next_length = 4'd8;
                end
            end
        end else if (extended && code == 8'h7C) begin
            if (translate_set1) begin
                next_sequence = pressed ? 64'h0000_0000_37E0_2AE0 :
                                          64'h0000_0000_AAE0_B7E0;
                next_length = 4'd4;
            end else begin
                next_sequence = pressed ? 64'h0000_0000_7CE0_12E0 :
                                          64'h0000_12F0_E07C_F0E0;
                next_length = pressed ? 4'd4 : 4'd6;
            end
        end else if (translate_set1) begin
            // As on an 8042, a translated code with bit 7 already set has
            // no representable break. Normal make/break differs by bit 7.
            if (pressed || !translated[7]) begin
                if (extended) begin
                    next_sequence[15:0] = {translated | (pressed ? 8'h00 : 8'h80), 8'hE0};
                    next_length = 4'd2;
                end else begin
                    next_sequence[7:0] = translated | (pressed ? 8'h00 : 8'h80);
                    next_length = 4'd1;
                end
            end
        end else begin
            if (extended && !pressed) begin
                next_sequence[23:0] = {code, 8'hF0, 8'hE0};
                next_length = 4'd3;
            end else if (extended || !pressed) begin
                next_sequence[15:0] = {code, extended ? 8'hE0 : 8'hF0};
                next_length = 4'd2;
            end else begin
                next_sequence[7:0] = code;
                next_length = 4'd1;
            end
        end
    end

    assign keyboard_byte = sequence_q[7:0];
    assign keyboard_byte_valid = !reset && (remaining_q != 0);

    // Track the HPS toggle even during reset: hps_io keeps its state, so
    // clearing our history to zero would replay an old event on reset exit.
    always_ff @(posedge clk) begin
        toggle_q <= ps2_key[10];
        if (reset) begin
            read_ptr_q <= '0;
            write_ptr_q <= '0;
            count_q <= '0;
            sequence_q <= '0;
            remaining_q <= '0;
            overflow <= 1'b0;
        end else begin
            if (enqueue) begin
                event_fifo[write_ptr_q] <= ps2_key[9:0];
                write_ptr_q <= write_ptr_q + 1'b1;
            end
            if (event_new && !enqueue)
                overflow <= 1'b1;
            case ({enqueue, load_event})
                2'b10: count_q <= count_q + 1'b1;
                2'b01: count_q <= count_q - 1'b1;
                default: begin end
            endcase
            if (load_event) begin
                read_ptr_q <= read_ptr_q + 1'b1;
                sequence_q <= next_sequence;
                remaining_q <= next_length;
            end else if (keyboard_byte_valid && keyboard_byte_ready) begin
                sequence_q <= {8'h00, sequence_q[63:8]};
                remaining_q <= remaining_q - 1'b1;
            end
        end
    end
endmodule
