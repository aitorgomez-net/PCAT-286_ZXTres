// Line doubler for the 15.7 kHz modes of the PC/AT picture.
//
// A picture of under 300 lines (the 200-line CGA/EGA modes, whose dot is
// 14.318 MHz, exactly a fourth of the 57.27 MHz pipeline clock) is doubled to
// 31.4 kHz with mist-modules' scandoubler_framing and a line store. Everything else (350-line and MDA
// modes, whose 16.257 MHz dot does not divide the clock; 400/480-line VGA
// modes, which are 31 kHz already) passes through at its own rate.
//
// The choice is made once per frame, on the line count of the undoubled
// picture, so it cannot follow its own output. off holds the doubler off.
//
// The core's syncs are +HSync, -VSync (the 200-line EGA/CGA timing). A
// doubled picture has about 525 lines at 59.9 Hz and 31.4 kHz, the 640x480
// VGA timing, which monitors tell from the 400-line one by -HSync, -VSync,
// so a doubled picture leaves with -HSync, -VSync whatever its input polarity:
// the idle level of each sync is read during the active picture. The CGA/EGA
// 200-line modes come in as +HSync, -VSync, the VGA 13h TV raster as
// +HSync, +VSync.
module zxtres_linedouble (
	input        clk,
	input        reset,
	input        ce_in,         // the dot enable of the input picture
	input        off,

	input  [5:0] r_in,
	input  [5:0] g_in,
	input  [5:0] b_in,
	input        hb_in,
	input        vb_in,
	input        hs_in,
	input        vs_in,

	output [5:0] r_out,
	output [5:0] g_out,
	output [5:0] b_out,
	output       hb_out,
	output       vb_out,
	output       hs_out,        // polarity of the input
	output       vs_out,
	output       ce_out,        // the dot enable of the output picture
	output       double,        // the picture is being doubled
	output       hs_pin,        // polarity for the connector
	output       vs_pin
);

reg       hb_q, vb_q;
reg [9:0] line_cnt;
reg       dbl;
reg       lo15;                 // a 15.7 kHz picture (under 300 lines), doubled or not

always @(posedge clk)
	if (reset) begin
		hb_q     <= 1'b1;
		vb_q     <= 1'b1;
		line_cnt <= 10'd0;
		dbl      <= 1'b0;
		lo15     <= 1'b0;
	end else if (ce_in) begin
		hb_q <= hb_in;
		vb_q <= vb_in;
		if (hb_in && !hb_q && !vb_in)
			line_cnt <= line_cnt + 1'd1;
		if (vb_in && !vb_q) begin
			line_cnt <= 10'd0;
			dbl      <= !off && line_cnt != 10'd0 && line_cnt < 10'd300;
			lo15     <= line_cnt != 10'd0 && line_cnt < 10'd300;
		end
	end

// The framing is mist-modules' scandoubler_framing: it measures the input
// line against the pixel clock divided by ce_divider + 1 and times the output
// lines, blanking and syncs at twice the rate. The line store is here, 6 bits
// per colour, two lines, in one block RAM.
wire        pe_in, pe_out, line_toggle;
wire [9:0]  hcnt, sd_hcnt;
wire        hb_sd, vb_sd, hs_sd, vs_sd;

/* verilator lint_off PINCONNECTEMPTY */
scandoubler_framing #(.HCNT_WIDTH(10), .HSCNT_WIDTH(12)) framing (
	.clk_sys(clk), .ce_divider(4'd3),
	.hb_in(hb_in), .vb_in(vb_in), .hs_in(hs_in), .vs_in(vs_in),
	.pe_in(pe_in), .hcnt_in(hcnt),
	.hb_out(hb_sd), .vb_out(vb_sd), .hs_out(hs_sd), .vs_out(vs_sd),
	.pe_out(pe_out), .ppe_out(), .hcnt_out(sd_hcnt), .line_out(line_toggle)
);
/* verilator lint_on PINCONNECTEMPTY */

reg [17:0] line_buffer[0:2047];
reg [17:0] line_out;

always @(posedge clk)
	if (pe_in)
		line_buffer[{line_toggle, hcnt}] <= {r_in, g_in, b_in};

always @(posedge clk)
	if (pe_out)
		line_out <= line_buffer[{~line_toggle, sd_hcnt}];

reg hb_o, vb_o, hs_o, vs_o;
always @(posedge clk)
	if (pe_out) begin
		hb_o <= hb_sd;
		vb_o <= vb_sd;
		hs_o <= hs_sd;
		vs_o <= vs_sd;
	end

assign {r_out, g_out, b_out} = dbl ? line_out : {r_in, g_in, b_in};
assign hb_out = dbl ? hb_o : hb_in;
assign vb_out = dbl ? vb_o : vb_in;
assign hs_out = dbl ? hs_o : hs_in;
assign vs_out = dbl ? vs_o : vs_in;

assign double = dbl;
assign ce_out = dbl ? pe_out : ce_in;
reg hs_idle, vs_idle;
always @(posedge clk)
	if (reset) begin
		hs_idle <= 1'b0;
		vs_idle <= 1'b1;
	end else if (ce_in && !hb_in && !vb_in) begin
		hs_idle <= hs_in;
		vs_idle <= vs_in;
	end

// A doubled VSync lasts at most 7 lines. The CGA/EGA ones are 3 lines, 6 once
// doubled; the VGA 13h TV raster has 16, which doubled is a millisecond, more
// than monitors take for a 31.4 kHz picture.
wire hs_act = hs_idle ? !hs_out : hs_out;
wire vs_act = vs_idle ? !vs_out : vs_out;
reg  hs_act_q, vs_cut;
reg [2:0] vs_n;
always @(posedge clk) begin
	hs_act_q <= hs_act;
	if (reset || !dbl || !vs_act) begin
		vs_n   <= 3'd0;
		vs_cut <= 1'b0;
	end else if (hs_act && !hs_act_q) begin
		if (vs_n == 3'd6) vs_cut <= 1'b1;
		else              vs_n <= vs_n + 1'd1;
	end
end

// A 15.7 kHz picture that is not doubled (scandoubler off) leaves with
// +HSync, +VSync, as a CGA monitor and the SCART adapters made for it take
// them, whatever polarity the machine's timing has (+HSync, -VSync for the
// 200-line EGA/CGA modes: a TV fed that lost the picture). The rest passes
// as it comes: the 350-line and VGA modes are told apart by their polarity.
assign hs_pin = dbl ? (!hs_idle ? !hs_out : hs_out) : lo15 ? hs_act : hs_out;
assign vs_pin = dbl ? !(vs_act && !vs_cut) : lo15 ? vs_act : vs_out;

endmodule
