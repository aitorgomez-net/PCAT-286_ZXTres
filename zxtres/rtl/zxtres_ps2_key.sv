// PS/2 keyboard bytes (scan code set 2) to MiSTer hps_io ps2_key events:
// ps2_key[10] toggles on every event, [9] is 1 for make and 0 for break,
// [8] marks the E0 prefix and [7:0] is the set-2 code. E0 and F0 become
// those flags. The Pause key's E1 sequence and the keyboard's own replies
// (BAT AAh, ACK FAh, echo, resend, errors) produce no event.
`timescale 1ns/1ps
module zxtres_ps2_key (
    input  logic        clk,
    input  logic        reset,
    input  logic        byte_valid,
    input  logic [7:0]  byte_in,
    output logic [10:0] ps2_key
);
    logic       extended_q, break_q;
    logic [2:0] skip_q;                 // bytes of an E1 sequence still to drop

    always_ff @(posedge clk) begin
        if (reset) begin
            ps2_key <= '0;
            extended_q <= 1'b0;
            break_q <= 1'b0;
            skip_q <= '0;
        end else if (byte_valid) begin
            if (skip_q != '0) begin
                skip_q <= skip_q - 3'd1;
            end else begin
                case (byte_in)
                    8'hE0: extended_q <= 1'b1;
                    8'hF0: break_q <= 1'b1;
                    8'hE1: skip_q <= 3'd7;           // E1 14 77 E1 F0 14 F0 77
                    8'h00, 8'hAA, 8'hEE, 8'hFA, 8'hFC, 8'hFD, 8'hFE, 8'hFF: ;
                    default: begin
                        ps2_key <= {!ps2_key[10], !break_q, extended_q, byte_in};
                        extended_q <= 1'b0;
                        break_q <= 1'b0;
                    end
                endcase
            end
        end
    end
endmodule
