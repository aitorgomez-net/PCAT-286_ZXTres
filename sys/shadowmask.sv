module shadowmask #(parameter AT_CDC = 0, parameter AT_VIDEO_ENABLE = 0)
(
	input             clk,
	input             clk_sys,

	input             cmd_wr,
	input      [15:0] cmd_in,
	input             cmd_active,

	input      [23:0] din,
	input             hs_in,vs_in,
	input             de_in,
	input             brd_in,
	input             enable,

	output reg [23:0] dout,
	output reg        hs_out,vs_out,
	output reg        de_out
);


wire [4:0] hmax;
wire [4:0] vmax;
reg  [7:0] mask_idx;
wire       mask_2x;
wire       mask_rotate;
wire       mask_enable;
reg [10:0] mask_lut[256];

generate if (AT_CDC) begin : g_at_config
	reg [2:0] flags_sys = 0;
	reg [3:0] hmax_sys = 0, vmax_sys = 0;
	reg [7:0] idx = 0;
	reg active_sys_q = 0;
	reg [10:0] config_committed_q = 0;
	wire [10:0] config_pending;
	reg [10:0] config_active_q = 0;
	reg vs_seen = 0;

	// Main_MiSTer sends flags, LUT words, HMAX, VMAX, then releases UIO.
	// Keep every LUT write in clk_sys, including back-to-back commands or a
	// stopped HDMI clock. A latest-value mailbox must not carry this stream.
	always @(posedge clk_sys) begin
		active_sys_q <= cmd_active;
		if (cmd_wr) begin
			case (cmd_in[15:13])
				3'b000: begin flags_sys <= cmd_in[3:1]; idx <= 0; end
				3'b001: vmax_sys <= cmd_in[3:0];
				3'b010: hmax_sys <= cmd_in[3:0];
				3'b011: begin mask_lut[idx] <= cmd_in[10:0]; idx <= idx + 1'b1; end
			endcase
		end
		if (active_sys_q && !cmd_active)
			config_committed_q <= {flags_sys, hmax_sys, vmax_sys};
	end

	// Legacy AT callers supply enable in clk_sys. The frame-config wrapper
	// supplies it in HDMI instead; keep that local gate out of the sys mailbox.
	at_cdc_snapshot #(.WIDTH(11)) config_mailbox (
		.src_clk(clk_sys), .src_send(!cmd_active),
		.src_data({config_committed_q[10] & (AT_VIDEO_ENABLE ? 1'b1 : enable), config_committed_q[9:0]}),
		.src_ready(), .dst_clk(clk), .dst_data(config_pending), .dst_update()
	);
	always @(posedge clk) begin
		vs_seen <= vs_in;
		if (vs_seen && !vs_in) config_active_q <= config_pending;
	end
	assign mask_enable = config_active_q[10] & (AT_VIDEO_ENABLE ? enable : 1'b1);
	assign {mask_rotate, mask_2x} = config_active_q[9:8];
	assign hmax = {1'b0, config_active_q[7:4]};
	assign vmax = {1'b0, config_active_q[3:0]};
end else begin : g_legacy_config
	reg [4:0] hmax_sys, vmax_sys;
	reg mask_2x_sys, mask_rotate_sys, mask_enable_sys;
	assign hmax = hmax_sys;
	assign vmax = vmax_sys;
	assign mask_2x = mask_2x_sys;
	assign mask_rotate = mask_rotate_sys;
	assign mask_enable = mask_enable_sys;
	always @(posedge clk_sys) begin
		reg m_enable;
		reg [7:0] idx;
		if (cmd_wr) begin
			case(cmd_in[15:13])
			3'b000: begin {m_enable, mask_rotate_sys, mask_2x_sys} <= cmd_in[3:1]; idx <= 0; end
			3'b001: vmax_sys <= cmd_in[3:0];
			3'b010: hmax_sys <= cmd_in[3:0];
			3'b011: begin mask_lut[idx] <= cmd_in[10:0]; idx <= idx + 1'd1; end
			endcase
		end
		mask_enable_sys <= m_enable & enable;
	end
end endgenerate

always @(posedge clk) begin
	reg [4:0] hcount;
	reg [4:0] vcount;
	reg [3:0] hindex;
	reg [3:0] vindex;
	reg [4:0] hmax2;
	reg [4:0] vmax2;
	reg [11:0] pcnt,pde;
	reg old_hs, old_vs, old_brd;
	reg next_v;

	old_hs <= hs_in;
	old_vs <= vs_in;
	old_brd<= brd_in;

	// hcount and vcount counts pixel rows and columns
	// hindex and vindex half the value of the counters for double size patterns
	// hindex2, vindex2 swap the h and v counters for drawing rotated masks
	hindex <= mask_2x ? hcount[4:1] : hcount[3:0];
	vindex <= mask_2x ? vcount[4:1] : vcount[3:0];
	mask_idx <= mask_rotate ? {hindex,vindex} : {vindex,hindex};

	// hmax and vmax store these sizes
	// hmax2 and vmax2 swap the values to handle rotation
	hmax2 <= ((mask_rotate ? vmax : hmax) << mask_2x) | mask_2x;
	vmax2 <= ((mask_rotate ? hmax : vmax) << mask_2x) | mask_2x;

	pcnt <= pcnt+1'd1;
	if(old_brd && ~brd_in) pde <= pcnt-4'd3;

	hcount <= hcount+1'b1;
	if(hcount == hmax2 || pde == pcnt) hcount <= 0;

	if(~old_brd && brd_in) next_v <= 1;
	if(old_vs && ~vs_in) vcount <= 0;
	if(old_hs && ~hs_in) begin
		vcount <= vcount + next_v;
		next_v <= 0;
		pcnt   <= 0;
		if (vcount == vmax2) vcount <= 0;
	end
end

reg [4:0] r_mul, g_mul, b_mul; // 1.4 fixed point multipliers
always @(posedge clk) begin
	reg [10:0] lut;

	lut <= mask_lut[mask_idx];

	r_mul <= 5'b10000; g_mul <= 5'b10000; b_mul <= 5'b10000; // default 100% to all channels
	if (mask_enable) begin
		r_mul <= lut[10] ? {1'b1,lut[7:4]} : {1'b0,lut[3:0]};
		g_mul <= lut[9]  ? {1'b1,lut[7:4]} : {1'b0,lut[3:0]};
		b_mul <= lut[8]  ? {1'b1,lut[7:4]} : {1'b0,lut[3:0]};
	end
end

always @(posedge clk) begin
	reg [11:0] vid;
	reg  [7:0] r1,   g1,   b1;
	reg  [7:0] r2,   g2,   b2;
	reg  [7:0] r3_x, g3_x, b3_x; // 6.25% + 12.5%
	reg  [8:0] r3_y, g3_y, b3_y; // 25% + 50% + 100%
	reg  [8:0] r4,   g4,   b4;

	// C1 - data input
	{r1,g1,b1} <= din;
	vid <= {vid[8:0],vs_in, hs_in, de_in};

	// C2 - relax timings
	{r2,g2,b2} <= {r1,g1,b1};

	// C3 - perform multiplications
	r3_x <= ({4{r_mul[0]}} & r2[7:4]) + ({8{r_mul[1]}} & r2[7:3]);
	r3_y <= ({6{r_mul[2]}} & r2[7:2]) + ({7{r_mul[3]}} & r2[7:1]) + ({9{r_mul[4]}} & r2[7:0]);
	g3_x <= ({4{g_mul[0]}} & g2[7:4]) + ({8{g_mul[1]}} & g2[7:3]);
	g3_y <= ({6{g_mul[2]}} & g2[7:2]) + ({7{g_mul[3]}} & g2[7:1]) + ({9{g_mul[4]}} & g2[7:0]);
	b3_x <= ({4{b_mul[0]}} & b2[7:4]) + ({8{b_mul[1]}} & b2[7:3]);
	b3_y <= ({6{b_mul[2]}} & b2[7:2]) + ({7{b_mul[3]}} & b2[7:1]) + ({9{b_mul[4]}} & b2[7:0]);

	// C4 - combine results
	r4 <= r3_x + r3_y;
	g4 <= g3_x + g3_y;
	b4 <= b3_x + b3_y;

	// C5 - clamp and output
	dout <= {{8{r4[8]}} | r4[7:0], {8{g4[8]}} | g4[7:0], {8{b4[8]}} | b4[7:0]};
	{vs_out,hs_out,de_out} <= vid[11:9];
end

endmodule
