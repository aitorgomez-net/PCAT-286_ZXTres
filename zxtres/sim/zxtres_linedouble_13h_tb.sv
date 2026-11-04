// The VGA 13h TV 60Hz raster (vga_mode13_timing, native_70hz=0) through
// zxtres_linedouble, with the dot enable made as the guest makes it: the edges
// of pixel_toggle seen on the 57 MHz clock. Reports what leaves the doubler.
`timescale 1ns/1ps

module zxtres_linedouble_13h_tb;
    logic clk = 0;                       // 57.27 MHz
    always #5 clk = ~clk;
    logic clk28 = 0;                     // the video clock, half of it
    always @(posedge clk) clk28 <= ~clk28;
    logic reset = 1;
    initial #400 reset = 0;

    wire [9:0] px, py, sy;
    wire active, hblank, vblank, hsync, vsync, sblank, lstart, fstart, toggle;
    vga_mode13_timing timing (
        .clock(clk28), .reset(reset), .enable(1'b1), .native_70hz(1'b0),
        .mode_x_profile(3'd0), .crt_h_offset(4'd0), .crt_v_offset(3'd0),
        .pixel_x(px), .pixel_y(py), .scan_y(sy), .active(active),
        .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync),
        .status_blank(sblank), .line_start(lstart), .frame_start(fstart),
        .pixel_toggle(toggle)
    );

    logic t_d = 0, t_dd = 0;
    always_ff @(posedge clk) begin t_d <= toggle; t_dd <= t_d; end
    wire ce = t_d ^ t_dd;

    wire [5:0] ro, go, bo;
    wire hbo, vbo, hso, vso, ceo, dbl, hsp, vsp;
    zxtres_linedouble dut (
        .clk(clk), .reset(reset), .ce_in(ce), .off(1'b0),
        .r_in(px[5:0]), .g_in(py[5:0]), .b_in(6'd9),
        .hb_in(hblank), .vb_in(vblank), .hs_in(hsync), .vs_in(vsync),
        .r_out(ro), .g_out(go), .b_out(bo), .hb_out(hbo), .vb_out(vbo),
        .hs_out(hso), .vs_out(vso), .ce_out(ceo), .double(dbl), .hs_pin(hsp), .vs_pin(vsp)
    );

    // Count output lines per frame (VSync edges of the pins) and HSync period.
    integer now = 0, last_hs = 0, hs_period = 0, vs_period = 0, last_vs = 0;
    logic hsp_q = 0, vsp_q = 0;
    integer vs_low = 0, vs_low_max = 0, hs_edges = 0, hs_edges_frame = 0;
    always_ff @(posedge clk) begin
        now <= now + 1;
        hsp_q <= hsp; vsp_q <= vsp;
        if (now > 1000000) begin
            if (hsp_q != hsp && !hsp) begin hs_period <= now - last_hs; last_hs <= now; hs_edges <= hs_edges + 1; end
            if (vsp_q != vsp && !vsp) begin vs_period <= now - last_vs; last_vs <= now; hs_edges_frame <= hs_edges; hs_edges <= 0; end
            if (!vsp) vs_low <= vs_low + 1; else begin if (vs_low > vs_low_max) vs_low_max <= vs_low; vs_low <= 0; end
        end
    end

    logic hs_seen = 0, vs_seen = 0, hsp_p = 1;
    integer vs_lines = 0, vs_lines_max = 0;
    always_ff @(posedge clk) if (now > 1000000) begin
        hsp_p <= hsp;
        if (!vsp) begin if (hsp_p && !hsp) vs_lines <= vs_lines + 1; end
        else begin if (vs_lines > vs_lines_max) vs_lines_max <= vs_lines; vs_lines <= 0; end
    end
    always_ff @(posedge clk) if (ceo && !hbo && !vbo) begin hs_seen <= hsp; vs_seen <= vsp; end

    initial begin
        #(40_000_000);
        $display("LINEDOUBLE_13H double=%b hs_period_clk=%0d frame_period_clk=%0d lines_per_frame=%0d hs_pin_idle=%b vs_pin_idle=%b (seen in the picture) vsync_lines=%0d",
                 dbl, hs_period, vs_period, hs_edges_frame, hs_seen, vs_seen, vs_lines_max);
        $finish;
    end
endmodule
