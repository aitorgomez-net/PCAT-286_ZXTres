// Board-level simulation of the PCAT-286 ZXTRES+ target booting a real
// BIOS: the DeMiSTify controller (GHDL-converted, real firmware) loads
// PCAT286.ROM and EGA.ROM from an SD card model into the SDRAM model, the
// AT machine runs POST, and VGA frames are captured at the picture's own
// resolution. The script, driven by plusargs:
//
//   +PROMPT=<text>       the POST frame is taken when this text appears in
//                        the colour text buffer (default "Press ESC")
//   +POST_MS=<ms>        longest wait for the prompt after the machine starts
//                        (default 8000); the POST frame is taken then anyway
//   +SETUP_KEYS=<hex>    set-2 scan codes, up to 8, pressed one by one to
//                        enter setup (default 76: Esc). E0-prefixed codes use
//                        the form E0xx.
//   +SETUP_MS=<ms>       wait after the keys before the setup frame (500)
//
// CPU writes to B8000-BFFFF are mirrored into a shadow text buffer, which
// the prompt search uses and which is printed to the log with each frame
// and, when it has changed, every 250 ms.
//
// Frames: post.ppm, post_osd.ppm, setup.ppm, setup_osd.ppm.
`timescale 1ns/1ps
module zxtres_pcat_bios_tb;
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
    logic [12:0] sdram_a;
    logic [1:0]  sdram_ba;
    logic sdram_clk, sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;
    logic sdram_dqml, sdram_dqmh;

    /* verilator lint_off PINCONNECTEMPTY */
    zxtres_pcat_top dut (
        .CLOCK_50(clock_50), .LED(led),
        .VGA_R(vga_r), .VGA_G(vga_g), .VGA_B(vga_b), .VGA_HS(vga_hs), .VGA_VS(vga_vs),
        .SDRAM_A(sdram_a), .SDRAM_DQ(sdram_dq), .SDRAM_DQML(sdram_dqml), .SDRAM_DQMH(sdram_dqmh),
        .SDRAM_nWE(sdram_we_n), .SDRAM_nCAS(sdram_cas_n), .SDRAM_nRAS(sdram_ras_n),
        .SDRAM_nCS(sdram_cs_n), .SDRAM_BA(sdram_ba), .SDRAM_CLK(sdram_clk), .SDRAM_CKE(sdram_cke),
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

    // SDRAM: the ZXTRES chip has dedicated DQM pins. The model is clocked
    // by the system clock, as in the PCAT SDRAM tests: SDRAM_CLK leaves the
    // ODDR in phase with it, and the chip samples what the controller
    // launched on the previous edge. Clocking the model from the ODDR model
    // output instead would make it see each command in the same time step
    // the controller issues it, one cycle early.
    wire [15:0] model_dq;
    wire [1:0]  model_dq_valid;
    /* verilator lint_off PINCONNECTEMPTY */
    spk286_sdram_pin_model #(.DQM_FROM_ADDRESS(1'b0), .MEM_WORDS(1 << 24)) u_sdram (
        .clk(clock_50), .reset(1'b0), .address(sdram_a), .cke(sdram_cke),
        .cs_n(sdram_cs_n), .ras_n(sdram_ras_n), .cas_n(sdram_cas_n), .we_n(sdram_we_n),
        .ba(sdram_ba), .dq_from_controller(sdram_dq),
        .controller_dq_oe(!dut.guest.sdram_dq_io), .dqm({sdram_dqmh, sdram_dqml}),
        .dq_to_controller(model_dq), .dq_valid(model_dq_valid),
        .read_count(), .write_count()
    );
    /* verilator lint_on PINCONNECTEMPTY */
    assign sdram_dq = (model_dq_valid != 2'b00) ? model_dq : 16'hzzzz;

    // ------------------------------------------------------------------
    // PS/2 keyboard model.
    logic kbd_clk_low = 1'b0, kbd_dat_low = 1'b0;
    assign ps2_kbd_clk = kbd_clk_low ? 1'b0 : 1'bz;
    assign ps2_kbd_dat = kbd_dat_low ? 1'b0 : 1'bz;
    task automatic ps2_send(input logic [7:0] b);
        logic [10:0] frame;
        int bit_index;
        frame = {1'b1, ~^b, b, 1'b0};
        bit_index = 0;
        while (bit_index < 11) begin
            kbd_dat_low = !frame[bit_index];
            #20us kbd_clk_low = 1'b1;
            #40us kbd_clk_low = 1'b0;
            #20us;
            bit_index = bit_index + 1;
        end
        kbd_dat_low = 1'b0;
        #200us;
    endtask
    task automatic key(input logic [15:0] code);
        if (code[15:8] == 8'hE0) ps2_send(8'hE0);
        ps2_send(code[7:0]);
        #5ms;
        if (code[15:8] == 8'hE0) ps2_send(8'hE0);
        ps2_send(8'hF0);
        ps2_send(code[7:0]);
        #20ms;
    endtask
    wire osd_open = dut.guest.u_osd.osd_enable;
    task automatic set_osd(input bit open);
        if (osd_open !== open) key(16'h0007);            // F12
        #30ms;
        if (osd_open !== open) $display("[%0t] OSD did not %s", $time, open ? "open" : "close");
    endtask

    // ------------------------------------------------------------------
    // Frame capture at the picture's own size: one frame starts when VBlank
    // ends; each run of DE dots on a video_ce is one line.
    wire       clk_video = dut.guest.at_video_clk_57;
    wire       video_ce  = dut.guest.video_ce;
    wire       video_de  = dut.guest.video_de;
    wire       video_vb  = dut.guest.at_video_mono_vb;
    bit        capture_request = 0, capturing = 0;
    string     capture_name;
    logic [23:0] pixels [$];
    int        line_width = 0, width = 0, height = 0;
    logic      de_q = 1'b0, vb_q = 1'b1;
    always @(posedge clk_video) begin
        vb_q <= video_vb;
        if (!capturing && capture_request && vb_q && !video_vb) begin
            capturing = 1;
            pixels.delete();
            width = 0;
            height = 0;
            line_width = 0;
        end else if (capturing && !vb_q && video_vb) begin
            int fd, pixel_index;
            capturing = 0;
            fd = $fopen({capture_name, ".ppm"}, "wb");
            $fwrite(fd, "P6\n%0d %0d\n255\n", width, height);
            pixel_index = 0;
            while (pixel_index < pixels.size()) begin
                $fwrite(fd, "%c%c%c", pixels[pixel_index][23:16], pixels[pixel_index][15:8],
                        pixels[pixel_index][7:0]);
                pixel_index = pixel_index + 1;
            end
            $fclose(fd);
            capture_request = 0;
            $display("[%0t] captured %s (%0dx%0d)", $time, capture_name, width, height);
        end
        if (capturing && video_ce) begin
            de_q <= video_de;
            if (video_de) begin
                pixels.push_back({vga_r, vga_g, vga_b});
                line_width++;
            end else if (de_q) begin
                if (width == 0) width = line_width;
                height++;
                line_width = 0;
            end
        end
    end
    task automatic shot(input string name);
        capture_name = name;
        capture_request = 1;
        wait (!capture_request);
    endtask

    // ------------------------------------------------------------------
    logic download_q = 0;
    always @(posedge clock_50) begin
        download_q <= dut.guest.ioctl_download;
        if (dut.guest.ioctl_download && !download_q)
            $display("[%0t] download start, index %02h", $time, dut.guest.ioctl_index);
        if (!dut.guest.ioctl_download && download_q)
            $display("[%0t] download end", $time);
    end

    // ------------------------------------------------------------------
    // Shadow of the colour text buffer from completed CPU memory writes.
    logic [7:0] text_shadow [0:32767];
    initial foreach (text_shadow[i]) text_shadow[i] = 8'h00;
    wire        cpu_clk   = dut.guest.CLK_50M;
    wire [23:0] cpu_addr  = dut.guest.at_cpu_address;
    wire [15:0] cpu_dout  = dut.guest.at_cpu_data_out;
    wire        cpu_bhe_n = dut.guest.at_cpu_bus_bhe_n;
    wire        cpu_write_done = dut.guest.at_cpu_bus_valid && dut.guest.at_cpu_bus_write &&
                                 dut.guest.at_cpu_ready && cpu_addr[23:15] == 9'h017;
    bit         text_changed = 0;
    always @(posedge cpu_clk) if (cpu_write_done) begin
        if (!cpu_addr[0]) text_shadow[cpu_addr[14:0]] <= cpu_dout[7:0];
        if (!cpu_bhe_n) text_shadow[cpu_addr[14:0] | 15'd1] <= cpu_dout[15:8];
        text_changed <= 1;
    end
    // Loops in timed processes, and in functions they call, are written as
    // while loops with the step in the body: Verilator 5.020 hoists a for
    // loop's step out of the loop when it inlines such a function into a
    // timed process, and the loop then never ends.
    function automatic string screen_line(int row);
        string line;
        int col;
        byte c;
        line = "";
        col = 0;
        while (col < 80) begin
            c = text_shadow[(row * 80 + col) * 2];
            line = {line, $sformatf("%c", (c >= 8'h20 && c < 8'h7f) ? c : 8'h20)};
            col = col + 1;
        end
        return line;
    endfunction
    function automatic bit screen_has(string text);
        int pos, i;
        bit match;
        pos = 0;
        while (pos + text.len() <= 2000) begin
            match = 1;
            i = 0;
            while (i < text.len() && match) begin
                if (text_shadow[(pos + i) * 2] != text[i]) match = 0;
                i = i + 1;
            end
            if (match) return 1;
            pos = pos + 1;
        end
        return 0;
    endfunction
    task automatic dump_screen(input string why);
        int row;
        $display("[%0t] screen (%s):", $time, why);
        row = 0;
        while (row < 25) begin
            $display("  |%s|", screen_line(row));
            row = row + 1;
        end
        $fflush();
    endtask
    initial forever begin
        #250ms;
        if (text_changed) begin
            text_changed = 0;
            dump_screen("changed");
        end
    end

    // +TRACE_POST: print each POST code the BIOS writes to port 80h, and the
    // first CPU write to the colour text buffer.
    bit trace_post = 0, text_write_seen = 0;
    initial trace_post = $test$plusargs("TRACE_POST");
    always @(posedge cpu_clk) if (trace_post && dut.guest.at_cpu_bus_valid &&
                                  dut.guest.at_cpu_bus_write && dut.guest.at_cpu_ready) begin
        if ((dut.guest.at_cpu_bus_status == 4'h9 || dut.guest.at_cpu_bus_status == 4'hA) &&
            cpu_addr[15:0] == 16'h0080) begin
            $display("[%0t] POST %h", $time, cpu_dout[7:0]);
            $fflush();
        end
        if (cpu_write_done && !text_write_seen) begin
            text_write_seen <= 1;
            $display("[%0t] first text write %h <- %h", $time, cpu_addr, cpu_dout);
            $fflush();
        end
    end

    // +TRACE_BUS=<n>: print the first n CPU bus cycles after the machine
    // starts, and a 100 us heartbeat meanwhile, flushed at once.
    longint trace_left = 0;
    logic   bus_valid_q = 1'b0;
    initial if (!$value$plusargs("TRACE_BUS=%d", trace_left)) trace_left = 0;
    always @(posedge cpu_clk) begin
        bus_valid_q <= dut.guest.at_cpu_bus_valid;
        if (trace_left > 0 && dut.guest.at_machine_reset === 1'b0 &&
            dut.guest.at_cpu_bus_valid && !bus_valid_q) begin
            $display("[%0t] bus %h %s st=%h bhe_n=%b dout=%h", $time, cpu_addr,
                     dut.guest.at_cpu_bus_write ? "W" : "R", dut.guest.at_cpu_bus_status,
                     cpu_bhe_n, cpu_dout);
            $fflush();
            trace_left--;
        end
    end
    initial begin
        if ($test$plusargs("TRACE_BUS")) begin
            wait (dut.guest.main_rom_loaded === 1'b1);
            wait (dut.guest.at_machine_reset === 1'b0);
            repeat (200) begin
                #100us;
                $display("[%0t] fine heartbeat", $time);
                $fflush();
            end
        end
    end

    initial forever begin
        #10ms;
        $display("[heartbeat] %0d ms", $time / 1000000);
        $fflush();
    end

    initial begin
        longint post_ms, setup_ms, waited;
        bit found;
        int key_index;
        logic [127:0] keys;
        string prompt;
        if (!$value$plusargs("PROMPT=%s", prompt)) prompt = "Press ESC";
        if (!$value$plusargs("POST_MS=%d", post_ms)) post_ms = 8000;
        if (!$value$plusargs("SETUP_MS=%d", setup_ms)) setup_ms = 500;
        if (!$value$plusargs("SETUP_KEYS=%h", keys)) keys = 128'h0076;
        $display("zxtres_pcat_bios_tb: start");
        wait (dut.guest.main_rom_loaded === 1'b1);
        wait (dut.guest.at_machine_reset === 1'b0);
        $display("[%0t] machine running", $time);
        $fflush();
        waited = 0;
        found = screen_has(prompt);
        while (waited < post_ms && !found) begin
            #1ms;
            waited++;
            found = screen_has(prompt);
        end
        if (found) $display("[%0t] prompt \"%s\" on screen", $time, prompt);
        else $display("[%0t] prompt \"%s\" not seen", $time, prompt);
        $fflush();
        shot("post");
        dump_screen("post");
        set_osd(1);
        shot("post_osd");
        set_osd(0);
        key_index = 7;
        while (key_index >= 0) begin
            if (keys[key_index*16 +: 16] != 16'h0000) key(keys[key_index*16 +: 16]);
            key_index = key_index - 1;
        end
        #(setup_ms * 1000000);
        shot("setup");
        dump_screen("setup");
        set_osd(1);
        shot("setup_osd");
        $display("ZXTRES_PCAT_BIOS_SIM_END");
        $finish;
    end
endmodule
