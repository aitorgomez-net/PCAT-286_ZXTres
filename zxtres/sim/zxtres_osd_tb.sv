// Testbench for zxtres_osd: a 640-dot picture of +LINES= lines (default 400)
// with blanking, the pixel enable at a quarter of the clock as in the PC/AT
// video path, a controller writing the rows over OSD SPI as the firmware does
// (attribute, 32 characters, 32 colours), and the captured OSD saved as
// osd_<lines>_p<page>[_pos<n>].ppm.
//
//   +LINES=n  picture lines (400 or 200)
//   +PAGE=n   0 main menu, 1 video page, 2 file selector
//   +ROWS=f   draw the rows saved by zxtres_pcat_bios_tb.sv (+OSD_TOUR) in
//             the file f instead of the mock menu; the output is f.ppm
//   +POS=n    position of the box: 0 centre, 1 top left, 2 top right,
//             3 bottom left, 4 bottom right
`timescale 1ns/1ps

module zxtres_osd_tb;
    integer lines = 400;
    integer pos = 0;
    integer page = 0;
    string rows_file;
    bit use_rows = 0;
    initial begin
        use_rows = $value$plusargs("ROWS=%s", rows_file);
        if ($value$plusargs("LINES=%d", lines)) ;
        if ($value$plusargs("POS=%d", pos)) ;
        if ($value$plusargs("PAGE=%d", page)) ;
    end

    logic clk = 0;
    always #5 clk = ~clk;

    logic sck = 0, ss3 = 1, di = 0;
    logic [5:0] r_in, g_in, b_in;
    logic hblank, vblank;
    wire  [5:0] r_out, g_out, b_out;
    wire  osd_enable;

    logic [1:0] ce_div = 0;
    always_ff @(posedge clk) ce_div <= ce_div + 1'd1;
    wire ce = ce_div == 2'd0;

    zxtres_osd #(.USE_BLANKS(1'b1), .OUT_COLOR_DEPTH(6)) dut (
        .clk_sys(clk), .ce(ce),
        .SPI_SCK(sck), .SPI_SS3(ss3), .SPI_DI(di),
        .R_in(r_in), .G_in(g_in), .B_in(b_in),
        .HBlank(hblank), .VBlank(vblank), .HSync(1'b1), .VSync(1'b1),
        .R_out(r_out), .G_out(g_out), .B_out(b_out),
        .osd_enable(osd_enable)
    );

    // Raster: 800 dots by lines+49 lines, 640 by lines active.
    integer h = 0, v = 0, frame = 0;
    always_ff @(posedge clk) if (ce) begin
        hblank <= h >= 640;
        vblank <= v >= lines;
        // A steady background makes doubled glyph scanlines directly comparable.
        r_in <= 6'd20;
        g_in <= 6'd20;
        b_in <= 6'd20;
        if (h == 799) begin
            h <= 0;
            if (v == lines + 48) begin v <= 0; frame <= frame + 1; end
            else v <= v + 1;
        end else h <= h + 1;
    end

    task automatic spi_byte(input [7:0] b);
        for (int i = 7; i >= 0; i--) begin
            di = b[i];
            #40 sck = 1;
            #40 sck = 0;
        end
    endtask

    task automatic spi_cmd(input [7:0] b);
        ss3 = 0;
        spi_byte(b);
        #100 ss3 = 1;
        #100;
    endtask

    // A row is a command, its attribute, 32 characters and 32 colours. A code
    // 1-7 in the text switches the colour of what follows and takes no column,
    // as in the firmware.
    task automatic send_row(input int cmd, input int attr, input string text);
        logic [7:0] ch [0:31];
        logic [7:0] co [0:31];
        int n;
        logic [7:0] cur;
        n = 0;
        cur = 0;
        for (int i = 0; i < text.len(); i++) begin
            if (text[i] >= 1 && text[i] <= 7) cur = text[i];
            else if (n < 32) begin ch[n] = text[i]; co[n] = cur; n++; end
        end
        while (n < 32) begin ch[n] = 8'h20; co[n] = 0; n++; end
        ss3 = 0;
        spi_byte(cmd[7:0]);
        spi_byte(attr[7:0]);
        for (int i = 0; i < 32; i++) spi_byte(ch[i]);
        for (int i = 0; i < 32; i++) spi_byte(co[i]);
        #100 ss3 = 1;
        #100;
    endtask

    // Rows read from a file: the inverse bit, then the characters and the
    // colours as hex digits.
    logic [7:0] raw_ch [0:17][0:31];
    logic [7:0] raw_co [0:17][0:31];
    int raw_inv [0:17];
    int raw_pos;
    function automatic logic [3:0] hexv(input byte ch);
        return ch >= "a" ? 4'(ch - "a" + 10) : 4'(ch - "0");
    endfunction
    task automatic read_rows;
        int fd, n, inv, c;
        string chars, colors;
        fd = $fopen(rows_file, "r");
        if (fd == 0) $fatal(1, "cannot read %s", rows_file);
        void'($fscanf(fd, "%d", raw_pos));
        for (n = 0; n < 18; n++) begin
            void'($fscanf(fd, "%d %s %s", inv, chars, colors));
            raw_inv[n] = inv;
            for (c = 0; c < 32; c++) begin
                raw_ch[n][c] = {hexv(chars[2*c]), hexv(chars[2*c+1])};
                raw_co[n][c] = {4'd0, hexv(colors[c])};
            end
        end
        $fclose(fd);
    endtask
    task automatic send_raw(input int n);
        ss3 = 0;
        spi_byte(8'h20 | n);
        spi_byte(raw_inv[n]);
        for (int i = 0; i < 32; i++) spi_byte(raw_ch[n][i]);
        for (int i = 0; i < 32; i++) spi_byte(raw_co[n][i]);
        #100 ss3 = 1;
        #100;
    endtask

    // The rows are collected first and sent from one loop: calling the
    // sending task from dozens of places makes the simulator build crawl.
    string row_text [0:17];
    int    row_attr [0:17];
    bit    row_used [0:17];

    function automatic void row(input int n, input int attr, input string text);
        row_text[n] = text;
        row_attr[n] = attr;
        row_used[n] = 1;
    endfunction

    integer fd, x, y, bad;
    logic [5:0] cap_r [0:640*500-1];
    logic [5:0] cap_g [0:640*500-1];
    logic [5:0] cap_b [0:640*500-1];
    int cap_frame;
    // Capture one frame as it leaves the OSD: the dot on the screen between
    // two enables is the one at the position the generator held before the
    // previous enable.
    integer hp = 0, vp = 0;
    always_ff @(posedge clk) if (ce) begin
        hp <= h;
        vp <= v;
        if (frame == cap_frame && !hblank && !vblank && hp < 640 && vp < lines) begin
            cap_r[vp * 640 + hp] = r_out;
            cap_g[vp * 640 + hp] = g_out;
            cap_b[vp * 640 + hp] = b_out;
        end
    end

    initial begin
        cap_frame = 99;
        // let the OSD measure the picture
        wait (frame == 2);
        spi_cmd(8'h41);
        if (use_rows) begin
            read_rows;
            spi_cmd(8'h50 | raw_pos);
            for (int n = 0; n < 18; n++) send_raw(n);
        end else begin
        if (pos != 0) spi_cmd(8'h50 | pos);
        row(16, 0, "\006   CPU 12.5 MHz  RAM 4 MB  CGA");
        row(17, 0, "\006 \002\200\201\006 change   Enter: select");
        if (page == 0) begin
            row(0,  0, "\211Floppy A:  \003DOS622.IMG");
            row(1,  0, "\211Floppy B:  \003(none)");
            row(2,  0, "\212Hard disk 0: \003PCAT286A.VHD");
            row(3,  0, "\212Hard disk 1: \003(none)");
            row(4,  0, " Write protect A  \001Off");
            row(5,  0, " Write protect B  \001Off");
            row(6,  0, "\006\210\210 Machine \210\210\210\210\210\210\210\210\210\210\210\210\210\210\210\210\210\210\210\210\210\210");
            row(7,  1, " CPU Speed     \200\001 12.5 MHz \201");
            row(8,  0, " Installed RAM  \0014MB");
            row(9,  0, "\215\007Input \201");
            row(10, 0, "\214\007Video \201");
            row(11, 0, "\213\007Audio \201");
            row(12, 0, "\217\007Settings \201");
            row(13, 0, "\220\007Info \201");
            row(14, 0, "\002 Reset");
            row(15, 0, "\006\200 Exit");
        end else if (page == 1) begin
            row(0,  0, "\006\210\210 Picture \210\210\210\210\210\210\210\210\210\210\210\210\210\210\210\210\210\210\210\210\210");
            row(1,  0, " Monitor        \0015153/CGA");
            row(2,  1, " Display       \200\001 Full Color \201");
            row(3,  0, "\006\210\210 Output \210\210\210\210\210\210\210\210\210\210\210\210\210\210\210\210\210\210\210\210\210\210");
            row(4,  0, " VGA 13h+ CRT   \001Native 70Hz");
            row(5,  0, " Scandoubler    \001Off");
            row(6,  0, " Scan converter \001Auto");
            row(15, 0, "\006\200 Back");
        end else begin
            row(0,  0, "\222PCAT286A.VHD    \006      64M");
            row(1,  0, "\222PCAT286B.VHD    \006       8M");
            row(2,  0, "\221\007DISKS");
            row(3,  1, "\222TEST.IMG        \006     1.4M");
            row(4,  0, "\222A LONG FILE NAME THAT RUNS ON");
            row(15, 0, "\006\200 Back");
        end
        for (int n = 0; n < 18; n++)
            if (row_used[n]) send_row(8'h20 | n, row_attr[n], row_text[n]);
        end
        // Check rows beyond the old 8x32 limits so a broken SPI row decode
        // cannot silently produce a screenshot containing only the footer.
        if (!use_rows && page == 0 && (dut.row_buffer[11*33+2] != "A" || dut.row_buffer[12*33+2] != "S" ||
            dut.row_buffer[15*33+3] != "E" || dut.row_buffer[16*33+4] != "C" ||
            dut.color_buffer[4*32+18] != 4'd1 || dut.color_buffer[11*32+1] != 4'd7))
            $fatal(1, "OSD SPI row addressing failed: row11=%h row12=%h row15=%h info=%h colour=%h/%h",
                   dut.row_buffer[11*33+2], dut.row_buffer[12*33+2],
                   dut.row_buffer[15*33+3], dut.row_buffer[16*33+4],
                   dut.color_buffer[4*32+18], dut.color_buffer[11*32+1]);
        wait (frame == 4);
        cap_frame = 5;
        wait (frame == 6);
        begin : check_frame
            integer cyan_pixels, blue_pixels, lblue_pixels, yellow_pixels;
            cyan_pixels = 0;
            blue_pixels = 0;
            lblue_pixels = 0;
            yellow_pixels = 0;
            for (y = 0; y < lines; y = y + 1)
                for (x = 0; x < 640; x = x + 1) begin
                    if (cap_r[y*640+x] == 0 && cap_g[y*640+x] == 63 && cap_b[y*640+x] == 63)
                        cyan_pixels = cyan_pixels + 1;
                    if (cap_r[y*640+x] == 0 && cap_g[y*640+x] == 22 && cap_b[y*640+x] == 50)
                        blue_pixels = blue_pixels + 1;
                    if (cap_r[y*640+x] == 24 && cap_g[y*640+x] == 40 && cap_b[y*640+x] == 63)
                        lblue_pixels = lblue_pixels + 1;
                    if (cap_r[y*640+x] == 63 && cap_g[y*640+x] == 63 && cap_b[y*640+x] == 20)
                        yellow_pixels = yellow_pixels + 1;
                end
            $display("OSD colours: cyan=%0d bar=%0d lightblue=%0d", cyan_pixels, blue_pixels, lblue_pixels);
            if (!use_rows && (cyan_pixels < 8 || blue_pixels < 8))
                $fatal(1, "OSD header/selection bar missing: cyan=%0d bar=%0d", cyan_pixels, blue_pixels);
        end
        if (lines == 400 && pos == 0) begin
            // The 31 kHz mode repeats each glyph scanline. Ignore the first
            // few dots of a line, where the renderer's pipeline is crossing blanking.
            bad = 0;
            for (y = 0; y < 400; y = y + 2)
                for (x = 8; x < 632; x++)
                    if (cap_r[y*640+x] !== cap_r[(y+1)*640+x] ||
                        cap_g[y*640+x] !== cap_g[(y+1)*640+x] ||
                        cap_b[y*640+x] !== cap_b[(y+1)*640+x])
                        bad = bad + 1;
            if (bad != 0) $fatal(1, "31 kHz OSD scanline pairs differ: %0d pixels", bad);
        end
        if (use_rows) fd = $fopen({rows_file, ".ppm"}, "wb");
        else fd = $fopen(pos == 0 ? $sformatf("osd_%0d_p%0d.ppm", lines, page)
                             : $sformatf("osd_%0d_p%0d_pos%0d.ppm", lines, page, pos), "wb");
        $fwrite(fd, "P6\n640 %0d\n255\n", lines);
        for (y = 0; y < lines; y++)
            for (x = 0; x < 640; x++)
                $fwrite(fd, "%c%c%c", {cap_r[y*640+x], 2'b00},
                        {cap_g[y*640+x], 2'b00}, {cap_b[y*640+x], 2'b00});
        $fclose(fd);
        $display("OSD_TB_DONE lines=%0d page=%0d pos=%0d enable=%b", lines, page, pos, osd_enable);
        $finish;
    end
endmodule
