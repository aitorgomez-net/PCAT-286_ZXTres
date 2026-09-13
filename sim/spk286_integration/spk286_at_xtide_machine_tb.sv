`timescale 1ns/1ps
// Regression for XT-IDE accesses being intercepted by the machine's FFh sink.
// Exercise CPU bus -> real AT bridge/decode/router/IDE and the real hps_ext
// transport. Host responses are modeled from Main_MiSTer/ide.cpp; no CPU
// instructions, BIOS, VHD parser or physical HPS are simulated here.
module spk286_at_xtide_machine_tb;
    logic clk = 0, reset = 1;
    always #10 clk = ~clk; // AT runs at CLK_50M, without XT bus pacing.
    logic [15:0] host_data = 0;
    logic host_enable = 0, host_strobe = 0;
    wire [35:0] ext_bus;
    assign ext_bus[35:34] = {1'b0, host_enable};
    assign ext_bus[33] = host_strobe;
    assign ext_bus[31:16] = host_data;
    wire [15:0] mgmt_address, mgmt_writedata, mgmt_readdata;
    wire mgmt_write, mgmt_read;
    wire [1:0] floppy_request;
    wire [2:0] ide_request;
    wire [15:0] irq_request;
    wire protocol_error, unmapped_request;
    wire [15:0] fault_sources;
    integer sink_reads = 0, ide_commands = 0;

    hps_ext transport (
        .clk_sys(clk), .EXT_BUS(ext_bus),
        .ext_din(mgmt_readdata), .ext_dout(mgmt_writedata),
        .ext_addr(mgmt_address), .ext_rd(mgmt_read), .ext_wr(mgmt_write),
        .ext_midi(), .ext_req({floppy_request, 3'b000, ide_request}),
        .ext_hotswap(2'b00)
    );
    spk286_at_machine dut (
        .clk(clk), .reset(reset), .cpu_reset(1'b0), .clk_video(clk),
        .splashscreen(1'b0), .execute_enable(1'b1), .counter_clock(1'b0),
        .refresh_enable(1'b0), .keyboard_byte_valid(1'b0), .keyboard_byte(8'd0),
        .periodic_tick(1'b0), .second_tick(1'b0), .parity_event(1'b0),
        .channel_check_event(1'b0), .external_nmi_event(1'b0),
        .mgmt_address(mgmt_address), .mgmt_writedata(mgmt_writedata),
        .mgmt_write(mgmt_write), .mgmt_read(mgmt_read),
        .mgmt_readdata(mgmt_readdata), .use_mmc(2'b00),
        .floppy_write_protect(2'b00), .floppy_request(floppy_request),
        .ide_request(ide_request), .irq_request(irq_request),
        .memory_accept(1'b0), .memory_ready(1'b0),
        .memory_read_data(16'd0), .memory_read_data_valid(1'b0),
        .dma_memory_accept(1'b0), .dma_memory_ready(1'b0), .dma_memory_data_in(16'd0),
        .refresh_memory_accept(1'b0), .refresh_memory_ready(1'b0),
        .unmapped_request(unmapped_request), .protocol_error(protocol_error),
        .debug_fault_sources(fault_sources)
    );
    always @(posedge clk) if (!reset) begin
        if (dut.io_sink_accept && !dut.at_write) sink_reads <= sink_reads + 1;
        if (dut.u_devices.u_storage_video.u_xtide.ide_io_write &&
            dut.at_address == 24'h000307) ide_commands <= ide_commands + 1;
    end

    task automatic check(input logic condition, input string message);
        if (condition !== 1'b1) $fatal(1, "%s", message);
    endtask
    task automatic host_word(input logic [15:0] value, output logic [15:0] reply);
        begin
            @(negedge clk);
            host_enable = 1;
            host_strobe = 1;
            host_data = value;
            @(negedge clk);
            reply = ext_bus[15:0];
            host_strobe = 0;
            // Allow the host-side registered FIFO read pipeline to settle.
            // This models extension words, not the ARM/GPIO clock crossing;
            // CPU bus throughput is independently stressed by CPU_IDLE=0.
            repeat (6) @(negedge clk);
        end
    endtask
    task automatic host_end;
        begin
            host_enable = 0;
            repeat (3) @(negedge clk);
        end
    endtask
    task automatic host_begin(input logic [15:0] command, address);
        logic [15:0] unused_reply;
        begin
            host_word(command, unused_reply);
            host_word(address, unused_reply);
            host_word(0, unused_reply);
        end
    endtask
    task automatic host_write(input logic [15:0] address, value);
        logic [15:0] unused_reply;
        begin
            host_begin(16'h61, address);
            host_word(value, unused_reply);
            host_end();
        end
    endtask
    task automatic host_read(input logic [15:0] address, output logic [15:0] value);
        begin
            host_begin(16'h62, address);
            host_word(0, value);
            host_end();
        end
    endtask
    task automatic host_regs(input logic [15:0] size_error, status_drive);
        logic [15:0] unused_reply;
        begin
            host_begin(16'h61, 16'hF000);
            host_word(size_error, unused_reply);
            host_word(16'h0101, unused_reply);
            host_word(0, unused_reply);
            host_word(0, unused_reply);
            host_word(0, unused_reply);
            host_word(status_drive, unused_reply);
            host_end();
        end
    endtask
    function automatic logic [15:0] payload(input integer block_id, index);
        if (block_id == 1 && index == 255) payload = 16'hAA55;
        else payload = 16'hA55A ^ (16'h0101 * 16'(index)) ^ (16'h1234 * 16'(block_id));
    endfunction
    task automatic host_send_sector(input integer block_id);
        logic [15:0] unused_reply;
        integer i;
        begin
            // F0FF saturates the transport address and streams into IDE FIFO F.
            host_begin(16'h61, 16'hF0FF);
            for (i = 0; i < 256; i = i + 1)
                host_word(payload(block_id, i), unused_reply);
            host_end();
        end
    endtask
    task automatic cpu_read_expect(input logic [15:0] port, input logic [7:0] expected);
        logic [7:0] actual;
        begin
            dut.u_cpu.io_read(port, actual);
            check(actual === expected,
                  $sformatf("CPU port %04h: expected %02h, got %02h (sink_reads=%0d)",
                            port, expected, actual, sink_reads));
        end
    endtask

    logic [15:0] reply, expected;
    logic [7:0] low_byte, high_byte;
    integer i, block_id;
    initial begin
        repeat (8) @(negedge clk);
        reset = 0;
        repeat (4) @(negedge clk);
        host_word(16'h63, reply);
        check(reply[15:12] == 4'hE && reply[2:0] == 3'b110,
              "HPS did not see IDE reset request in bits 2:0");
        host_end();
        host_write(16'hF006, 16'h0089); // master present, slave absent
        host_regs(16'h0000, 16'h40A0); // host releases BSY after reset
        check(ide_request == 0, "HPS did not acknowledge IDE reset");
        // This fails on 94fd21d: FFh despite a mounted/initialized controller.
        cpu_read_expect(16'h0307, 8'h40);
        check(sink_reads == 0, "Machine intercepted an XT-IDE status read");
        dut.u_cpu.io_write(16'h0302, 8'h55);
        dut.u_cpu.io_write(16'h0303, 8'hAA);
        cpu_read_expect(16'h0302, 8'h55);
        cpu_read_expect(16'h0303, 8'hAA);
        cpu_read_expect(16'h0309, 8'hFF);
        cpu_read_expect(16'h02FF, 8'hFF);
        cpu_read_expect(16'h0310, 8'hFF);
        check(sink_reads == 3, "XT-IDE window overdecoded neighboring ports");

        // Software reset uses the alternate control port, including host delay.
        dut.u_cpu.io_write(16'h030E, 8'h04);
        dut.u_cpu.io_write(16'h030E, 8'h00);
        check(ide_request == 6, "CPU software reset did not reach IDE");
        cpu_read_expect(16'h030E, 8'h80);
        host_regs(16'h0000, 16'h40A0);

        // Full IDENTIFY and sector-read payloads via 300h + 308h at maximum
        // bridge throughput. Keep BSY set across several CPU polls to model HPS latency.
        for (block_id = 0; block_id < 2; block_id = block_id + 1) begin
            dut.u_cpu.io_write(16'h0306, 8'hA0);
            dut.u_cpu.io_write(16'h0307, block_id == 0 ? 8'hEC : 8'h20);
            check(ide_request == 4, "CPU command never reached IDE/HPS");
            host_read(16'hF005, reply);
            check(reply == (block_id == 0 ? 16'hECA0 : 16'h20A0),
                  "HPS command or selected drive mismatch");
            repeat (8) cpu_read_expect(16'h0307, 8'h80);
            host_send_sector(block_id);
            host_regs(16'h0001, 16'h5EA0); // 256 words, DRQ, IRQ, last block
            check(irq_request[14], "IDE data-ready IRQ missing");
            cpu_read_expect(16'h030E, 8'h58);
            check(irq_request[14], "Alternate status incorrectly cleared IRQ");
            cpu_read_expect(16'h0307, 8'h58);
            check(!irq_request[14], "Status read did not clear IDE IRQ");
            for (i = 0; i < 256; i = i + 1) begin
                dut.u_cpu.io_read(16'h0300, low_byte);
                dut.u_cpu.io_read(16'h0308, high_byte);
                expected = payload(block_id, i);
                check({high_byte, low_byte} === expected,
                      $sformatf("Read block %0d word %0d: expected %04h, got %02h%02h",
                                block_id, i, expected, high_byte, low_byte));
            end
            cpu_read_expect(16'h0307, 8'h40);
            check(ide_request == 0, "Last read unexpectedly requested another block");
        end

        // Write a sector in XTIDE byte order and inspect all 256 host words.
        dut.u_cpu.io_write(16'h0307, 8'h30);
        check(ide_request == 4, "WRITE command did not reach HPS");
        host_regs(16'h0001, 16'h48A0);
        for (i = 0; i < 256; i = i + 1) begin
            expected = payload(2, i);
            dut.u_cpu.io_write(16'h0308, expected[15:8]);
            dut.u_cpu.io_write(16'h0300, expected[7:0]);
        end
        check(ide_request == 5, "Completed WRITE did not request HPS data transfer");
        host_begin(16'h62, 16'hF0FF);
        for (i = 0; i < 256; i = i + 1) begin
            host_word(0, reply);
            check(reply === payload(2, i),
                  $sformatf("Write sector word %0d: expected %04h, got %04h (mgmt_cnt=%0d)",
                            i, payload(2, i), reply,
                            dut.u_devices.u_storage_video.u_xtide.u_ide.mgmt_cnt));
        end
        host_end();
        host_regs(16'h0000, 16'h40A0);
        cpu_read_expect(16'h0307, 8'h40);
        check(ide_commands == 3, "Command was duplicated or dropped");
        check(sink_reads == 3, "Valid XT-IDE reads reached the FFh sink");
        check(!protocol_error, $sformatf("AT protocol fault: %04h", fault_sources));
        $display("AT_XTIDE_MACHINE_PASS cpu_idle=%0d identify_words=256 read_words=256 write_words=256 hps=1 decode=1",
                 dut.u_cpu.idle_cycles);
        $finish;
    end
    initial begin
        #100000000;
        $fatal(1, "AT XT-IDE machine test watchdog");
    end
endmodule
