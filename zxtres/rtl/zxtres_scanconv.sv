// Scan converter for the PC/AT pictures a VGA monitor cannot lock to.
//
// The 350-line EGA modes (about 21.8 kHz) and the MDA mode (18.4 kHz) are
// written into a frame store in the SRAM, six bits per pixel, and read out
// on a 27 MHz clock in one of three rasters (`mode`):
//   0  480p: 720x480 at 59.94 Hz (CEA-861: 858x525 dots, 31.5 kHz, -HSync
//      -VSync). The picture is not scaled: it sits centred in the 720x480
//      frame, black around it.
//   2  480i, 15.7 kHz: the same 720x480 frame, half of its lines in each of
//      two fields (858x525 dots at 13.5 MHz, the VSync of the second field
//      half a line late). Both fields come from the same stored frame.
//   3  240p, 15.7 kHz: one progressive field of 262 lines, 224 of them
//      active; the 350 source lines are squeezed into them (25 into 16, so a
//      little over a third are dropped). Nothing flickers.
// The 15.7 kHz rasters leave with +HSync and +VSync, as the not-doubled
// pictures of the machine do (a 15 kHz TV on an adapter needs that), and
// take the CRT H and V offsets of the OSD.
//
// Pictures that need no conversion pass untouched, and `active` stays low
// for them: under 300 lines (the doubler in zxtres_linedouble handles those),
// 400 lines or more, or a line rate over 26 kHz (the VGA profiles, whose
// colours have six bits per channel, more than the store keeps). The choice
// is made per frame, from the line count and line period of the picture.
//
// A pixel is stored as {R[5:4], G[5:4], B[5:4]}. EGA has two bits per
// channel, replicated to six (00, 15h, 2Ah, 3Fh), so it comes back exactly.
//
// Frame store: three buffers of 400 lines x 360 words (two pixels per
// 16-bit word, 12 bits used), 144000 words each. The writer takes a buffer
// that is neither the last complete one nor the one being read out, so the
// reader never sees a frame being written, and the 70 Hz or 50 Hz of the
// source and the 59.94 Hz of the output drift without tearing, a frame
// repeated or dropped now and then.
//
// Read-out is in two clock domains. The 27 MHz side counts the raster and
// reads a line from a block-RAM line store (two banks of 360 words); the
// 57 MHz side fills the bank of the next line from the SRAM during the line
// before it, on a line toggle and a pre-frame level from the 27 MHz side.
module zxtres_scanconv (
	input         clk,            // 57.27 MHz pipeline clock
	input         reset,
	input         ce_in,          // dot enable of the picture
	input         off,
	input   [1:0] mode,           // output raster, see above (1 counts as 0)
	input   [3:0] crt_h,          // picture-to-sync distance, 4 dots a step
	input   [2:0] crt_v,          // picture-to-sync distance, lines
	input   [5:0] r_in,
	input   [5:0] g_in,
	input   [5:0] b_in,
	input         hb_in,
	input         vb_in,
	output        active,         // show the converted picture

	output reg        wr_req,
	output reg [19:0] wr_addr,
	output reg [15:0] wr_data,
	input             wr_grant,
	output reg        rd_req,
	output reg [19:0] rd_addr,
	input             rd_grant,
	input             rd_valid,
	input      [15:0] rd_data,

	input             clk27,
	input             reset27,
	output reg [5:0]  r_out,
	output reg [5:0]  g_out,
	output reg [5:0]  b_out,
	output reg        hb_out,
	output reg        vb_out,
	output reg        hs_out,     // active low in 480p, high at 15.7 kHz
	output reg        vs_out,     // active low in 480p, high at 15.7 kHz
	output            ce_out,     // dot enable of the outputs (clk27, or half)

	output reg [7:0]  lost         // writes that found the port busy, saturating
);

	localparam [19:0] BUF_WORDS = 20'd144000;
	localparam        ROW_WORDS = 360;
	localparam        MAX_LINES = 400;

	// ---------------------------------------------------------------------
	// Picture measurement and capture (clk)
	// ---------------------------------------------------------------------

	reg        hb_q, vb_q;
	reg [11:0] per_cnt, per_last;     // clocks per line
	reg [9:0]  lines;                 // lines of the frame so far
	reg        conv_dec;              // convert the pictures of this size
	reg        cap_on;                // this frame is being written
	reg        have;                  // a complete frame is in the store
	reg [1:0]  wbuf, latest;
	reg [9:0]  xcnt, ycnt, maxw;
	reg [9:0]  lat_w, lat_h;
	reg [19:0] w_rowbase;
	reg [5:0]  pix_a;

	wire [5:0] pix = {r_in[5:4], g_in[5:4], b_in[5:4]};
	reg [1:0]  rbuf;                  // buffer on the output side, set below

	assign active = conv_dec && have;

	// 350-line pictures at under 26 kHz: the EGA 350-line modes and MDA.
	wire dec_next = !off && lines >= 10'd300 && lines < 10'd400 && per_last > 12'd2200;

	function [19:0] base_of(input [1:0] b);
		base_of = b == 2'd0 ? 20'd0 : b == 2'd1 ? BUF_WORDS : 2 * BUF_WORDS;
	endfunction

	function [1:0] pick(input [1:0] a, input [1:0] b);
		pick = (a != 2'd0 && b != 2'd0) ? 2'd0 : (a != 2'd1 && b != 2'd1) ? 2'd1 : 2'd2;
	endfunction

	always @(posedge clk) begin
		if (per_cnt != 12'hfff) per_cnt <= per_cnt + 1'd1;

		if (reset) begin
			hb_q <= 1'b1; vb_q <= 1'b1;
			per_cnt <= 12'd0; per_last <= 12'd0;
			lines <= 10'd0; conv_dec <= 1'b0; cap_on <= 1'b0; have <= 1'b0;
			wbuf <= 2'd0; latest <= 2'd1;
			xcnt <= 10'd0; ycnt <= 10'd0; maxw <= 10'd0;
			lat_w <= 10'd0; lat_h <= 10'd0;
			w_rowbase <= 20'd0;
			wr_req <= 1'b0;
			lost <= 8'd0;
		end else begin
			if (wr_grant) wr_req <= 1'b0;

			if (ce_in) begin
				hb_q <= hb_in;
				vb_q <= vb_in;

				// An active dot: the first of a pair waits, the second makes a word.
				if (cap_on && !hb_in && !vb_in) begin
					if (xcnt != 10'd1023) xcnt <= xcnt + 1'd1;
					if (xcnt < 10'd720 && ycnt < MAX_LINES) begin
						if (!xcnt[0]) pix_a <= pix;
						else begin
							if (wr_req && !wr_grant && lost != 8'hff) lost <= lost + 1'd1;
							wr_req  <= 1'b1;
							wr_addr <= w_rowbase + {11'd0, xcnt[9:1]};
							wr_data <= {4'd0, pix_a, pix};
						end
					end
				end

				// End of a line.
				if (hb_in && !hb_q) begin
					per_last <= per_cnt;
					per_cnt  <= 12'd0;
					if (!vb_in) lines <= lines + 1'd1;
					if (cap_on && !vb_in && xcnt != 10'd0) begin
						if (xcnt[0] && xcnt < 10'd720 && ycnt < MAX_LINES) begin
							wr_req  <= 1'b1;
							wr_addr <= w_rowbase + {11'd0, xcnt[9:1]};
							wr_data <= {4'd0, pix_a, 6'd0};
						end
						if (ycnt < MAX_LINES) begin
							ycnt <= ycnt + 1'd1;
							w_rowbase <= w_rowbase + ROW_WORDS;
							if ((xcnt > 10'd720 ? 10'd720 : xcnt) > maxw)
								maxw <= xcnt > 10'd720 ? 10'd720 : xcnt;
						end
					end
					xcnt <= 10'd0;
				end

				// End of a frame: commit what was written, decide for the next.
				if (vb_in && !vb_q) begin
					lines <= 10'd0;
					conv_dec <= dec_next;
					if (cap_on && ycnt != 10'd0) begin
						latest <= wbuf;
						lat_w  <= maxw;
						lat_h  <= ycnt;
						have   <= 1'b1;
						wbuf   <= pick(wbuf, rbuf);
					end
					if (!dec_next) have <= 1'b0;
					cap_on    <= dec_next;
					ycnt      <= 10'd0;
					maxw      <= 10'd0;
					w_rowbase <= base_of(cap_on && ycnt != 10'd0 ? pick(wbuf, rbuf) : wbuf);
				end
			end
		end
	end

	// ---------------------------------------------------------------------
	// Raster of the output (clk27)
	//
	// 480p counts a dot per clock. The 15.7 kHz rasters count a dot every
	// second clock (13.5 MHz) and keep the 858 dots of the line, so the
	// picture is the same 720 dots wide in all three.
	// ---------------------------------------------------------------------

	localparam [9:0] H_LAST    = 10'd857;
	localparam [9:0] H_SYNC15  = 10'd64;     // 4.7 us
	localparam [9:0] H_GAP15   = 10'd106;    // sync start to picture, CRT H 0
	localparam [9:0] V_GAP_I   = 10'd15;     // field start to picture, CRT V 0
	localparam [9:0] V_GAP_P   = 10'd23;     // 240p: frame start to picture
	localparam [9:0] V_FIELD1  = 10'd262;    // the 263 lines of the first field

	// mode, offsets: slow, taken at the frame boundary
	reg [1:0] md_s1, md_s2;
	reg [3:0] hx_s1, hx_s2;
	reg [2:0] vx_s1, vx_s2;
	always @(posedge clk27) begin
		md_s1 <= mode;  md_s2 <= md_s1;
		hx_s1 <= crt_h; hx_s2 <= hx_s1;
		vx_s1 <= crt_v; vx_s2 <= vx_s1;
	end

	reg [1:0] m27;                  // mode of this frame
	reg [3:0] h27;
	reg [2:0] v27;
	reg       tg;                   // halves the clock at 15.7 kHz
	wire      hz15 = m27[1];
	wire      lace = m27 == 2'd2;
	assign    ce_out = !hz15 || tg;
	wire      ce27   = ce_out;

	reg [9:0] hc, vc;
	reg       ln_t27;               // toggles at hc == 8 of every line

	// What the line fetch is to prepare for the next line: whether it has a
	// picture, which line of the output image that is (of the 480 for 480p
	// and 480i, of the 224 for 240p), which bank of the line store it goes
	// to, and whether the line now being output is the last of the frame.
	// Written with the toggle; the fetch reads them after seeing it.
	reg       fd_act, fd_pre, fd_bank;
	reg [9:0] fd_l;
	reg [1:0] fd_m;

	wire [9:0] vlast  = (m27 == 2'd3) ? 10'd261 : 10'd524;
	wire [9:0] vcn    = (vc == vlast) ? 10'd0 : vc + 1'd1;
	wire [9:0] vb0    = V_GAP_I + {7'd0, v27};          // first picture line, field 0
	wire [9:0] vb1    = V_FIELD1 + vb0;                 // and field 1
	wire [9:0] vbp    = V_GAP_P + {7'd0, v27};
	wire [9:0] gap    = H_GAP15 + {4'd0, h27, 2'b00};

	// The picture lines. 480i: field 0 (lines vb0..) carries the odd lines of
	// the image and field 1, whose picture starts half a line earlier after
	// its VSync, the even ones, so that on the tube image line 2k comes just
	// above line 2k+1.
	wire       av0    = vc >= vb0 && vc < vb0 + 10'd240;
	wire       av1    = vc >= vb1 && vc < vb1 + 10'd240;
	wire       avp    = vc >= vbp && vc < vbp + 10'd224;
	wire       act_v  = !hz15 ? vc < 10'd480 : lace ? (av0 || av1) : avp;
	wire       act_h  = !hz15 ? hc < 10'd720 : (hc >= gap && hc < gap + 10'd720);
	wire [9:0] px     = !hz15 ? hc : hc - gap;

	// VSync of the 15.7 kHz rasters: three lines. In 480i the second field's
	// starts in the middle of line 262, and that half line is what makes a
	// television draw it between the lines of the first.
	wire       vs0    = vc < 10'd3;
	wire       vs1    = (vc == V_FIELD1 && hc >= 10'd429) || vc == 10'd263 ||
	                    vc == 10'd264 || (vc == 10'd265 && hc < 10'd429);

	reg [11:0] linebuf [0:1023];    // {bank, word}: two pixels of six bits
	reg        bw_en;
	reg [9:0]  bw_addr;
	reg [11:0] bw_data;
	always @(posedge clk)
		if (bw_en) linebuf[bw_addr] <= bw_data;

	reg [11:0] rd_q;
	reg        sel_d, act_d, actv_d, hs_d, vs_d;
	always @(posedge clk27) begin
		tg <= reset27 ? 1'b0 : !tg;
		if (reset27) begin
			hc <= 10'd0; vc <= 10'd0; ln_t27 <= 1'b0;
			m27 <= 2'd0; h27 <= 4'd0; v27 <= 3'd0;
			fd_act <= 1'b0; fd_pre <= 1'b0; fd_bank <= 1'b0; fd_l <= 10'd0; fd_m <= 2'd0;
			hb_out <= 1'b1; vb_out <= 1'b1; hs_out <= 1'b1; vs_out <= 1'b1;
			{r_out, g_out, b_out} <= 18'd0;
		end else if (ce27) begin
			if (hc == H_LAST) begin
				hc <= 10'd0;
				if (vc == vlast) begin
					vc  <= 10'd0;
					m27 <= md_s2;
					h27 <= hx_s2;
					v27 <= vx_s2;
				end else vc <= vc + 1'd1;
			end else hc <= hc + 1'd1;

			if (hc == 10'd8) begin
				ln_t27  <= !ln_t27;
				fd_pre  <= vc == vlast;
				fd_bank <= vcn[0];
				fd_m    <= m27;
				if (!hz15) begin
					fd_act <= vcn < 10'd480;
					fd_l   <= vcn;
				end else if (lace) begin
					if (vcn >= vb0 && vcn < vb0 + 10'd240) begin
						fd_act <= 1'b1;
						fd_l   <= {vcn - vb0, 1'b0} + 1'd1;
					end else if (vcn >= vb1 && vcn < vb1 + 10'd240) begin
						fd_act <= 1'b1;
						fd_l   <= {vcn - vb1, 1'b0};
					end else begin
						fd_act <= 1'b0;
						fd_l   <= 10'd0;
					end
				end else begin
					fd_act <= vcn >= vbp && vcn < vbp + 10'd224;
					fd_l   <= vcn - vbp;
				end
			end

			// the line store is read one clock after its address
			rd_q   <= linebuf[{vc[0], px[9:1]}];
			sel_d  <= px[0];
			act_d  <= act_h && act_v;
			actv_d <= act_v;
			hs_d   <= !hz15 ? !(hc >= 10'd736 && hc < 10'd798) : hc < H_SYNC15;
			vs_d   <= !hz15 ? !(vc >= 10'd489 && vc < 10'd495)
			                : (vs0 || (lace && vs1));

			begin : pixel
				reg [5:0] p;
				p = sel_d ? rd_q[5:0] : rd_q[11:6];
				r_out  <= act_d ? {3{p[5:4]}} : 6'd0;
				g_out  <= act_d ? {3{p[3:2]}} : 6'd0;
				b_out  <= act_d ? {3{p[1:0]}} : 6'd0;
				hb_out <= !act_d;
				vb_out <= !actv_d;
				hs_out <= hs_d;
				vs_out <= vs_d;
			end
		end
	end

	// ---------------------------------------------------------------------
	// Line fetch (clk): during a line of the output, the next one is read from
	// the SRAM into the other bank of the line store.
	// ---------------------------------------------------------------------

	reg [2:0] ln_sync;
	always @(posedge clk)
		ln_sync <= {ln_sync[1:0], ln_t27};
	wire ln_ev = ln_sync[2] ^ ln_sync[1];

	localparam [3:0] F_IDLE = 4'd0, F_SETUP = 4'd1, F_ROW1 = 4'd2, F_ROW2 = 4'd3,
	                 F_START = 4'd4, F_ZL = 4'd5, F_RD = 4'd6, F_ZR = 4'd7, F_ZALL = 4'd8;

	reg [3:0]  fst;
	reg        r_have, ok;
	reg [9:0]  rw, rh;
	reg [9:0]  y0;                   // first output line of the picture
	reg [9:0]  ys;                   // picture line to fetch
	reg [8:0]  wwords, x0w;
	reg [19:0] row_addr, t1, t2;
	reg [9:0]  zi, zend;
	reg [8:0]  issued, recv;
	reg        busy_miss;

	// 240p: output line n shows source line 25n/16
	wire [13:0] ys240 = {fd_l, 4'd0} + {1'b0, fd_l, 3'd0} + {4'd0, fd_l};
	wire [9:0]  ysn   = fd_m == 2'd3 ? ys240[13:4] : fd_l - y0;
	wire        ok_n  = fd_m == 2'd3 ? ys240[13:4] < rh
	                                 : (fd_l >= y0 && fd_l - y0 < rh);

	always @(posedge clk) begin
		bw_en <= 1'b0;
		if (reset) begin
			fst <= F_IDLE; rd_req <= 1'b0; r_have <= 1'b0; ok <= 1'b0;
			rbuf <= 2'd2; rw <= 10'd0; rh <= 10'd0; busy_miss <= 1'b0;
		end else begin
			if (rd_grant) begin
				rd_addr <= rd_addr + 1'd1;
				issued  <= issued + 1'd1;
				if (issued + 1'd1 == wwords) rd_req <= 1'b0;
			end

			case (fst)
				F_IDLE: if (ln_ev) begin
					if (fd_pre) begin
						rbuf   <= latest;
						rw     <= lat_w;
						rh     <= lat_h;
						r_have <= have;
					end
					fst <= F_SETUP;
				end

				F_SETUP: begin
					y0      <= (10'd480 - rh) >> 1;
					wwords  <= (rw + 1'd1) >> 1;
					x0w     <= (9'd360 - ((rw + 1'd1) >> 1)) >> 1;
					fst <= fd_act ? F_ROW1 : F_IDLE;
				end

				// which picture line, if any, and its address in the store
				F_ROW1: begin
					ys  <= ysn;
					ok  <= r_have && rw != 10'd0 && rh != 10'd0 && ok_n;
					fst <= F_ROW2;
				end

				F_ROW2: begin
					t1  <= {2'd0, ys, 8'd0} + {4'd0, ys, 6'd0};
					t2  <= {5'd0, ys, 5'd0} + {7'd0, ys, 3'd0};
					fst <= F_START;
				end

				F_START: begin
					zi <= 10'd0;
					if (!ok) begin
						zend <= 10'd359;
						fst  <= F_ZALL;
					end else begin
						row_addr <= base_of(rbuf) + t1 + t2;
						zend <= {1'b0, x0w} - 1'd1;
						fst  <= x0w == 9'd0 ? F_RD : F_ZL;
						if (x0w == 9'd0) begin
							rd_req  <= 1'b1;
							rd_addr <= base_of(rbuf) + t1 + t2;
							issued  <= 9'd0;
							recv    <= 9'd0;
						end
					end
				end

				// zero the margin left of the picture
				F_ZL: begin
					bw_en   <= 1'b1;
					bw_addr <= {fd_bank, zi[8:0]};
					bw_data <= 12'd0;
					zi      <= zi + 1'd1;
					if (zi == zend) begin
						rd_req  <= 1'b1;
						rd_addr <= row_addr;
						issued  <= 9'd0;
						recv    <= 9'd0;
						fst     <= F_RD;
					end
				end

				// the picture: the SRAM words land in order
				F_RD: if (rd_valid) begin
					bw_en   <= 1'b1;
					bw_addr <= {fd_bank, x0w + recv};
					bw_data <= rd_data[11:0];
					recv    <= recv + 1'd1;
					if (recv + 1'd1 == wwords) begin
						zi   <= {1'b0, x0w} + {1'b0, wwords};
						zend <= 10'd359;
						fst  <= (x0w + wwords >= 10'd360) ? F_IDLE : F_ZR;
					end
				end

				F_ZR, F_ZALL: begin
					bw_en   <= 1'b1;
					bw_addr <= {fd_bank, zi[8:0]};
					bw_data <= 12'd0;
					zi      <= zi + 1'd1;
					if (zi == zend) fst <= F_IDLE;
				end

				default: fst <= F_IDLE;
			endcase

			if (fst != F_IDLE && ln_ev) busy_miss <= 1'b1;
		end
	end

endmodule