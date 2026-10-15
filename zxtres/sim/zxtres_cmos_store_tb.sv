// zxtres_cmos_store against the PC/AT RTC/CMOS and a model of the
// controller's side of the user_io block-device protocol.
//
// 1. A blank (all-zero) file is not restored; once the CMOS has been quiet
//    the module writes it, signed, with the RTC's bytes.
// 2. A CPU write to a configuration byte (2Ch) is saved after the quiet
//    period; writes to the shutdown byte and register B are not.
// 3. Mounting the saved file again restores 10h-7Fh over CPU changes.
//
// Loops in timed processes are while loops (Verilator 5.020, see
// zxtres_pcat_bios_tb.sv).
`timescale 1ns/1ps
module zxtres_cmos_store_tb;
    localparam int QUIET = 2000;

    logic clk = 1'b0;
    always #10 clk = !clk;
    logic reset = 1'b1;

    // ---------------------------------------------------------------- RTC
    logic request_valid = 1'b0, request_command_valid = 1'b0, request_write = 1'b0;
    logic [23:0] request_address = 24'h000070;
    logic [1:0]  request_byte_enable = 2'b01;
    logic [15:0] request_data_out = 16'h0000;
    wire request_accept, request_ready, request_read_data_valid;
    wire [15:0] request_read_data;
    wire [15:0] mgmt_address, mgmt_writedata, mgmt_readdata;
    wire        mgmt_write;

    /* verilator lint_off PINCONNECTEMPTY */
    spk286_at_rtc_cmos rtc (
        .clk(clk), .reset(reset),
        .request_valid(request_valid), .request_command_valid(request_command_valid),
        .request_write(request_write), .request_io(1'b1),
        .request_address(request_address), .installed_ram_size(3'd0),
        .request_byte_enable(request_byte_enable), .request_data_out(request_data_out),
        .request_accept(request_accept), .request_ready(request_ready),
        .request_read_data(request_read_data), .request_read_data_valid(request_read_data_valid),
        .mgmt_address(mgmt_address), .mgmt_writedata(mgmt_writedata),
        .mgmt_write(mgmt_write), .mgmt_readdata(mgmt_readdata),
        .periodic_tick(1'b0), .second_tick(1'b0),
        .irq8(), .nmi_mask(), .side_effect_count(), .selected_index(), .protocol_error()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // ------------------------------------------------- block device model
    logic        img_mounted = 1'b0;
    logic [63:0] img_size = 64'd512;
    logic        sd_ack = 1'b0, sd_dout_strobe = 1'b0;
    logic [8:0]  sd_buff_addr = '0;
    logic [7:0]  sd_dout = '0;
    wire         sd_rd, sd_wr, busy, restored;
    wire  [7:0]  sd_din;
    wire  [15:0] save_count;
    logic [7:0]  file [0:511];
    int          reads = 0, writes = 0;
    bit          busy_seen = 0;

    zxtres_cmos_store #(.QUIET_CYCLES(QUIET)) dut (
        .clk(clk), .reset(reset),
        .img_mounted(img_mounted), .img_size(img_size),
        .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_dout(sd_dout), .sd_dout_strobe(sd_dout_strobe),
        .sd_din(sd_din),
        .mgmt_address(mgmt_address), .mgmt_writedata(mgmt_writedata),
        .mgmt_write(mgmt_write), .mgmt_readdata(mgmt_readdata),
        .busy(busy), .restored(restored), .save_count(save_count)
    );
    always @(posedge clk) if (busy) busy_seen <= 1;

    // The controller serves one request at a time, a byte every 16 clocks.
    initial forever begin
        int i;
        @(posedge clk);
        if (sd_rd) begin
            repeat (20) @(posedge clk);
            sd_ack <= 1'b1;
            i = 0;
            while (i < 512) begin
                repeat (8) @(posedge clk);
                sd_buff_addr <= i[8:0];
                sd_dout <= file[i];
                sd_dout_strobe <= 1'b1;
                @(posedge clk);
                sd_dout_strobe <= 1'b0;
                i = i + 1;
            end
            repeat (4) @(posedge clk);
            sd_ack <= 1'b0;
            sd_buff_addr <= '0;
            reads = reads + 1;
        end else if (sd_wr) begin
            repeat (20) @(posedge clk);
            sd_ack <= 1'b1;
            i = 0;
            while (i < 512) begin
                sd_buff_addr <= i[8:0];
                repeat (8) @(posedge clk);
                file[i] = sd_din;
                i = i + 1;
            end
            repeat (4) @(posedge clk);
            sd_ack <= 1'b0;
            sd_buff_addr <= '0;
            writes = writes + 1;
        end
    end

    // ---------------------------------------------------------- helpers
    task automatic check(input bit condition, input string message);
        if (!condition) $fatal(1, "CHECK_FAIL: %s", message);
    endtask

    task automatic io_write(input logic [15:0] port, input logic [7:0] value);
        @(negedge clk);
        request_address = {8'h00, port};
        request_byte_enable = port[0] ? 2'b10 : 2'b01;
        request_data_out = port[0] ? {value, 8'h00} : {8'h00, value};
        request_write = 1'b1;
        request_valid = 1'b1;
        request_command_valid = 1'b1;
        #1 check(request_accept, "RTC write not accepted");
        @(posedge clk);
        @(negedge clk);
        request_valid = 1'b0;
        request_command_valid = 1'b0;
        request_write = 1'b0;
        @(posedge clk);
    endtask

    task automatic io_read(input logic [15:0] port, output logic [7:0] value);
        @(negedge clk);
        request_address = {8'h00, port};
        request_byte_enable = port[0] ? 2'b10 : 2'b01;
        request_write = 1'b0;
        request_valid = 1'b1;
        request_command_valid = 1'b1;
        #1 check(request_accept, "RTC read not accepted");
        @(posedge clk);
        @(negedge clk);
        request_valid = 1'b0;
        request_command_valid = 1'b0;
        #1 value = port[0] ? request_read_data[15:8] : request_read_data[7:0];
        @(posedge clk);
    endtask

    task automatic cmos_write(input logic [6:0] index, input logic [7:0] value);
        io_write(16'h0070, {1'b0, index});
        io_write(16'h0071, value);
    endtask

    task automatic cmos_read(input logic [6:0] index, output logic [7:0] value);
        io_write(16'h0070, {1'b0, index});
        io_read(16'h0071, value);
    endtask

    task automatic mount;
        @(negedge clk);
        img_mounted = 1'b1;
        @(negedge clk);
        img_mounted = 1'b0;
    endtask

    task automatic wait_cycles(input int n);
        repeat (n) @(posedge clk);
    endtask

    function automatic bit signed_file;
        string signature = "PCATCMOS";
        int i;
        i = 0;
        while (i < 8) begin
            if (file[128 + i] != signature[i]) return 0;
            i = i + 1;
        end
        return file[136] == 8'h01;
    endfunction

    // ------------------------------------------------------------- test
    initial begin
        int i;
        logic [7:0] value;

        i = 0;
        while (i < 512) begin
            file[i] = 8'h00;
            i = i + 1;
        end
        wait_cycles(5);
        reset = 1'b0;
        wait_cycles(5);

        // 1. Blank file: no restore; the defaults are written once.
        mount();
        wait_cycles(20000);
        check(reads == 1, "the blank file was not read");
        check(busy_seen, "busy was not raised while restoring");
        check(!restored, "a blank file was restored");
        check(writes == 1 && save_count == 16'd1, "the defaults were not written once");
        check(signed_file(), "the written file is not signed");
        i = 16;
        while (i < 128) begin
            cmos_read(i[6:0], value);
            if (i != 'h0C && i != 'h0D)
                check(file[i] == value, $sformatf("file byte %02h is %02h, CMOS has %02h", i, file[i], value));
            i = i + 1;
        end
        wait_cycles(10 * QUIET);
        check(writes == 1, "a quiet CMOS was written again");

        // 2. A configuration byte is saved; run-time registers are not.
        cmos_write(7'h2C, 8'h5A);
        cmos_write(7'h45, 8'hC3);
        wait_cycles(20000);
        check(writes == 2, "the configuration change was not written");
        check(file[8'h2C] == 8'h5A && file[8'h45] == 8'hC3, "the change is not in the file");
        cmos_write(7'h0F, 8'h05);
        cmos_write(7'h0B, 8'h42);
        wait_cycles(20000);
        check(writes == 2, "a shutdown-code or register B write was saved");

        // 3. Mounting the saved file restores it over later CPU changes.
        cmos_write(7'h2C, 8'h11);
        cmos_write(7'h45, 8'h22);
        mount();
        wait_cycles(20000);
        check(reads == 2, "the saved file was not read");
        check(restored, "the saved file was not restored");
        cmos_read(7'h2C, value);
        check(value == 8'h5A, $sformatf("2Ch restored as %02h", value));
        cmos_read(7'h45, value);
        check(value == 8'hC3, $sformatf("45h restored as %02h", value));
        cmos_read(7'h0F, value);
        check(value == 8'h05, "the shutdown byte was overwritten by the restore");
        check(writes == 2, "the restore caused a write");

        $display("ZXTRES_CMOS_STORE_PASS reads=%0d writes=%0d", reads, writes);
        $finish;
    end
endmodule
