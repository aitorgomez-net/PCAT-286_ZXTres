// Board-level simulation of the ZXTRES+ PCAT target with Verilator (the
// DeMiSTify controller converted from VHDL by GHDL): the controller runs its
// real firmware against an SD card model
// holding a FAT16 image, a PS/2 keyboard model follows a script, and VGA
// frames are captured as PPM files at each step:
//
//   shot0_loading        while the firmware loads the files (machine in reset)
//   shot1_running        after start-up
//   shot2_osd_menu       F12: the OSD menu
//   shot3_file_selector  Load ROM: the files on the SD card
//   shot4_file_loaded    after loading the first file from the selector
//   shot5_option         Test switch turned on
//   shot6_keys           OSD closed, a key typed into the core
`timescale 1ns/1ps
module zxtres_pcat_tb;
    logic clock_50 = 1'b0;
    always #10 clock_50 = !clock_50;

    logic [7:0] vga_r, vga_g, vga_b;
    logic vga_hs, vga_vs, led;
    logic sd_cs, sd_sck, sd_mosi, sd_miso;
    wire  ps2_kbd_clk, ps2_kbd_dat, ps2_mouse_clk, ps2_mouse_dat;
    pullup (ps2_kbd_clk);
    pullup (ps2_kbd_dat);
    pullup (ps2_mouse_clk);
    pullup (ps2_mouse_dat);
    wire  [15:0] sdram_dq;

    wire  [19:0] sram_a;
    wire  [15:0] sram_q;
    wire         sram_we, sram_oe, sram_ub, sram_lb;
    zxtres_sram_model u_sram (.SRAM_A(sram_a), .SRAM_Q(sram_q), .SRAM_WE(sram_we),
                              .SRAM_OE(sram_oe), .SRAM_UB(sram_ub), .SRAM_LB(sram_lb));

    /* verilator lint_off PINCONNECTEMPTY */
    zxtres_pcat_top dut (
        .CLOCK_50(clock_50), .LED(led),
        .VGA_R(vga_r), .VGA_G(vga_g), .VGA_B(vga_b), .VGA_HS(vga_hs), .VGA_VS(vga_vs),
        .SRAM_A(sram_a), .SRAM_Q(sram_q), .SRAM_WE(sram_we), .SRAM_OE(sram_oe),
        .SRAM_UB(sram_ub), .SRAM_LB(sram_lb),
        .SDRAM_A(), .SDRAM_DQ(sdram_dq), .SDRAM_DQML(), .SDRAM_DQMH(), .SDRAM_nWE(),
        .SDRAM_nCAS(), .SDRAM_nRAS(), .SDRAM_nCS(), .SDRAM_BA(), .SDRAM_CLK(), .SDRAM_CKE(),
        .SD_CS(sd_cs), .SD_SCK(sd_sck), .SD_MOSI(sd_mosi), .SD_MISO(sd_miso),
        .PS2_KEYBOARD_CLK(ps2_kbd_clk), .PS2_KEYBOARD_DAT(ps2_kbd_dat),
        .PS2_MOUSE_CLK(ps2_mouse_clk), .PS2_MOUSE_DAT(ps2_mouse_dat),
        .JOY_CLK(), .JOY_LOAD(), .JOY_DATA(1'b1), .JOY_SEL(),
        .AUDIO_L(), .AUDIO_R(), .I2S_BCK(), .I2S_LRCK(), .I2S_DATA()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    sd_card_model #(.IMAGE("sd.img.sparse"), .BLOCKS(16384)) u_sd (
        .sclk(sd_sck), .cs_n(sd_cs), .mosi(sd_mosi), .miso(sd_miso)
    );

    // ------------------------------------------------------------------
    // PS/2 keyboard: device-to-host frames on open-collector lines.
    logic kbd_clk_low = 1'b0, kbd_dat_low = 1'b0;
    assign ps2_kbd_clk = kbd_clk_low ? 1'b0 : 1'bz;
    assign ps2_kbd_dat = kbd_dat_low ? 1'b0 : 1'bz;

    task automatic ps2_send(input logic [7:0] b);
        logic [10:0] frame;
        frame = {1'b1, ~^b, b, 1'b0};                    // stop, odd parity, data, start
        for (int i = 0; i < 11; i++) begin
            kbd_dat_low = !frame[i];
            #20us kbd_clk_low = 1'b1;
            #40us kbd_clk_low = 1'b0;
            #20us;
        end
        kbd_dat_low = 1'b0;
        #200us;
    endtask
    task automatic key(input logic [7:0] code, input bit extended = 0);
        if (extended) ps2_send(8'hE0);
        ps2_send(code);
        #5ms;
        if (extended) ps2_send(8'hE0);
        ps2_send(8'hF0);
        ps2_send(code);
        #20ms;
    endtask

    // ------------------------------------------------------------------
    // VGA capture, as in zxtres_demo_tb: VSYNC falls at the start of line
    // 490, so dot t after it is line (490 + t / 800) % 525, column t % 800.
    logic vs_q = 1'b1;
    logic clk_pix;
    assign clk_pix = dut.guest.clk_pix;
    bit     capture_request = 0, capturing = 0;
    string  capture_name;
    int     capture_fd;
    longint t = 0;
    always @(posedge clk_pix) begin
        vs_q <= vga_vs;
        if (capture_request && !capturing && vs_q && !vga_vs) begin
            capture_fd = $fopen({capture_name, ".ppm"}, "wb");
            $fwrite(capture_fd, "P6\n640 480\n255\n");
            capturing = 1;
            t = 0;
        end
        if (capturing) begin
            int x, y;
            x = int'(t % 800);
            y = int'((490 + t / 800) % 525);
            if (x < 640 && y < 480) $fwrite(capture_fd, "%c%c%c", vga_r, vga_g, vga_b);
            t = t + 1;
            if (t == 800 * 525) begin
                $fclose(capture_fd);
                capturing = 0;
                capture_request = 0;
                $display("[%0t] captured %s", $time, capture_name);
            end
        end
    end
    task automatic shot(input string name);
        capture_name = name;
        capture_request = 1;
        wait (!capture_request);
    endtask

    // Progress log.
    logic download_q = 0, hold_q = 1;
    always @(posedge clock_50) begin
        download_q <= dut.guest.ioctl_download;
        hold_q <= dut.guest.status[0];
        if (dut.guest.ioctl_download && !download_q)
            $display("[%0t] download start, index %02h", $time, dut.guest.ioctl_index);
        if (!dut.guest.ioctl_download && download_q)
            $display("[%0t] download end: %0d bytes, sum %04h", $time,
                     dut.guest.rom_bytes, dut.guest.rom_sum);
        if (hold_q != dut.guest.status[0])
            $display("[%0t] status[0] (machine reset) = %0d", $time, dut.guest.status[0]);
    end

    // OSD state as the guest's osd module sees it.
    wire osd_open = dut.guest.u_osd.osd_enable;
    task automatic set_osd(input bit open);
        if (osd_open !== open) key(8'h07);               // F12 toggles the OSD
        #30ms;
        if (osd_open !== open) $display("[%0t] OSD did not %s", $time, open ? "open" : "close");
    endtask

    initial begin
        $display("zxtres_pcat_tb: start");
        // The firmware holds status bit 0 while it loads; catch one frame then.
        wait (dut.guest.ioctl_download);
        shot("shot0_loading");
        wait (hold_q === 1'b0 && dut.guest.status[0] === 1'b0);
        #150ms;
        shot("shot1_running");
        // The menu opens with the cursor on Exit, the last row.
        set_osd(1);
        shot("shot2_osd_menu");
        key(8'h7D, 1);                                   // Page Up: first row, Load ROM
        key(8'h5A);                                      // Enter: file selector
        #30ms;
        shot("shot3_file_selector");
        // The selector also opens on its last row (Back).
        key(8'h7D, 1);                                   // Page Up: first file
        key(8'h5A);                                      // Enter: load it
        #150ms;
        shot("shot4_file_loaded");
        set_osd(1);
        key(8'h7D, 1);                                   // Page Up
        key(8'h72, 1);                                   // Down: Test switch
        key(8'h5A);                                      // Enter: On
        #30ms;
        set_osd(1);
        shot("shot5_option");
        set_osd(0);
        key(8'h1C);                                      // A
        #30ms;
        shot("shot6_keys");
        $display("status %016h keys %06h", dut.guest.status, dut.guest.keys);
        $display("ZXTRES_PCAT_SIM_END");
        $finish;
    end

    // Heartbeat: simulated time, flushed so progress is visible in the log.
    initial forever begin
        #1ms;
        $display("[heartbeat] %0t ms", $time / 1000000000);
        $fflush();
    end

    initial begin
        #2000ms;
        $display("ZXTRES_PCAT_SIM_TIMEOUT");
        $finish;
    end
endmodule
