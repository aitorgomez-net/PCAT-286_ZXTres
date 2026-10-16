//============================================================================
//
//  VGA mode 13h boot splash regression.
//
//  The splash picture is preloaded into the packed mode 13h framebuffer and
//  its colours come from vga_splash_palette. While splashscreen is high the
//  mode 13h raster must own the connector and draw that picture dot for dot:
//
//    - Native (31 kHz / 70 Hz): 640x400 active, each source pixel two clocks
//      wide and each source row on two scanlines.
//    - 15 kHz (60 Hz): 1280 clocks x 200 lines, each source pixel four clocks.
//
//  Every visible pixel of one frame is compared against the RGB666 colour
//  the hex images give for it, in both profiles. A splash whose picture has
//  been overwritten (splash_image_valid low) must stay black instead.
//
//  Run from rtl/video so the hex images resolve, e.g. via
//    TESTBENCH/run_tests.sh vga_splash
//
//  +dump=PREFIX also writes the checked frames, as the connector carries
//  them, to PREFIX_native.ppm (640x400) and PREFIX_15khz.ppm (1280x200).
//
//============================================================================

`timescale 1ns/1ps
`default_nettype wire

module vga_splash_tb;

    reg clk = 1'b0;
    always #17.462 clk = ~clk;   // 28.636363 MHz video clock

    reg reset = 1'b1;
    reg image_valid = 1'b1;

    reg [7:0]  expected_pixel [0:65535];
    reg [17:0] expected_palette [0:255];

    initial begin
        $readmemh("splash_vga_320x200.hex", expected_pixel);
        $readmemh("splash_vga_palette.hex", expected_palette);
    end

    integer errors = 0;

    reg [1023:0] dump_prefix;
    integer      n_dump = 0, t_dump = 0;

    initial begin
        if ($value$plusargs("dump=%s", dump_prefix)) begin
            n_dump = $fopen({dump_prefix, "_native.ppm"}, "w");
            t_dump = $fopen({dump_prefix, "_15khz.ppm"}, "w");
            $fwrite(n_dump, "P3\n640 400\n63\n");
            $fwrite(t_dump, "P3\n1280 200\n63\n");
        end
    end

    // ------------------------------------------------------------------ DUTs
    // Both rasters run side by side from the same clock: n = Native, t = TV.

    wire [15:0] n_fb_addr, t_fb_addr;
    wire        n_fb_read_en, t_fb_read_en;
    wire [7:0]  n_fb_pixel, t_fb_pixel;
    wire        n_fb_valid, t_fb_valid;
    wire [5:0]  n_red, n_green, n_blue, t_red, t_green, t_blue;
    wire        n_de, t_de, n_vblank, t_vblank, n_vsync, t_vsync;
    wire        n_private, t_private, n_vmode_toggle;

    vga_framebuffer #(.INIT_FILE("splash_vga_320x200.hex")) n_fb (
        .clk_cpu(clk), .reset_cpu(reset), .cpu_addr(16'h0000), .cpu_din(8'h00),
        .cpu_read(1'b0), .cpu_write(1'b0), .cpu_dout(), .cpu_ready(), .cpu_written(),
        .clk_video(clk), .video_addr(n_fb_addr), .video_read_en(n_fb_read_en),
        .video_pixel(n_fb_pixel), .video_data_valid(n_fb_valid)
    );

    vga_framebuffer #(.INIT_FILE("splash_vga_320x200.hex")) t_fb (
        .clk_cpu(clk), .reset_cpu(reset), .cpu_addr(16'h0000), .cpu_din(8'h00),
        .cpu_read(1'b0), .cpu_write(1'b0), .cpu_dout(), .cpu_ready(), .cpu_written(),
        .clk_video(clk), .video_addr(t_fb_addr), .video_read_en(t_fb_read_en),
        .video_pixel(t_fb_pixel), .video_data_valid(t_fb_valid)
    );

`define SPLASH_DUT(NAME, NATIVE, VALID, FB_ADDR, FB_RE, FB_PIX, FB_VALID, RED, GREEN, BLUE, DE, VBLANK, VSYNC, PRIVATE, VMODE) \
    ega_top NAME ( \
        .clk(clk), .reset(reset), \
        .bus_a(15'h0000), .bus_ior_l(1'b1), .bus_iow_l(1'b1), .bus_d(8'h00), \
        .bus_out(), .bus_dir(), .bus_aen(1'b0), \
        .ega_fetch_addr(), .ega_fetch_en(), \
        .ega_plane0_data(8'h00), .ega_plane1_data(8'h00), \
        .ega_plane2_data(8'h00), .ega_plane3_data(8'h00), \
        .ega_fetch_data_valid(1'b0), \
        .ega_text_cell_addr(), .ega_text_font_addr(), .ega_text_fetch_en(), \
        .ega_text_char(8'h00), .ega_text_attr(8'h00), .ega_text_glyph(8'h00), \
        .ega_text_data_valid(1'b0), \
        .vga_framebuffer_addr(FB_ADDR), .vga_framebuffer_read_en(FB_RE), \
        .vga_framebuffer_pixel(FB_PIX), .vga_framebuffer_data_valid(FB_VALID), \
        .cpu_mem_select(1'b0), .cpu_mem_write(1'b0), \
        .ega_cfg_toggle(), .ega_plane_write_mask_out(), .ega_odd_even_mode_out(), \
        .ega_cpu_access_slot_out(), .ega_chain2_write_out(), .ega_chain2_read_out(), \
        .ega_extended_memory_out(), .ega_mem_map_sel_out(), .ega_page_select_out(), \
        .ega_write_mode_out(), .ega_read_mode_out(), .ega_read_plane_sel_out(), \
        .ega_color_compare_out(), .ega_color_dont_care_out(), .ega_bit_mask_out(), \
        .ega_set_reset_out(), .ega_enable_set_reset_out(), .ega_rop_select_out(), \
        .ega_rotate_count_out(), .ega_blink_counter_out(), .ega_blink_state_out(), \
        .hsync(), .hblank(), .dbl_hsync(), .vsync(VSYNC), .vblank(VBLANK), \
        .vblank_border(), .std_hsyncwidth(), .de_o(DE), \
        .ega_red(RED), .ega_green(GREEN), .ega_blue(BLUE), \
        .ega_display_sel_out(), .ega_dot_toggle_out(), .ega_dot_clock_sel_out(), \
        .ega_scandouble_active_out(), .ega_mode350_out(), .ega_active_dots_out(), \
        .ega_active_lines_out(), .ega_vmode_toggle_out(VMODE), \
        .splashscreen(1'b1), .splash_image_valid(VALID), .prebios_video(1'b0), \
        .thin_font(1'b0), .scandouble_en(1'b0), .ega_enabled(1'b1), \
        .ega_monitor_profile(2'b00), .vga_enabled(1'b0), \
        .vga_mode13_native(NATIVE), .vga_mode13_set(1'b0), .vga_mode13_clear(1'b0), \
        .vga_mode13_active_out(PRIVATE), .vga_unchained256_active_out(), \
        .vga_mode13_wide_clock_out(), .vga_planar_memory_active_out(), \
        .vga_mode13_pixel_toggle_out(), \
        .crt_h_offset(4'd0), .crt_v_offset(3'd0), \
        .vsync_width_osd(3'd0), .hsync_width_osd(3'd0) \
    );

    `SPLASH_DUT(n_dut, 1'b1, image_valid, n_fb_addr, n_fb_read_en, n_fb_pixel, n_fb_valid,
                n_red, n_green, n_blue, n_de, n_vblank, n_vsync, n_private, n_vmode_toggle)
    `SPLASH_DUT(t_dut, 1'b0, 1'b1, t_fb_addr, t_fb_read_en, t_fb_pixel, t_fb_valid,
                t_red, t_green, t_blue, t_de, t_vblank, t_vsync, t_private, )

    // --------------------------------------------------------------- checker
    // One instance per raster. CLOCKS is the width of a source pixel in video
    // clocks, ROW_LINES the scanlines drawn from each source row.

    task automatic check_pixel;
        input [8*6-1:0] name;
        input integer   row;
        input integer   column;
        input [5:0]     red;
        input [5:0]     green;
        input [5:0]     blue;
        reg   [17:0]    want;
        begin
            want = expected_palette[expected_pixel[row * 320 + column]];
            if ({red, green, blue} !== want) begin
                if (errors < 20)
                    $display("FAIL: %0s pixel (%0d,%0d) is %02h/%02h/%02h, expected %02h/%02h/%02h",
                             name, column, row, red, green, blue,
                             want[17:12], want[11:6], want[5:0]);
                errors = errors + 1;
            end
        end
    endtask

    reg     n_armed = 1'b0, t_armed = 1'b0;
    reg     n_capturing = 1'b0, t_capturing = 1'b0;
    reg     n_done = 1'b0, t_done = 1'b0;
    reg     n_de_q = 1'b0, t_de_q = 1'b0;
    reg     n_vblank_q = 1'b1, t_vblank_q = 1'b1;
    integer n_line = 0, t_line = 0;
    integer n_dot = 0, t_dot = 0;
    integer n_pixels = 0, t_pixels = 0;

    always @(posedge clk) begin
        // ---------------- Native: 2 clocks per pixel, 2 lines per row
        if (n_armed && !n_done) begin
            if (n_vblank_q && !n_vblank) begin
                n_capturing = 1'b1;
                n_line = 0;
            end
            if (n_capturing) begin
                if (n_de) begin
                    if (n_dump)
                        $fwrite(n_dump, "%0d %0d %0d\n", n_red, n_green, n_blue);
                    if ((n_dot % 2) == 1) begin
                        check_pixel("native", n_line / 2, n_dot / 2, n_red, n_green, n_blue);
                        n_pixels = n_pixels + 1;
                    end
                    n_dot = n_dot + 1;
                end
                if (n_de_q && !n_de) begin
                    if (n_dot != 640) begin
                        $display("FAIL: native line %0d is %0d clocks wide, expected 640", n_line, n_dot);
                        errors = errors + 1;
                    end
                    n_line = n_line + 1;
                    n_dot = 0;
                end
                if (!n_vblank_q && n_vblank) begin
                    if (n_line != 400) begin
                        $display("FAIL: native frame has %0d active lines, expected 400", n_line);
                        errors = errors + 1;
                    end
                    n_done = 1'b1;
                end
            end
        end
        n_de_q = n_de;
        n_vblank_q = n_vblank;

        // ---------------- 15 kHz: 4 clocks per pixel, 1 line per row
        if (t_armed && !t_done) begin
            if (t_vblank_q && !t_vblank) begin
                t_capturing = 1'b1;
                t_line = 0;
            end
            if (t_capturing) begin
                if (t_de) begin
                    if (t_dump)
                        $fwrite(t_dump, "%0d %0d %0d\n", t_red, t_green, t_blue);
                    if ((t_dot % 4) == 2) begin
                        check_pixel("15kHz", t_line, t_dot / 4, t_red, t_green, t_blue);
                        t_pixels = t_pixels + 1;
                    end
                    t_dot = t_dot + 1;
                end
                if (t_de_q && !t_de) begin
                    if (t_dot != 1280) begin
                        $display("FAIL: 15kHz line %0d is %0d clocks wide, expected 1280", t_line, t_dot);
                        errors = errors + 1;
                    end
                    t_line = t_line + 1;
                    t_dot = 0;
                end
                if (!t_vblank_q && t_vblank) begin
                    if (t_line != 200) begin
                        $display("FAIL: 15kHz frame has %0d active lines, expected 200", t_line);
                        errors = errors + 1;
                    end
                    t_done = 1'b1;
                end
            end
        end
        t_de_q = t_de;
        t_vblank_q = t_vblank;
    end

    // ------------------------------------------------------------- sequence
    reg     vmode_seen = 1'b0;
    reg     n_vmode_q = 1'b0;
    integer black_violations = 0;
    reg     check_black = 1'b0;

    always @(posedge clk) begin
        if (!reset && (n_vmode_toggle != n_vmode_q))
            vmode_seen <= 1'b1;
        n_vmode_q <= n_vmode_toggle;
        if (check_black && ({n_red, n_green, n_blue} != 18'd0))
            black_violations = black_violations + 1;
    end

    initial begin
        repeat (16) @(posedge clk);
        reset = 1'b0;
        // Skip the frame that was already under way when reset released.
        @(posedge n_vblank);
        n_armed = 1'b1;
        @(posedge t_vblank);
        t_armed = 1'b1;
        wait (n_done && t_done);
        if (n_dump) begin
            $fclose(n_dump);
            $fclose(t_dump);
        end

        if (!n_private || !t_private) begin
            $display("FAIL: the private VGA raster does not own the connector during the splash");
            errors = errors + 1;
        end
        if (!vmode_seen) begin
            $display("FAIL: entering the splash raster did not request a video mode update");
            errors = errors + 1;
        end
        if (n_pixels != 128000) begin
            $display("FAIL: checked %0d native pixels, expected 128000", n_pixels);
            errors = errors + 1;
        end
        if (t_pixels != 64000) begin
            $display("FAIL: checked %0d 15kHz pixels, expected 64000", t_pixels);
            errors = errors + 1;
        end

        // An overwritten picture leaves the splash interval black.
        image_valid = 1'b0;
        repeat (8) @(posedge clk);
        check_black = 1'b1;
        @(posedge n_vblank);
        @(posedge n_vblank);
        check_black = 1'b0;
        if (black_violations != 0) begin
            $display("FAIL: %0d non-black clocks with the splash picture invalid",
                     black_violations);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: splash drawn by the mode 13h raster (Native 640x400, 15 kHz 1280x200)");
        else
            $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #120000000;
        $display("RESULT: FAIL (timeout)");
        $finish;
    end

endmodule
