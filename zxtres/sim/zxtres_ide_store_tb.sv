// zxtres_ide_store against the machine's IDE device (rtl/common/ide.v) and a
// model of the controller's side of the user_io block-device protocol, with
// the register-level traffic of a BIOS:
//
//   reset and presence, IDENTIFY, READ SECTORS in CHS and LBA mode on both
//   drives, WRITE SECTORS of two blocks, INIT DEVICE PARAMETERS followed by a
//   CHS read with the new translation, and a read beyond the disk.
//
// Disk 0 ends in a VHD footer (the geometry comes from it); disk 1 is raw
// (the default geometry applies).
//
// Loops in timed processes are while loops (Verilator 5.020, see
// zxtres_pcat_bios_tb.sv).
`timescale 1ns/1ps
module zxtres_ide_store_tb;
    localparam int SECT0 = 2048;      // data sectors of disk 0, plus a footer
    localparam int SECT1 = 3000;

    logic clk = 1'b0;
    always #10 clk = !clk;
    logic reset = 1'b1;

    // ------------------------------------------------------------ IDE
    logic [3:0]  io_address = '0;
    logic        io_read = 1'b0, io_write = 1'b0;
    logic [31:0] io_writedata = '0;
    wire  [31:0] io_readdata;
    wire  [2:0]  request;
    wire         irq, drq;
    wire  [15:0] ide_mgmt_readdata;
    wire  [15:0] mgmt_address, mgmt_writedata;
    wire         mgmt_write, mgmt_read;
    wire         selected = (mgmt_address[15:8] == 8'hF0);
    wire         bus_req, bus_use;

    /* verilator lint_off PINCONNECTEMPTY */
    ide u_ide (
        .clk(clk), .rst_n(!reset), .irq(irq), .drq(drq), .use_fast(1'b0), .no_data(),
        .drive_en(), .io_address(io_address), .io_read(io_read), .io_readdata(io_readdata),
        .io_write(io_write), .io_writedata(io_writedata), .io_32(1'b0), .io_wait(),
        .request(request),
        .mgmt_address(mgmt_address[3:0]), .mgmt_write(mgmt_write && selected),
        .mgmt_writedata(mgmt_writedata), .mgmt_read(mgmt_read && selected),
        .mgmt_readdata(ide_mgmt_readdata),
        .primary_only(1'b0), .secondary_only(1'b0), .ignore_access()
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
    wire  [15:0] command_count;
    logic [7:0]  disk0 [0:(SECT0 + 1) * 512 - 1];
    logic [7:0]  disk1 [0:SECT1 * 512 - 1];
    int          reads = 0, writes = 0;

    function automatic logic [7:0] pattern(input int unit, input int sector, input int i);
        pattern = 8'((sector * 7) + (i * 3) + unit * 41 + (i >> 8));
    endfunction

    zxtres_ide_store #(.TIMEOUT_CYCLES(200000)) dut (
        .clk(clk), .reset(reset),
        .img_mounted(img_mounted), .img_size(img_size),
        .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_lba(sd_lba), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_dout(sd_dout), .sd_dout_strobe(sd_dout_strobe),
        .sd_din(sd_din),
        .bus_req(bus_req), .bus_grant(1'b1), .bus_use(bus_use),
        .mgmt_address(mgmt_address), .mgmt_writedata(mgmt_writedata),
        .mgmt_write(mgmt_write), .mgmt_read(mgmt_read),
        .mgmt_readdata(ide_mgmt_readdata), .ide_request(request),
        .command_count(command_count)
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
                    sd_dout <= (u == 0) ? disk0[lba * 512 + i] : disk1[lba * 512 + i];
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
                    if (u == 0) disk0[lba * 512 + i] = sd_din;
                    else        disk1[lba * 512 + i] = sd_din;
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

    task automatic ide_write(input logic [3:0] address, input logic [7:0] value);
        @(negedge clk);
        io_address = address;
        io_writedata = {24'd0, value};
        io_write = 1'b1;
        @(negedge clk);
        io_write = 1'b0;
        repeat (2) @(negedge clk);
    endtask

    task automatic ide_write_word(input logic [15:0] value);
        @(negedge clk);
        io_address = 4'd0;
        io_writedata = {16'd0, value};
        io_write = 1'b1;
        @(negedge clk);
        io_write = 1'b0;
        repeat (2) @(negedge clk);
    endtask

    task automatic ide_read(input logic [3:0] address, output logic [15:0] value);
        @(negedge clk);
        io_address = address;
        io_read = 1'b1;
        @(negedge clk);
        value = io_readdata[15:0];
        io_read = 1'b0;
        repeat (2) @(negedge clk);
    endtask

    // Alternate status until the drive is neither busy nor missing, and
    // optionally until DRQ is up (or down).
    task automatic wait_status(input bit want_drq, output logic [7:0] status);
        logic [15:0] v;
        int n;
        n = 0;
        status = 8'hFF;
        while (n < 200000) begin
            ide_read(4'd14, v);
            status = v[7:0];
            if (!status[7] && status != 8'hFF && (status[3] == want_drq)) n = 1000000;
            n = n + 1;
        end
        check(!status[7] && status != 8'hFF && status[3] == want_drq,
              $sformatf("status wait timed out with %02h", status));
    endtask

    task automatic select_lba(input logic unit, input int lba, input int count, input logic [7:0] cmd);
        ide_write(4'd2, 8'(count));
        ide_write(4'd3, 8'(lba));
        ide_write(4'd4, 8'(lba >> 8));
        ide_write(4'd5, 8'(lba >> 16));
        ide_write(4'd6, {3'b111, unit, 4'(lba >> 24)});
        ide_write(4'd7, cmd);
    endtask

    task automatic select_chs(input logic unit, input int cyl, input int head,
                              input int sector, input int count, input logic [7:0] cmd);
        ide_write(4'd2, 8'(count));
        ide_write(4'd3, 8'(sector));
        ide_write(4'd4, 8'(cyl));
        ide_write(4'd5, 8'(cyl >> 8));
        ide_write(4'd6, {3'b101, unit, 4'(head)});
        ide_write(4'd7, cmd);
    endtask

    task automatic read_block(input int unit, input int sector, input string what);
        logic [15:0] w;
        logic [7:0]  s;
        int i;
        wait_status(1'b1, s);
        i = 0;
        while (i < 256) begin
            ide_read(4'd0, w);
            check(w[7:0] == pattern(unit, sector, 2 * i) &&
                  w[15:8] == pattern(unit, sector, 2 * i + 1),
                  $sformatf("%s: sector %0d word %0d is %04h", what, sector, i, w));
            i = i + 1;
        end
    endtask

    int errors = 0;
    initial begin
        int s, i;
        logic [15:0] w;
        logic [7:0]  status;
        for (s = 0; s < SECT0 + 1; s = s + 1)
            for (i = 0; i < 512; i = i + 1)
                disk0[s * 512 + i] = (s < SECT0) ? pattern(0, s, i) : 8'h00;
        for (s = 0; s < SECT1; s = s + 1)
            for (i = 0; i < 512; i = i + 1)
                disk1[s * 512 + i] = pattern(1, s, i);
        // The footer: "conectix", 2 cylinders, 16 heads, 63 sectors.
        disk0[SECT0 * 512 + 0] = "c"; disk0[SECT0 * 512 + 1] = "o";
        disk0[SECT0 * 512 + 2] = "n"; disk0[SECT0 * 512 + 3] = "e";
        disk0[SECT0 * 512 + 4] = "c"; disk0[SECT0 * 512 + 5] = "t";
        disk0[SECT0 * 512 + 6] = "i"; disk0[SECT0 * 512 + 7] = "x";
        disk0[SECT0 * 512 + 56] = 8'h00; disk0[SECT0 * 512 + 57] = 8'h02;
        disk0[SECT0 * 512 + 58] = 8'd16; disk0[SECT0 * 512 + 59] = 8'd63;

        repeat (8) @(negedge clk);
        reset = 0;
        repeat (50) @(negedge clk);
        ide_read(4'd14, w);
        check(w[7:0] == 8'hFF, $sformatf("without disks the bus reads FF, not %02h", w[7:0]));

        // The firmware mounts the disks after the machine started: first an
        // unmount and the image, for each. Reset is not answered before.
        @(negedge clk); img_mounted = 2'b01; img_size = 64'd0;
        @(negedge clk); img_mounted = 2'b00;
        @(negedge clk); img_mounted = 2'b01; img_size = 64'((SECT0 + 1) * 512);
        @(negedge clk); img_mounted = 2'b00;
        repeat (200) @(negedge clk);
        ide_read(4'd14, w);
        check(w[7:0] == 8'h80, $sformatf("disk 1 not mounted yet: expected BSY, got %02h", w[7:0]));
        @(negedge clk); img_mounted = 2'b10; img_size = 64'd0;
        @(negedge clk); img_mounted = 2'b00;
        @(negedge clk); img_mounted = 2'b10; img_size = 64'(SECT1 * 512);
        @(negedge clk); img_mounted = 2'b00;
        wait_status(1'b0, status);
        check(status == 8'h50, $sformatf("status after reset is %02h", status));
        ide_read(4'd1, w);
        check(w[7:0] == 8'h01, "diagnostic code after reset");
        ide_read(4'd2, w);
        check(w[7:0] == 8'h01, "sector count signature");

        // IDENTIFY of the master
        ide_write(4'd6, 8'hA0);
        ide_write(4'd7, 8'hEC);
        wait_status(1'b1, status);
        i = 0;
        while (i < 256) begin
            ide_read(4'd0, w);
            case (i)
                0:  check(w == 16'h0040, "IDENTIFY word 0");
                1:  check(w == 16'd2, "IDENTIFY cylinders come from the footer");
                3:  check(w == 16'd16, "IDENTIFY heads");
                6:  check(w == 16'd63, "IDENTIFY sectors per track");
                27: check(w == {"P", "C"}, "IDENTIFY model starts with PC");
                49: check(w[9], "IDENTIFY LBA flag");
                57: check(w == 16'(2 * 16 * 63), "IDENTIFY CHS capacity low");
                60: check(w == 16'(SECT0), "IDENTIFY total sectors low");
                61: check(w == 16'd0, "IDENTIFY total sectors high");
                default: ;
            endcase
            i = i + 1;
        end
        ide_read(4'd7, w);
        check(w[7:0] == 8'h40, $sformatf("status after IDENTIFY is %02h", w[7:0]));

        // IDENTIFY of the slave: no footer, 3000 / 1008 = 2 cylinders
        ide_write(4'd6, 8'hB0);
        ide_write(4'd7, 8'hEC);
        wait_status(1'b1, status);
        i = 0;
        while (i < 256) begin
            ide_read(4'd0, w);
            if (i == 1) check(w == 16'd2, "slave cylinders");
            if (i == 3) check(w == 16'd16, "slave heads");
            if (i == 60) check(w == 16'(SECT1), "slave total sectors");
            i = i + 1;
        end

        // READ SECTORS in CHS mode: cylinder 1, head 3, sector 5, two sectors
        // is LBA (1 * 16 + 3) * 63 + 4 = 1201.
        select_chs(1'b0, 1, 3, 5, 2, 8'h20);
        read_block(0, 1201, "CHS");
        read_block(0, 1202, "CHS");
        wait_status(1'b0, status);
        check(status == 8'h40, $sformatf("status after the read is %02h", status));

        // READ SECTORS in LBA mode on both drives
        select_lba(1'b0, 2047, 1, 8'h20);
        read_block(0, 2047, "LBA 0");
        select_lba(1'b1, 2999, 1, 8'h20);
        read_block(1, 2999, "LBA 1");
        wait_status(1'b0, status);

        // WRITE SECTORS: two blocks to the slave
        select_lba(1'b1, 100, 2, 8'h30);
        wait_status(1'b1, status);
        check(status == 8'h58, $sformatf("write DRQ status is %02h", status));
        s = 0;
        while (s < 2) begin
            i = 0;
            while (i < 256) begin
                ide_write_word({8'(i * 3 + s), 8'(i * 5 + s * 13 + 1)});
                i = i + 1;
            end
            wait_status(s == 0, status);
            s = s + 1;
        end
        check(status == 8'h50, $sformatf("status after the write is %02h", status));
        s = 0;
        while (s < 3) begin
            i = 0;
            while (i < 256) begin
                check(disk1[(100 + s) * 512 + 2 * i] ==
                      ((s < 2) ? 8'(i * 5 + s * 13 + 1) : pattern(1, 100 + s, 2 * i)) &&
                      disk1[(100 + s) * 512 + 2 * i + 1] ==
                      ((s < 2) ? 8'(i * 3 + s) : pattern(1, 100 + s, 2 * i + 1)),
                      $sformatf("written sector %0d word %0d is %02h%02h", 100 + s, i,
                                disk1[(100 + s) * 512 + 2 * i + 1], disk1[(100 + s) * 512 + 2 * i]));
                i = i + 1;
            end
            s = s + 1;
        end
        check(writes == 2, $sformatf("%0d sectors written", writes));

        // INIT DEVICE PARAMETERS: 8 heads of 32 sectors, then a CHS read
        ide_write(4'd2, 8'd32);
        ide_write(4'd6, 8'hA7);
        ide_write(4'd7, 8'h91);
        wait_status(1'b0, status);
        check(status == 8'h50, $sformatf("INIT DEVICE PARAMETERS status %02h", status));
        select_chs(1'b0, 0, 1, 1, 1, 8'h20);       // LBA 1 * 32
        read_block(0, 32, "translated CHS");
        wait_status(1'b0, status);

        // A read beyond the end is refused
        select_lba(1'b0, 2048, 1, 8'h20);
        wait_status(1'b0, status);
        check(status == 8'h51, $sformatf("status of a read beyond the disk is %02h", status));
        ide_read(4'd1, w);
        check(w[7:0] == 8'h10, "ID not found error");

        // An unknown command is aborted
        ide_write(4'd6, 8'hA0);
        ide_write(4'd7, 8'hC4);
        wait_status(1'b0, status);
        check(status == 8'h51, $sformatf("aborted command status %02h", status));
        ide_read(4'd1, w);
        check(w[7:0] == 8'h04, "abort error");

        $display("ZXTRES_IDE_STORE_PASS commands=%0d reads=%0d writes=%0d", command_count, reads, writes);
        $finish;
    end
    initial begin
        #200000000;
        $fatal(1, "IDE store watchdog");
    end
endmodule
