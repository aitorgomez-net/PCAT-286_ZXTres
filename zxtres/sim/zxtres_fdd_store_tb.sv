// zxtres_fdd_store against the machine's floppy controller
// (rtl/common/floppy.v) and a model of the controller's side of the user_io
// block-device protocol. The controller is driven through its ports in
// non-DMA mode, as a BIOS does without the DMA chip:
//
//   mount of a 1.44M image in drive A and a 720K one in drive B (geometry
//   registers and media present), READ DATA from both drives, WRITE DATA to
//   drive A and a check of the image, then an eject.
//
// Loops in timed processes are while loops (Verilator 5.020, see
// zxtres_pcat_bios_tb.sv).
`timescale 1ns/1ps
module zxtres_fdd_store_tb;
    localparam int SECT_A = 2880;
    localparam int SECT_B = 1440;

    logic clk = 1'b0;
    always #10 clk = !clk;
    logic reset = 1'b1;

    // ------------------------------------------------------------ floppy
    logic [2:0]  io_address = '0;
    logic        io_read = 1'b0, io_write = 1'b0;
    logic [7:0]  io_writedata = '0;
    wire  [7:0]  io_readdata;
    wire  [1:0]  request;
    wire  [15:0] fdc_mgmt_readdata;
    wire  [15:0] mgmt_address, mgmt_writedata;
    wire         mgmt_write, mgmt_read;
    wire         selected = (mgmt_address[15:8] == 8'hF2);
    wire         bus_req, bus_use;

    /* verilator lint_off PINCONNECTEMPTY */
    floppy u_fdc (
        .clk(clk), .rst_n(!reset),
        .dma_req(), .dma_ack(1'b0), .dma_tc(1'b0), .dma_readdata(8'h00), .dma_writedata(),
        .irq(),
        .io_address(io_address), .io_read(io_read), .io_readdata(io_readdata),
        .io_write(io_write), .io_writedata(io_writedata),
        .fdd0_inserted(),
        .mgmt_address(mgmt_address[3:0]), .mgmt_fddn(mgmt_address[7]),
        .mgmt_write(mgmt_write && selected), .mgmt_writedata(mgmt_writedata),
        .mgmt_read(mgmt_read && selected), .mgmt_readdata(fdc_mgmt_readdata),
        .wp(2'b00), .clock_rate(28'd50_000_000), .request(request),
        .io_write_address(3'd0)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // ------------------------------------------------- block device model
    logic [1:0]  img_mounted = 2'b00;
    logic [63:0] img_size = '0;
    logic [1:0]  sd_ack = 2'b00;
    logic        sd_dout_strobe = 1'b0;
    logic [8:0]  sd_buff_addr = '0;
    logic [7:0]  sd_dout = '0;
    wire  [1:0]  sd_rd, sd_wr;
    wire  [31:0] sd_lba;
    wire  [7:0]  sd_din;
    wire  [15:0] sector_count;
    logic [7:0]  disk_a [0:SECT_A * 512 - 1];
    logic [7:0]  disk_b [0:SECT_B * 512 - 1];
    int          reads = 0, writes = 0;

    function automatic logic [7:0] pattern(input int unit, input int sector, input int i);
        pattern = 8'((sector * 7) + (i * 3) + unit * 41 + (i >> 8));
    endfunction

    zxtres_fdd_store #(.TIMEOUT_CYCLES(200000)) dut (
        .clk(clk), .reset(reset),
        .img_mounted(img_mounted), .img_size(img_size),
        .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_lba(sd_lba), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_dout(sd_dout), .sd_dout_strobe(sd_dout_strobe),
        .sd_din(sd_din),
        .bus_req(bus_req), .bus_grant(1'b1), .bus_use(bus_use),
        .mgmt_address(mgmt_address), .mgmt_writedata(mgmt_writedata),
        .mgmt_write(mgmt_write), .mgmt_read(mgmt_read),
        .mgmt_readdata(fdc_mgmt_readdata), .floppy_request(request),
        .sector_count(sector_count)
    );

    // The controller serves one request at a time, a byte every ten clocks.
    initial forever begin
        int i, u;
        logic [31:0] lba;
        @(posedge clk);
        if (|sd_rd || |sd_wr) begin
            u = sd_rd[1] || sd_wr[1];
            lba = sd_lba;
            repeat (20) @(posedge clk);
            sd_ack[u] <= 1'b1;
            i = 0;
            if (|sd_rd) begin
                while (i < 512) begin
                    repeat (8) @(posedge clk);
                    sd_buff_addr <= i[8:0];
                    sd_dout <= (u == 0) ? disk_a[lba * 512 + i] : disk_b[lba * 512 + i];
                    sd_dout_strobe <= 1'b1;
                    @(posedge clk);
                    sd_dout_strobe <= 1'b0;
                    i = i + 1;
                end
                reads = reads + 1;
            end else begin
                while (i < 512) begin
                    sd_buff_addr <= i[8:0];
                    repeat (8) @(posedge clk);
                    if (u == 0) disk_a[lba * 512 + i] = sd_din;
                    else        disk_b[lba * 512 + i] = sd_din;
                    i = i + 1;
                end
                writes = writes + 1;
            end
            repeat (4) @(posedge clk);
            sd_ack[u] <= 1'b0;
            sd_buff_addr <= '0;
        end
    end

    // ---------------------------------------------------------- helpers
    task automatic check(input bit condition, input string message);
        if (!condition) $fatal(1, "CHECK_FAIL: %s", message);
    endtask

    task automatic fdc_write(input logic [2:0] address, input logic [7:0] value);
        @(negedge clk);
        io_address = address;
        io_writedata = value;
        io_write = 1'b1;
        @(negedge clk);
        io_write = 1'b0;
        repeat (2) @(negedge clk);
    endtask

    task automatic fdc_read(input logic [2:0] address, output logic [7:0] value);
        @(negedge clk);
        io_address = address;
        io_read = 1'b1;
        @(negedge clk);
        value = io_readdata;
        io_read = 1'b0;
        repeat (2) @(negedge clk);
    endtask

    // Main status register until the bits in MASK read as WANT.
    task automatic wait_msr(input logic [7:0] mask, input logic [7:0] want, input string what);
        logic [7:0] v;
        int n;
        n = 0;
        v = 8'h00;
        while (n < 3000000) begin
            fdc_read(3'd4, v);
            if ((v & mask) == want) n = 100000000;
            n = n + 1;
        end
        check((v & mask) == want, $sformatf("%s: MSR is %02h", what, v));
    endtask

    task automatic mount(input int unit, input int sectors);
        @(negedge clk);
        img_size = 64'(sectors) * 64'd512;
        img_mounted[unit] = 1'b1;
        @(negedge clk);
        img_mounted[unit] = 1'b0;
    endtask

    // Seven result bytes of a READ or WRITE DATA.
    task automatic results(output logic [7:0] st0, output logic [7:0] st1);
        logic [7:0] v;
        int i;
        i = 0;
        st0 = 8'hFF;
        st1 = 8'hFF;
        while (i < 7) begin
            wait_msr(8'hE0, 8'hC0, "result phase");
            fdc_read(3'd5, v);
            if (i == 0) st0 = v;
            if (i == 1) st1 = v;
            i = i + 1;
        end
    endtask

    task automatic transfer_cmd(input logic write, input logic drive, input int head,
                                input int cyl, input int sector);
        fdc_write(3'd5, write ? 8'h45 : 8'h46);
        fdc_write(3'd5, {5'd0, head[0], 1'b0, drive});
        fdc_write(3'd5, 8'(cyl));
        fdc_write(3'd5, 8'(head));
        fdc_write(3'd5, 8'(sector));
        fdc_write(3'd5, 8'd2);
        fdc_write(3'd5, 8'(sector));        // EOT: this sector only; the last head, where a non-DMA transfer ends
        fdc_write(3'd5, 8'h1B);
        fdc_write(3'd5, 8'hFF);
    endtask

    task automatic read_sector(input logic drive, input int head, input int cyl,
                               input int sector, input int unit, input int lba, input string what);
        logic [7:0] v, st0, st1;
        int i;
        transfer_cmd(1'b0, drive, head, cyl, sector);
        i = 0;
        while (i < 512) begin
            wait_msr(8'hA0, 8'hA0, what);        // data register ready, non-DMA execution
            fdc_read(3'd5, v);
            check(v == pattern(unit, lba, i),
                  $sformatf("%s: byte %0d of sector %0d is %02h", what, i, lba, v));
            i = i + 1;
        end
        results(st0, st1);
        check(st0[7:6] == 2'b00 && st1 == 8'h00, $sformatf("%s: status %02h %02h", what, st0, st1));
    endtask

    task automatic write_sector(input logic drive, input int head, input int cyl,
                                input int sector, input int unit, input int seed);
        logic [7:0] st0, st1;
        int i;
        transfer_cmd(1'b1, drive, head, cyl, sector);
        i = 0;
        while (i < 512) begin
            wait_msr(8'hA0, 8'hA0, "write data");
            fdc_write(3'd5, pattern(unit, seed, i) ^ 8'h5A);
            i = i + 1;
        end
        results(st0, st1);
        check(st0[7:6] == 2'b00 && st1 == 8'h00, $sformatf("write: status %02h %02h", st0, st1));
    endtask

    int k, n;
    initial begin
        n = 0;
        while (n < SECT_A * 512) begin disk_a[n] = pattern(0, n / 512, n % 512); n = n + 1; end
        n = 0;
        while (n < SECT_B * 512) begin disk_b[n] = pattern(1, n / 512, n % 512); n = n + 1; end

        repeat (10) @(negedge clk);
        reset = 1'b0;
        repeat (10) @(negedge clk);

        // Mounted images become media with the geometry of their size.
        mount(0, SECT_A);
        mount(1, SECT_B);
        k = 0;
        while (k < 200000 && !(u_fdc.media_present[0] && u_fdc.media_present[1])) begin
            @(negedge clk); k = k + 1;
        end
        check(u_fdc.media_present[0] && u_fdc.media_present[1], "media not present");
        check(u_fdc.media_cylinders[0] == 8'd80 && u_fdc.media_sectors_per_track[0] == 8'd18 &&
              u_fdc.media_heads[0] == 2'd2 && u_fdc.media_sector_count[0] == 16'd2880,
              "drive A geometry");
        check(u_fdc.media_cylinders[1] == 8'd80 && u_fdc.media_sectors_per_track[1] == 8'd9 &&
              u_fdc.media_heads[1] == 2'd2 && u_fdc.media_sector_count[1] == 16'd1440,
              "drive B geometry");
        $display("INFO: media registers set");

        // Motor on, drive A, non-DMA execution.
        fdc_write(3'd2, 8'h1C);
        fdc_write(3'd5, 8'h03);
        fdc_write(3'd5, 8'hDF);
        fdc_write(3'd5, 8'h03);               // HLT = 1, ND = 1

        fdc_write(3'd7, 8'h00);               // 500 kbit/s: 1.44M
        read_sector(1'b0, 1, 0, 1, 0, 18, "A cyl 0 head 1 sector 1");
        read_sector(1'b0, 1, 0, 3, 0, 20, "A cyl 0 head 1 sector 3");
        $display("INFO: reads from drive A passed");

        // Drive B, 720K: 250 kbit/s.
        fdc_write(3'd2, 8'h2D);
        fdc_write(3'd7, 8'h02);
        read_sector(1'b1, 1, 0, 2, 1, 10, "B cyl 0 head 1 sector 2");
        $display("INFO: read from drive B passed");

        // Write to drive A, sector 5 of cylinder 0 head 1 (image sector 22).
        fdc_write(3'd2, 8'h1C);
        fdc_write(3'd7, 8'h00);
        write_sector(1'b0, 1, 0, 5, 0, 22);
        k = 0;
        while (k < 100000 && writes == 0) begin @(negedge clk); k = k + 1; end
        check(writes == 1, "no write reached the image");
        n = 0;
        while (n < 512) begin
            check(disk_a[22 * 512 + n] == (pattern(0, 22, n) ^ 8'h5A),
                  $sformatf("image byte %0d is %02h", n, disk_a[22 * 512 + n]));
            n = n + 1;
        end
        $display("INFO: write to drive A reached the image");

        // Eject: size zero.
        @(negedge clk);
        img_size = 64'd0;
        img_mounted[0] = 1'b1;
        @(negedge clk);
        img_mounted[0] = 1'b0;
        k = 0;
        while (k < 200000 && u_fdc.media_present[0]) begin @(negedge clk); k = k + 1; end
        check(!u_fdc.media_present[0] && u_fdc.media_present[1], "eject");

        $display("ZXTRES_FDD_STORE_PASS reads=%0d writes=%0d sectors=%0d", reads, writes, sector_count);
        $finish;
    end

    initial begin
        #400_000_000;
        $fatal(1, "CHECK_FAIL: timeout");
    end
endmodule
