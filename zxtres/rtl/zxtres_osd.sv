// Character-grid OSD for the DeMiSTify controller.
//
// Replaces mist-modules/osd.v, whose pixel buffer is written under an
// asynchronous reset and read combinationally, so Vivado builds it from
// 17k registers, and whose pixels are 1 dot wide and 2-4 lines high, so the
// menu fills a third to two thirds of a 400-line picture.
//
// The controller still talks to it on the OSD SPI channel (SS3) with the
// MiST commands, but the payload of a write is characters, not pixels, and
// the glyphs come from a ROM here:
//
//   0x20 | row   write row (0-15): attribute byte (bit 0 selected row, bit 1
//                stipple), 32 character codes, then 32 colour bytes (the low
//                3 bits index the palette below; a row that stops short keeps
//                the colours it had)
//   0x30, 0x31   the same for the info row (between the title and the menu)
//                and the help row (below the menu); no attribute use
//   0x40, 0x41   disable, enable
//   0x50 | n     position of the box: 0 centre, 1 top left, 2 top right,
//                3 bottom left, 4 bottom right
//
// Codes 20h-7Fh are ASCII; 80h-9Fh are the menu symbols and icons (arrows,
// check, cross, cycle, ellipsis, rule, drives, ...); anything else draws
// blank. Each glyph is 8 lines
// high and 6 dots wide (8 when the picture has under 300 lines, as a 15 kHz
// picture has few lines and wide dots). At 31 kHz each glyph line is repeated
// so the text rows retain the same on-screen height. The grid is centred by
// default. The selected row is a blue bar with white text, the panel is the
// picture darkened with a blue tint, and the box casts a shadow to the right
// and below.
//
// Derived from mist-modules/osd.v (Till Harbaum and others, GPL v3 or later):
// the SPI command framing and the video timing analysis are theirs. The
// glyphs are built by zxtres/scripts/make_mem.py osdfont from
// rtl/common/font0.hex (jtframe, Jose Tejada, GPL v3) and menu symbols
// drawn for this OSD.

module zxtres_osd #(
	parameter       OSD_X_OFFSET    = 11'd0,
	parameter       OSD_Y_OFFSET    = 11'd0,
	parameter [2:0] OSD_COLOR       = 3'd0,
	parameter       USE_BLANKS      = 1'b0,
	parameter       OUT_COLOR_DEPTH = 6,
	parameter       FONT_FILE       = "osd_font.mem"
) (
	input        clk_sys,
	input        ce,

	// SPI interface
	input        SPI_SCK,
	input        SPI_SS3,
	input        SPI_DI,

	// VGA signals coming from the core
	input [OUT_COLOR_DEPTH-1:0] R_in,
	input [OUT_COLOR_DEPTH-1:0] G_in,
	input [OUT_COLOR_DEPTH-1:0] B_in,
	input        HBlank,
	input        VBlank,
	input        HSync,
	input        VSync,

	// VGA signals going to the video connector
	output [OUT_COLOR_DEPTH-1:0] R_out,
	output [OUT_COLOR_DEPTH-1:0] G_out,
	output [OUT_COLOR_DEPTH-1:0] B_out,

	output reg   osd_enable
);

localparam OSD_ROWS = 16;
localparam OSD_COLS = 32;
localparam FRAME_MARGIN = 2;
localparam TITLE_CHARS  = 15;            // "PCAT-286 ZXTres"
localparam TEXT_ROWS = OSD_ROWS + 2;     // the menu, the info row, the help row
localparam ROW_STRIDE = OSD_COLS + 1;
localparam OSD_H = OSD_ROWS * 8;
localparam BUFFER_BYTES = TEXT_ROWS * ROW_STRIDE;
localparam COLOR_BYTES = TEXT_ROWS * OSD_COLS;
localparam LATENCY = 3;        // ce periods from the position to the pixel
localparam SHADOW_X = 4;       // dots
localparam MARGIN = 8;         // dots and lines kept free in the corners

// *********************************************************************************
// spi client
// *********************************************************************************

// Row r holds its attribute at r*33 and its characters at r*33+1 ... r*33+32.
(* ram_style = "block" *) reg [7:0] row_buffer[0:BUFFER_BYTES-1];
(* ram_style = "block" *) reg [3:0] color_buffer[0:COLOR_BYTES-1];
reg [31:0] row_attr;           // {stipple, inverse} per row

initial osd_enable = 1'b0;
reg  [3:0] osd_pos = 4'd0;     // set by the controller, steady while drawing

reg  [4:0] spi_cnt;
reg  [10:0] spi_addr;
reg  [4:0]  spi_row;
reg  [6:0]  spi_col;
reg  [7:0] spi_sbuf;
reg  [7:0] spi_cmd;

// The framing is osd.v's: eight command bits, then a byte every eight clocks.
always @(posedge SPI_SCK, posedge SPI_SS3) begin
	if(SPI_SS3) begin
		spi_cnt  <= 0;
		spi_addr <= 0;
		spi_row  <= 0;
		spi_col  <= 0;
	end else begin
		spi_sbuf <= {spi_sbuf[6:0], SPI_DI};

		if(spi_cnt < 15) spi_cnt <= spi_cnt + 1'd1;
		else spi_cnt <= 8;

		if(spi_cnt == 7) begin
			spi_cmd  <= {spi_sbuf[6:0], SPI_DI};

			// Row-write commands carry the row number: 0x2n for the menu
			// rows 0-15, 0x30 and 0x31 for the info and help rows.
			if(spi_sbuf[6:3] == 4'b0010) begin
				spi_row  <= {1'b0, spi_sbuf[2:0], SPI_DI};
				spi_col  <= 7'd0;
				spi_addr <= ({7'd0, spi_sbuf[2:0], SPI_DI} * ROW_STRIDE);
			end
			if(spi_sbuf[6:3] == 4'b0011) begin
				spi_row  <= {4'b1000, SPI_DI};
				spi_col  <= 7'd0;
				spi_addr <= SPI_DI ? (11'd17 * ROW_STRIDE) : (11'd16 * ROW_STRIDE);
			end

			// command 0x40: OSDCMDENABLE, OSDCMDDISABLE
			if(spi_sbuf[6:3] == 4'b0100) osd_enable <= SPI_DI;

			// command 0x50: position of the box
			if(spi_sbuf[6:3] == 4'b0101) osd_pos <= {spi_sbuf[2:0], SPI_DI};
		end

		// commands 0x20 and 0x30: OSDCMDWRITE
		if((spi_cmd[7:5] == 3'b001) && (spi_cnt == 15)) begin
			spi_addr <= spi_addr + 1'd1;
			spi_col  <= spi_col + 1'd1;
		end
	end
end

wire       spi_we   = !SPI_SS3 && spi_cmd[7:5] == 3'b001 && spi_cnt == 15;
wire [7:0] spi_data = {spi_sbuf[6:0], SPI_DI};

// A row is its attribute byte (column 0), 32 characters (columns 1-32) and
// 32 colours (columns 33-64). The buffers have no reset, so they map to
// block RAM.
always @(posedge SPI_SCK)
	if(spi_we && spi_col <= 7'd32 && spi_addr < BUFFER_BYTES)
		row_buffer[spi_addr] <= spi_data;

always @(posedge SPI_SCK)
	if(spi_we && spi_col >= 7'd33 && spi_col <= 7'd64)
		color_buffer[{spi_row, spi_col[4:0] - 5'd1}] <= spi_data[3:0];

always @(posedge SPI_SCK)
	if(spi_we && spi_col == 0 && !spi_row[4]) begin
		row_attr[{spi_row[3:0], 1'b0}] <= spi_data[0];
		row_attr[{spi_row[3:0], 1'b1}] <= spi_data[1];
	end

// *********************************************************************************
// video timing and sync polarity analysis
// *********************************************************************************

reg  [10:0] h_cnt;
reg  [10:0] hs_low, hs_high;
wire        hs_pol = hs_high < hs_low;
wire [10:0] dsp_width = (hs_pol & !USE_BLANKS) ? hs_low : hs_high;

reg  [10:0] v_cnt;
reg  [10:0] vs_low, vs_high;
wire        vs_pol = vs_high < vs_low;
wire [10:0] dsp_height = (vs_pol & !USE_BLANKS) ? vs_low : vs_high;

always @(posedge clk_sys) begin
	reg hsD;
	reg vsD;

	if(ce) begin
		if (USE_BLANKS) begin
			h_cnt <= h_cnt + 1'd1;
			if(HBlank) begin
				h_cnt <= 0;
				if (h_cnt != 0) begin
					hs_high <= h_cnt;
					v_cnt <= v_cnt + 1'd1;
				end
			end
			if(VBlank) begin
				v_cnt <= 0;
				if (v_cnt != 0 && vs_high != v_cnt + 1'd1) vs_high <= v_cnt;
			end
		end else begin
			// bring hsync into local clock domain
			hsD <= HSync;

			// falling edge of HSync
			if(!HSync && hsD) begin
				h_cnt <= 0;
				hs_high <= h_cnt;
			end

			// rising edge of HSync
			else if(HSync && !hsD) begin
				h_cnt <= 0;
				hs_low <= h_cnt;
				v_cnt <= v_cnt + 1'd1;
			end else begin
				h_cnt <= h_cnt + 1'd1;
			end

			vsD <= VSync;

			// falling edge of VSync
			if(!VSync && vsD) begin
				v_cnt <= 0;
				// if the difference is only one line, that might be interlaced picture
				if (vs_high != v_cnt + 1'd1) vs_high <= v_cnt;
			end

			// rising edge of VSync
			else if(VSync && !vsD) begin
				v_cnt <= 0;
				if (vs_low != v_cnt + 1'd1) vs_low <= v_cnt;
			end
		end
	end
end

// At 15 kHz use 8-dot cells. At 31 kHz use 6-dot cells and repeat each
// glyph scanline. A fixed title row and a blank spacer row precede the menu.
wire        wide_cell = dsp_height < 11'd300;
wire [10:0] osd_w       = wide_cell ? 11'd256 : 11'd192;
// title row, info row, the 16 menu rows, help row
wire [10:0] content_h   = OSD_H + 11'd24;
wire [10:0] box_w       = osd_w + FRAME_MARGIN * 2;
wire [10:0] box_h_base  = content_h + FRAME_MARGIN * 2;
wire [10:0] box_h       = wide_cell ? box_h_base : box_h_base * 2;

// area in which OSD is being displayed
reg [10:0] h_osd_start;
reg [10:0] v_osd_start;

wire [10:0] free_w = dsp_width  - box_w;
wire [10:0] free_h = dsp_height - box_h;

always @(posedge clk_sys) begin
	case (osd_pos)
		4'd1:    begin h_osd_start <= MARGIN;                   v_osd_start <= MARGIN;                  end
		4'd2:    begin h_osd_start <= free_w - MARGIN;          v_osd_start <= MARGIN;                  end
		4'd3:    begin h_osd_start <= MARGIN;                   v_osd_start <= free_h - MARGIN;         end
		4'd4:    begin h_osd_start <= free_w - MARGIN;          v_osd_start <= free_h - MARGIN;         end
		default: begin h_osd_start <= (free_w >> 1) + OSD_X_OFFSET;
		               v_osd_start <= (free_h >> 1) + OSD_Y_OFFSET;                                     end
	endcase
end

// *********************************************************************************
// character grid renderer: position, character, glyph row, pixel
// *********************************************************************************

// Stage 0: the position LATENCY dots ahead of the dot on the screen.
reg signed [12:0] x0, y0;
reg               wide0;
always @(posedge clk_sys)
	if(ce) begin
		x0    <= $signed({2'b00, h_cnt}) - $signed({2'b00, h_osd_start}) + LATENCY;
		y0    <= $signed({2'b00, v_cnt}) - $signed({2'b00, v_osd_start});
		wide0 <= wide_cell;
	end

wire        in_area0 = x0 >= 0 && x0 < $signed({2'b00, box_w}) && y0 >= 0 && y0 < $signed({2'b00, box_h});
wire signed [12:0] content_x0 = x0 - FRAME_MARGIN;
wire signed [12:0] visual_y0 = wide0 ? y0 : (y0 >>> 1);
wire signed [12:0] content_y0 = visual_y0 - FRAME_MARGIN;
wire        in_content0 = content_x0 >= 0 && content_x0 < $signed({2'b00, osd_w}) &&
                           content_y0 >= 0 && content_y0 < $signed({2'b00, content_h});
wire        header0 = in_content0 && content_y0 < 13'sd8;
wire        info0 = in_content0 && content_y0 >= 13'sd8 && content_y0 < 13'sd16;
wire        menu0 = in_content0 && content_y0 >= 13'sd16 && content_y0 < 13'sd144;
wire        help0 = in_content0 && content_y0 >= 13'sd144;
wire        text0 = info0 || menu0 || help0;
// Shadow: the box moved SHADOW_X dots right and 3 lines (6 at 31 kHz) down.
wire signed [12:0] shadow_y0 = wide0 ? 13'sd3 : 13'sd6;
wire        in_shadow0 = !in_area0 &&
                         x0 >= $signed(13'(SHADOW_X)) && x0 < $signed({2'b00, box_w}) + $signed(13'(SHADOW_X)) &&
                         y0 >= shadow_y0 && y0 < $signed({2'b00, box_h}) + shadow_y0;
wire        frame0 = in_area0 && (x0 < FRAME_MARGIN || x0 >= $signed({2'b00, box_w}) - FRAME_MARGIN ||
                                  visual_y0 < FRAME_MARGIN || visual_y0 >= $signed({2'b00, box_h_base}) - FRAME_MARGIN);
wire        corner0 = frame0 &&
                      ((x0 < 5 || x0 >= $signed({2'b00, box_w}) - 5) &&
                       (visual_y0 < 5 || visual_y0 >= $signed({2'b00, box_h_base}) - 5));
wire [9:0]  x_u        = content_x0[9:0];
wire [8:0]  x_hires    = x_u[8:0];
wire [10:0] menu_y0    = content_y0 - 11'd16;
// x / 6 as (x * 171) >> 10: exact for x < 384.
wire [16:0] x_times    = {8'd0, x_hires} * 17'd171;
wire [5:0]  col0       = wide0 ? x_hires[8:3] : x_times[15:10];
wire [8:0]  cell_start = {2'd0, col0, 1'b0} + {1'd0, col0, 2'b00};
wire [2:0]  cx0        = wide0 ? x_hires[2:0] : x_hires[2:0] - cell_start[2:0];
wire [3:0]  row0       = menu_y0[6:3];
wire [2:0]  gy0        = content_y0[2:0];
// Buffer row: the menu rows 0-15, the info row 16, the help row 17.
wire [4:0]  rowsel0    = info0 ? 5'd16 : (help0 ? 5'd17 : {1'b0, row0});
wire [10:0] row_base0  = ({6'd0, rowsel0} * ROW_STRIDE);
wire [10:0] char_addr0 = text0 ? row_base0 + col0 + 11'd1 : 11'd0;
wire [9:0]  color_addr0 = {rowsel0, col0[4:0]};

// Center the 15-character fixed title in dot space, including the half-cell
// offset that cannot be represented by an integer column on either raster.
wire [10:0] title_width0 = wide0 ? TITLE_CHARS * 8 : TITLE_CHARS * 6;
wire signed [12:0] title_x0 = content_x0 - ((osd_w - title_width0) >> 1);
wire        in_title0 = title_x0 >= 0 && title_x0 < $signed({2'b00, title_width0});
wire [8:0]  title_hires0 = title_x0[8:0];
wire [16:0] title_times0 = {8'd0, title_hires0} * 17'd171;
wire [5:0]  title_col0 = wide0 ? title_hires0[8:3] : title_times0[15:10];
wire [8:0]  title_cell_start0 = {2'd0, title_col0, 1'b0} + {1'd0, title_col0, 2'b00};
wire [2:0]  title_cx0 = wide0 ? title_hires0[2:0] : title_hires0[2:0] - title_cell_start0[2:0];

function automatic [7:0] header_char(input [5:0] index);
    begin
        case (index)
            6'd0:  header_char = "P";
            6'd1:  header_char = "C";
            6'd2:  header_char = "A";
            6'd3:  header_char = "T";
            6'd4:  header_char = "-";
            6'd5:  header_char = "2";
            6'd6:  header_char = "8";
            6'd7:  header_char = "6";
            6'd8:  header_char = " ";
            6'd9:  header_char = "Z";
            6'd10: header_char = "X";
            6'd11: header_char = "T";
            6'd12: header_char = "r";
            6'd13: header_char = "e";
            6'd14: header_char = "s";
            default: header_char = " ";
        endcase
    end
endfunction

// Stage 1: the character code and its colour.
reg [7:0] code1;
reg [2:0] cx1, gy1;
reg [3:0] color1;
reg       in1, shadow1, inv1, stip1, wide1, header1, frame1, corner1;
always @(posedge clk_sys)
	if(ce) begin
		code1 <= header0 ? (in_title0 ? header_char(title_col0) : 8'd32) :
		         (text0 ? row_buffer[char_addr0] : 8'd32);
		color1 <= text0 ? color_buffer[color_addr0] : 4'd0;
		cx1   <= header0 ? title_cx0 : cx0;
		gy1   <= gy0;
		in1   <= in_area0 || in_shadow0;
		shadow1 <= in_shadow0;
		inv1  <= menu0 ? row_attr[{row0, 1'b0}] : 1'b0;
		stip1 <= menu0 ? row_attr[{row0, 1'b1}] : 1'b0;
		wide1 <= wide0;
		header1 <= header0;
		frame1 <= frame0;
		corner1 <= corner0;
	end

// Stage 2: the glyph row.
(* ram_style = "block" *) reg [7:0] glyph_rom[0:1023];
initial $readmemh(FONT_FILE, glyph_rom);

wire        known = code1 >= 8'd32 && code1 < 8'd160;
wire [6:0]  glyph = known ? code1[6:0] - 7'd32 : 7'd0;

reg [7:0] bits2;
reg [2:0] cx2;
reg [3:0] color2;
reg       in2, shadow2, inv2, stip2, wide2, header2, frame2, corner2;
always @(posedge clk_sys)
	if(ce) begin
		bits2 <= glyph_rom[{glyph, gy1}];
		cx2   <= cx1;
		color2 <= color1;
		in2   <= in1;
		shadow2 <= shadow1;
		inv2  <= inv1;
		stip2 <= stip1;
		wide2 <= wide1;
		header2 <= header1;
		frame2 <= frame1;
		corner2 <= corner1;
	end

// Stage 3: the pixel. A 6-dot cell shows glyph columns 1-6.
wire       dot  = wide2 ? bits2[3'd7 - cx2] : bits2[3'd6 - cx2];
wire       keep = !(stip2 && cx2[0]);

reg       text3, inv3, header3, frame3, corner3, shadow3;
reg [2:0] color3;
reg       osd_de;
always @(posedge clk_sys)
	if(ce) begin
		text3   <= dot & keep;
		inv3    <= inv2;
		color3  <= color2[2:0];
		osd_de  <= osd_enable && in2 &&
		           ((USE_BLANKS && !HBlank) || (!USE_BLANKS && HSync != hs_pol)) &&
		           ((USE_BLANKS && !VBlank) || (!USE_BLANKS && VSync != vs_pol));
		header3 <= header2;
		frame3  <= frame2;
		corner3 <= corner2;
		shadow3 <= shadow2;
	end

// The palette of the colour bytes, 6 bits per channel.
localparam SHIFT = OUT_COLOR_DEPTH - 6;
reg [17:0] pal;
always @* begin
	case (color3)
		3'd0:    pal = {6'd63, 6'd63, 6'd63};    // white
		3'd1:    pal = {6'd0,  6'd63, 6'd63};    // cyan
		3'd2:    pal = {6'd63, 6'd63, 6'd0};     // yellow
		3'd3:    pal = {6'd16, 6'd63, 6'd16};    // green
		3'd4:    pal = {6'd63, 6'd16, 6'd16};    // red
		3'd5:    pal = {6'd63, 6'd40, 6'd0};     // orange
		3'd6:    pal = {6'd40, 6'd40, 6'd44};    // grey
		default: pal = {6'd24, 6'd40, 6'd63};    // light blue
	endcase
end

// The panel is the picture at an eighth of its brightness with a blue tint;
// the shadow is the picture at a quarter; the bar of the selected row is blue.
wire [OUT_COLOR_DEPTH-1:0] bg_r = R_in >> 3;
wire [OUT_COLOR_DEPTH-1:0] bg_g = G_in >> 3;
wire [OUT_COLOR_DEPTH-1:0] bg_b = (B_in >> 3) | (1 << (OUT_COLOR_DEPTH - 3));

reg [OUT_COLOR_DEPTH-1:0] osd_r, osd_g, osd_b;
always @* begin
	osd_r = bg_r;
	osd_g = bg_g;
	osd_b = bg_b;
	if (shadow3) begin
		osd_r = R_in >> 2;
		osd_g = G_in >> 2;
		osd_b = B_in >> 2;
	end else if (frame3) begin
		osd_r = 0;
		osd_g = corner3 ? {OUT_COLOR_DEPTH{1'b1}} : 0;
		osd_b = {OUT_COLOR_DEPTH{1'b1}};
	end else if (header3) begin
		if (text3) begin
			osd_r = 0;
			osd_g = {OUT_COLOR_DEPTH{1'b1}};
			osd_b = {OUT_COLOR_DEPTH{1'b1}};
		end
	end else if (inv3) begin
		if (text3) begin
			osd_r = {OUT_COLOR_DEPTH{1'b1}};
			osd_g = {OUT_COLOR_DEPTH{1'b1}};
			osd_b = {OUT_COLOR_DEPTH{1'b1}};
		end else begin
			osd_r = 6'd0 << SHIFT;
			osd_g = 6'd22 << SHIFT;
			osd_b = 6'd50 << SHIFT;
		end
	end else if (text3) begin
		osd_r = pal[17:12] << SHIFT;
		osd_g = pal[11:6]  << SHIFT;
		osd_b = pal[5:0]   << SHIFT;
	end
end

assign R_out = osd_de ? osd_r : R_in;
assign G_out = osd_de ? osd_g : G_in;
assign B_out = osd_de ? osd_b : B_in;

endmodule
