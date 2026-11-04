// zxtres_vidinfo with the real mist-modules user_io: a CGA-like raster
// (912 dots of 4 pipeline clocks per line, 262 lines, 640x200 of picture,
// +HSync of 64 dots, -VSync of 3 lines) and the controller's read of the
// information with command 0x1f.
`timescale 1ns/1ps
module zxtres_vidinfo_tb;
	logic clk50 = 0, clk57 = 0;
	always #10 clk50 = ~clk50;
	always #8.73 clk57 = ~clk57;

	// the raster
	logic [1:0]  div = 0;
	logic [9:0]  dot = 0;
	logic [8:0]  line = 0;
	always_ff @(posedge clk57) begin
		div <= div + 1'd1;
		if (div == 2'd3) begin
			if (dot == 10'd911) begin
				dot <= 0;
				line <= line == 9'd261 ? 9'd0 : line + 1'd1;
			end else dot <= dot + 1'd1;
		end
	end
	wire vce = div == 2'd0;
	wire vhb = dot < 10'd272;
	wire vvb = line >= 9'd200;
	logic hs_pin, vs_pin;
	always_ff @(posedge clk57) begin
		hs_pin <= dot < 10'd64;
		vs_pin <= !(line >= 9'd224 && line < 9'd227);
	end

	logic spi_sck = 0, spi_ss = 1, spi_mosi = 0;
	wire spi_miso;
	wire [7:0] leds;
	zxtres_vidinfo dut (.clk(clk50), .hs_pin(hs_pin), .vs_pin(vs_pin),
		.conv_active(1'b0), .doubled(1'b1),
		.vclk(clk57), .vce(vce), .vhb(vhb), .vvb(vvb),
		.spi_sck(spi_sck), .spi_ss(spi_ss), .leds(leds));

	wire [63:0] status;
	user_io #(.STRLEN(8), .PS2DIV(2000), .SD_IMAGES(5)) u_user_io (
		.conf_str("PCAT286;"), .conf_addr(), .conf_chr(8'h00),
		.clk_sys(clk50), .clk_sd(clk50),
		.SPI_CLK(spi_sck), .SPI_SS_IO(spi_ss), .SPI_MISO(spi_miso), .SPI_MOSI(spi_mosi),
		.joystick_0(), .joystick_1(), .joystick_2(), .joystick_3(),
		.joystick_4(), .joystick_analog_0(), .joystick_analog_1(),
		.buttons(), .switches(), .scandoubler_disable(), .ypbpr(), .no_csync(),
		.status(status), .core_mod(), .rtc(),
		.sd_lba(), .sd_rd(), .sd_wr(),
		.sd_ack(), .sd_ack_conf(), .sd_ack_x(), .sd_conf(1'b0), .sd_sdhc(1'b1),
		.sd_dout(), .sd_dout_strobe(), .sd_din(8'h00),
		.sd_din_strobe(), .sd_buff_addr(),
		.img_mounted(), .img_size(),
		.ps2_kbd_clk(), .ps2_kbd_data(), .ps2_kbd_clk_i(1'b1), .ps2_kbd_data_i(1'b1),
		.ps2_mouse_clk(), .ps2_mouse_data(), .ps2_mouse_clk_i(1'b1), .ps2_mouse_data_i(1'b1),
		.key_pressed(), .key_extended(), .key_code(), .key_strobe(),
		.kbd_out_data(8'h00), .kbd_out_strobe(1'b0), .leds(leds),
		.mouse_x(), .mouse_y(), .mouse_z(), .mouse_flags(), .mouse_strobe(), .mouse_idx(),
		.i2c_start(), .i2c_read(), .i2c_addr(), .i2c_subaddr(), .i2c_dout(),
		.i2c_din(8'h00), .i2c_ack(1'b0), .i2c_end(1'b0),
		.serial_data(8'h00), .serial_strobe(1'b0)
	);

	// One SPI byte, master side: returns what the core sends back.
	task automatic xfer(input [7:0] out, output [7:0] in);
		for (int b = 7; b >= 0; b--) begin
			spi_mosi = out[b];
			#100 spi_sck = 1;
			in[b] = spi_miso;
			#100 spi_sck = 0;
		end
	endtask

	logic [7:0] d [0:17];
	logic [7:0] x;
	int errors = 0;
	task automatic check(input string name, input int got, input int lo, input int hi);
		if (got < lo || got > hi) begin
			$display("FAIL %s = %0d, expected %0d..%0d", name, got, lo, hi);
			errors++;
		end else $display("ok   %s = %0d", name, got);
	endtask

	initial begin
		#80_000_000;                 // four frames and more
		spi_ss = 0;
		#200;
		xfer(8'h1f, x);
		for (int i = 0; i < 18; i++) xfer(8'hff, d[i]);
		#200 spi_ss = 1;
		check("signature", d[0], 8'hA5, 8'hA5);
		check("flags", d[1], 2, 2);
		check("line period", {d[2], d[3]}, 3183, 3185);
		check("hsync high", {d[4], d[5]}, 222, 225);
		check("frame period", {d[6], d[7], d[8]}, 834_000, 835_000);
		// the high level is the long one for a -VSync: the pulse is the low time
		check("vsync low", {d[6], d[7], d[8]} - {d[9], d[10], d[11]}, 3 * 3183 - 10, 3 * 3183 + 10);
		check("lines per frame", {d[12], d[13]}, 262, 262);
		check("dots", {d[14], d[15]}, 640, 640);
		check("picture lines", {d[16], d[17]}, 200, 200);
		if (errors == 0) $display("PASS zxtres_vidinfo_tb"); else $display("FAILED %0d", errors);
		$finish;
	end
endmodule
