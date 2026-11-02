// PS/2 keyboard bytes (scan code set 2) to MiSTer hps_io ps2_key events:
// ps2_key[10] toggles on every event, [9] is 1 for make and 0 for break,
// [8] marks the E0 prefix and [7:0] is the set-2 code. E0 and F0 become
// those flags. The Pause key's E1 sequence and the keyboard's own replies
// (BAT AAh, ACK FAh, echo, resend, errors) produce no event.
//
// Win+F12 opens the OSD (the controller watches the same keyboard), so an F12
// pressed while either Windows key is down gives no event, nor does its
// release: the core keeps plain F12 for itself, as MiSTer's F12KEYMOD does.
// The keyboard is hidden from the core while the OSD is open (osd_open), so
// whatever the Windows keys did meanwhile is unknown: when the OSD closes they
// count as up again.
`timescale 1ns/1ps
module zxtres_ps2_key (
    input  logic        clk,
    input  logic        reset,
    input  logic        osd_open,
    input  logic        byte_valid,
    input  logic [7:0]  byte_in,
    output logic [10:0] ps2_key
);
    logic       extended_q, break_q;
    logic [2:0] skip_q;                 // bytes of an E1 sequence still to drop
    logic       lwin_q, rwin_q;         // Windows keys down
    logic       menu_f12_q;             // an F12 taken by Win+F12 is down
    logic       osd_open_q;

    wire is_f12  = !extended_q && byte_in == 8'h07;
    wire is_lwin = extended_q && byte_in == 8'h1F;
    wire is_rwin = extended_q && byte_in == 8'h27;

    always_ff @(posedge clk) begin
        osd_open_q <= osd_open;
        if (reset) begin
            ps2_key <= '0;
            extended_q <= 1'b0;
            break_q <= 1'b0;
            skip_q <= '0;
            lwin_q <= 1'b0;
            rwin_q <= 1'b0;
            menu_f12_q <= 1'b0;
        end else if (osd_open_q && !osd_open) begin
            lwin_q <= 1'b0;
            rwin_q <= 1'b0;
            menu_f12_q <= 1'b0;
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
                        if (is_lwin) lwin_q <= !break_q;
                        if (is_rwin) rwin_q <= !break_q;
                        if (is_f12 && !break_q && (lwin_q || rwin_q))
                            menu_f12_q <= 1'b1;          // Win+F12: the OSD's
                        else if (is_f12 && break_q && menu_f12_q)
                            menu_f12_q <= 1'b0;
                        else
                            ps2_key <= {!ps2_key[10], !break_q, extended_q, byte_in};
                        extended_q <= 1'b0;
                        break_q <= 1'b0;
                    end
                endcase
            end
        end
    end
endmodule
