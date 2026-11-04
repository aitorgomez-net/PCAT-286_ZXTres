// Video information for the OSD page "Video info": the raster on the VGA
// connector and the size of the machine's own picture.
//
// The raster is measured on the pins as they leave (VGA_HS, VGA_VS), whatever
// produced them, with the 50 MHz clock: line and frame periods and the length
// of the HIGH part of each sync (the firmware tells the polarity from it: the
// short level is the pulse), and the lines counted per frame. The picture is
// measured in the pipeline clock domain, before the output stage: the dots of
// a line and the lines of a frame that are not blanked, which is the mode the
// BIOS or the program has set, as the machine makes it (640x200, 720x400...).
//
// The firmware reads it with the MiST user_io command 0x1f (keyboard LEDs,
// which nothing uses): user_io answers every byte of that command with the
// `leds` input, and this module drives `leds` with a different byte for each,
// counting the SPI clocks as user_io does. Reply byte N (the first one after
// the command is 1) is BYTES[N-1]:
//
//    0       0xA5, so that a core without this block (leds = 0) is told
//    1       flags: bit 0 scan converter in use, bit 1 line doubler in use
//    2-3     line period, 50 MHz clocks (0: no signal)
//    4-5     HSync high time, clocks
//    6-8     frame period, clocks (0: no signal)
//    9-11    VSync high time, clocks
//    12-13   HSync periods counted in the last frame
//    14-15   dots per line of the machine's picture
//    16-17   lines per frame of the machine's picture
//
// The values come from other clock domains and are not synchronised bit by
// bit; they hold still for many frames, and the firmware reads them twice.
module zxtres_vidinfo (
	input  logic        clk,            // 50 MHz
	input  logic        hs_pin,
	input  logic        vs_pin,
	input  logic        conv_active,
	input  logic        doubled,

	input  logic        vclk,           // the pipeline clock of the machine's picture
	input  logic        vce,
	input  logic        vhb,
	input  logic        vvb,

	input  logic        spi_sck,
	input  logic        spi_ss,         // high: not selected
	output logic [7:0]  leds
);

// ---------------------------------------------------------------- the pins
logic [2:0] hs_q = 3'b0, vs_q = 3'b0;
always_ff @(posedge clk) begin
	hs_q <= {hs_q[1:0], hs_pin};
	vs_q <= {vs_q[1:0], vs_pin};
end
wire hs_rise = hs_q[1] && !hs_q[2];
wire hs_fall = !hs_q[1] && hs_q[2];
wire vs_rise = vs_q[1] && !vs_q[2];
wire vs_fall = !vs_q[1] && vs_q[2];

logic [15:0] h_cnt = 16'd0, h_hi_cnt = 16'd0, h_period = 16'd0, h_hi = 16'd0;
logic [23:0] v_cnt = 24'd0, v_hi_cnt = 24'd0, v_period = 24'd0, v_hi = 24'd0;
logic [15:0] line_cnt = 16'd0, lines = 16'd0;

always_ff @(posedge clk) begin
	if (h_cnt != 16'hFFFF) h_cnt <= h_cnt + 1'd1; else h_period <= 16'd0;
	if (hs_rise) begin
		h_period <= h_cnt + 1'd1;
		h_cnt    <= 16'd0;
		h_hi_cnt <= 16'd0;
		line_cnt <= line_cnt + 1'd1;
	end else if (hs_q[1] && h_hi_cnt != 16'hFFFF)
		h_hi_cnt <= h_hi_cnt + 1'd1;
	if (hs_fall) h_hi <= h_hi_cnt + 1'd1;

	if (v_cnt != 24'hFFFFFF) v_cnt <= v_cnt + 1'd1; else v_period <= 24'd0;
	if (vs_rise) begin
		v_period <= v_cnt + 1'd1;
		v_cnt    <= 24'd0;
		v_hi_cnt <= 24'd0;
		lines    <= line_cnt;
		line_cnt <= hs_rise ? 16'd1 : 16'd0;
	end else if (vs_q[1] && v_hi_cnt != 24'hFFFFFF)
		v_hi_cnt <= v_hi_cnt + 1'd1;
	if (vs_fall) v_hi <= v_hi_cnt + 1'd1;
end

// -------------------------------------------------------- the machine's picture
logic        hb_q = 1'b1, vb_q = 1'b1;
logic [11:0] dots = 12'd0, lines_act = 12'd0;
logic [11:0] src_dots = 12'd0, src_lines = 12'd0;
always_ff @(posedge vclk)
	if (vce) begin
		hb_q <= vhb;
		vb_q <= vvb;
		if (!vhb && !vvb && dots != 12'hFFF) dots <= dots + 1'd1;
		if (!vhb && hb_q && !vvb && lines_act != 12'hFFF)  // a line of picture starts
			lines_act <= lines_act + 1'd1;
		if (vhb && !hb_q) begin                       // its end
			if (dots != 12'd0) src_dots <= dots;
			dots <= 12'd0;
		end
		if (vvb && !vb_q) begin                       // end of a frame
			src_lines <= lines_act;
			lines_act <= 12'd0;
		end
	end

(* ASYNC_REG = "TRUE" *) logic [27:0] src_s1 = 28'd0, src_s2 = 28'd0;
always_ff @(posedge clk) begin
	src_s1 <= {src_lines, src_dots, 2'b00, doubled, conv_active};
	src_s2 <= src_s1;
end

// ------------------------------------------------------------ the SPI answer
logic [1:0] ss_q = 2'b11;
always_ff @(posedge clk) ss_q <= {ss_q[0], spi_ss};

logic [7:0] live [0:17];
logic [7:0] snap [0:17];
wire [11:0] src_dots_s  = src_s2[15:4];
wire [11:0] src_lines_s = src_s2[27:16];
always_comb begin
	live[0]  = 8'hA5;
	live[1]  = {6'd0, src_s2[1:0]};
	live[2]  = h_period[15:8];
	live[3]  = h_period[7:0];
	live[4]  = h_hi[15:8];
	live[5]  = h_hi[7:0];
	live[6]  = v_period[23:16];
	live[7]  = v_period[15:8];
	live[8]  = v_period[7:0];
	live[9]  = v_hi[23:16];
	live[10] = v_hi[15:8];
	live[11] = v_hi[7:0];
	live[12] = lines[15:8];
	live[13] = lines[7:0];
	live[14] = {4'd0, src_dots_s[11:8]};
	live[15] = src_dots_s[7:0];
	live[16] = {4'd0, src_lines_s[11:8]};
	live[17] = src_lines_s[7:0];
end
// Hold the values while the controller reads them.
always_ff @(posedge clk)
	if (ss_q[1])
		for (int i = 0; i < 18; i++) snap[i] <= live[i];

// The bit and byte counters of user_io.
logic [2:0] bit_cnt = 3'd0;
logic [4:0] byte_cnt = 5'd0;
always_ff @(posedge spi_sck or posedge spi_ss)
	if (spi_ss) begin
		bit_cnt  <= 3'd0;
		byte_cnt <= 5'd0;
	end else begin
		if (bit_cnt == 3'd7 && byte_cnt != 5'd31) byte_cnt <= byte_cnt + 1'd1;
		bit_cnt <= bit_cnt + 1'd1;
	end

assign leds = byte_cnt < 5'd18 ? snap[byte_cnt] : 8'h00;

endmodule
