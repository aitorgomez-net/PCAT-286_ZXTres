// Testbench for zxtres_scanconv with the SRAM controller and a model of the
// SRAM: a 640-wide picture of +LINES= lines (350 by default, 70 Hz at a
// 16.257 MHz dot rate, about 21.8 kHz) with a pattern of EGA colours goes in;
// the 720x480 frame at 27 MHz is compared with the source, pixel by pixel,
// and saved as scanconv_<lines>.ppm. With 200 lines nothing must be
// converted (active stays low).
//
// +MODE= picks the output raster: 0 480p (default), 2 480i, 3 240p. The
// 15.7 kHz rasters are checked from the pins alone: the row of every line
// follows from its time after the VSync, in half lines, so that the half
// line of the second 480i field is part of what is tested.
`timescale 1ns/1ps
module zxtres_scanconv_tb;
	integer lines = 350, width = 640, mode = 0, crth = 0, crtv = 0, gapm = 0;
	initial begin
		if ($value$plusargs("MODE=%d", mode)) ;
		if ($value$plusargs("CRTH=%d", crth)) ;
		if ($value$plusargs("CRTV=%d", crtv)) ;
		if ($value$plusargs("LINES=%d", lines)) ;
		if ($value$plusargs("WIDTH=%d", width)) ;
	end

	logic clk = 0, clk27 = 0;
	always #8.73 clk = ~clk;          // 57.27 MHz
	always #18.52 clk27 = ~clk27;     // 27 MHz
	logic reset = 1, reset27 = 1;
	initial begin #300 reset = 0; #300 reset27 = 0; end

	// Source: 3.52 clocks per dot (16.257 MHz), 912 dots per line.
	integer acc = 0;
	logic ce;
	always_ff @(posedge clk) begin
		if (acc >= 2520) begin acc <= acc - 2520; ce <= 1; end
		else begin acc <= acc + 1000; ce <= 0; end
	end

	// A pattern of 2-bit channels.
	function automatic [5:0] src(input integer x, input integer y);
		logic [1:0] rr, gg, bb;
		rr = 2'((x / 40 + y / 25) % 4);
		gg = 2'((x / 16 + y / 10) % 4);
		bb = 2'((x / 24 + y / 50 + x) % 4);
		src = {rr, gg, bb};
	endfunction

	integer h = 0, v = 0, frames = 0;
	logic [5:0] sv;
	logic [5:0] r, g, b;
	logic hb = 1, vb = 1;
	always_ff @(posedge clk) if (ce) begin
		sv = src(h, v);
		r <= {3{sv[5:4]}};
		g <= {3{sv[3:2]}};
		b <= {3{sv[1:0]}};
		hb <= h >= width;
		vb <= v >= lines;
		if (h == 911) begin
			h <= 0;
			if (v == lines + 59) begin v <= 0; frames <= frames + 1; end
			else v <= v + 1;
		end else h <= h + 1;
	end

	wire active;
	wire wr_req, rd_req, wr_grant, rd_grant, rd_valid;
	wire [19:0] wr_addr, rd_addr;
	wire [15:0] wr_data, rd_data;
	wire [5:0] ro, go, bo;
	wire hbo, vbo, hso, vso;
	wire [7:0] lost;
	zxtres_scanconv dut (
		.clk(clk), .reset(reset), .ce_in(ce), .off(1'b0),
		.mode(mode[1:0]), .crt_h(crth[3:0]), .crt_v(crtv[2:0]),
		.r_in(r), .g_in(g), .b_in(b), .hb_in(hb), .vb_in(vb), .active(active),
		.wr_req(wr_req), .wr_addr(wr_addr), .wr_data(wr_data), .wr_grant(wr_grant),
		.rd_req(rd_req), .rd_addr(rd_addr), .rd_grant(rd_grant), .rd_valid(rd_valid), .rd_data(rd_data),
		.clk27(clk27), .reset27(reset27),
		.r_out(ro), .g_out(go), .b_out(bo), .hb_out(hbo), .vb_out(vbo), .hs_out(hso), .vs_out(vso), .ce_out(),
		.lost(lost)
	);

	wire [19:0] sram_a;
	wire [15:0] sram_q;
	wire sram_we, sram_oe, sram_ub, sram_lb;
	zxtres_sram_ctrl sram (
		.clk(clk), .reset(reset),
		.wr_req(wr_req), .wr_addr(wr_addr), .wr_data(wr_data), .wr_grant(wr_grant),
		.rd_req(rd_req), .rd_addr(rd_addr), .rd_grant(rd_grant), .rd_valid(rd_valid), .rd_data(rd_data),
		.SRAM_A(sram_a), .SRAM_Q(sram_q), .SRAM_WE(sram_we), .SRAM_OE(sram_oe),
		.SRAM_UB(sram_ub), .SRAM_LB(sram_lb)
	);
	zxtres_sram_model model (
		.SRAM_A(sram_a), .SRAM_Q(sram_q), .SRAM_WE(sram_we), .SRAM_OE(sram_oe),
		.SRAM_UB(sram_ub), .SRAM_LB(sram_lb)
	);

	// Output frame. 480p: pixels stored at the raster position the DUT had
	// two clocks before (its output pipeline). 15.7 kHz: the row follows from
	// the time between the VSync and the HSync of the line, in half lines.
	logic [9:0] hc1, hc2, vc1, vc2;
	logic [17:0] frame [0:720*480-1];
	integer out_frames = 0, vs_edges = 0;
	integer hs_first = 0, hs_second = 0, now27 = 0;
	integer vs_t0 = 0, vs_t1 = 0, vs_t2 = 0, ls = 0, vl = 0, xc = 0, row = 0;
	integer first_row = 99999, last_row = -1;
	logic hso_q = 1, vso_q = 1;
	wire vs_act   = (mode == 0) ? !vso   : vso;
	wire vs_act_q = (mode == 0) ? !vso_q : vso_q;
	wire hs_act   = (mode == 0) ? !hso   : hso;
	wire hs_act_q = (mode == 0) ? !hso_q : hso_q;
	wire ce27 = dut.ce_out;
	always_ff @(posedge clk27) begin
		now27 <= now27 + 1;
		hc1 <= dut.hc; vc1 <= dut.vc; hc2 <= hc1; vc2 <= vc1;
		hso_q <= hso; vso_q <= vso;
		if (hs_act && !hs_act_q) begin
			hs_first <= hs_second; hs_second <= now27; ls <= now27; xc <= 0;
		end
		if (vs_act && !vs_act_q) begin
			vs_edges <= vs_edges + 1;
			vs_t2 <= vs_t1; vs_t1 <= vs_t0; vs_t0 <= now27; vl <= now27;
			if (mode != 2 || vs_edges % 2 == 1) out_frames <= out_frames + 1;
		end
		if (mode == 0) begin
			if (!hbo && !vbo) frame[vc2 * 720 + hc2] = {ro, go, bo};
		end else if (ce27 && !hbo && !vbo) begin
			// 480i: the line is 2*(15+k) half lines after the VSync in the
			// first field and 2*(15+k)-1 in the second, so the image row is
			// the half lines minus 29. 240p: line 23+n after it.
			if (mode == 2) row = ((ls - vl + 429) / 858) - 29 - 2 * crtv;
			else row = ((ls - vl + 858) / 1716) - 23 - crtv;
			if (xc == 0) gapm <= (now27 - ls) / 2;
			if (row >= 0 && row < 480 && xc < 720) begin
				frame[row * 720 + xc] = {ro, go, bo};
				if (row < first_row) first_row = row;
				if (row > last_row) last_row = row;
			end
			xc <= xc + 1;
		end
	end

	integer x, y, bad, shown, fd;
	logic [5:0] exp_r, exp_g, exp_b;
	logic [17:0] got;
	initial begin
		wait (out_frames == 8);
		@(posedge vs_act);       // let one frame go by whole
		wait (out_frames == 10);
		bad = 0; shown = 0;
		for (y = 0; y < (mode == 3 ? 224 : 480); y++)
			for (x = 0; x < 720; x++) begin
				got = frame[y * 720 + x];
				exp_r = 0; exp_g = 0; exp_b = 0;
				sv = 0;
				if (lines == 350 && x >= (720 - width) / 2 && x < (720 + width) / 2) begin
					if (mode == 3) sv = src(x - (720 - width) / 2, (y * 25) / 16);
					else if (y >= 65 && y < 415) sv = src(x - (720 - width) / 2, y - 65);
					if (mode == 3 || (y >= 65 && y < 415)) begin
						exp_r = {3{sv[5:4]}};
						exp_g = {3{sv[3:2]}};
						exp_b = {3{sv[1:0]}};
					end
				end
				if (got !== {exp_r, exp_g, exp_b}) begin
					bad = bad + 1;
					if (shown < 5) begin
						shown = shown + 1;
						$display("mismatch at x=%0d y=%0d got %h expected %h", x, y, got, {exp_r, exp_g, exp_b});
					end
				end
			end
		fd = $fopen($sformatf("scanconv_%0d_%0d_m%0d.ppm", lines, width, mode), "wb");
		$fwrite(fd, "P6\n720 %0d\n255\n", mode == 3 ? 224 : 480);
		for (y = 0; y < (mode == 3 ? 224 : 480); y++)
			for (x = 0; x < 720; x++)
				$fwrite(fd, "%c%c%c", {frame[y*720+x][17:12], 2'b00}, {frame[y*720+x][11:6], 2'b00},
				        {frame[y*720+x][5:0], 2'b00});
		$fclose(fd);
		$display("SCANCONV_TB lines=%0d width=%0d mode=%0d active=%b mismatches=%0d lost=%0d src_frames=%0d out_frames=%0d hs_period_clk27=%0d vs_gaps_clk27=%0d/%0d rows=%0d..%0d gap=%0d sram_errors=%0d",
		         lines, width, mode, active, bad, lost, frames, out_frames, hs_second - hs_first,
		         vs_t0 - vs_t1, vs_t1 - vs_t2, first_row, last_row, gapm, model.errors);
		$finish;
	end
	initial begin #600ms $display("SCANCONV_TB timeout"); $finish; end
endmodule
