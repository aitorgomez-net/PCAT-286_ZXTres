`timescale 1ns/1ps

`ifndef ENABLE_CMS
`define ENABLE_CMS 0
`endif
`ifndef ENABLE_MIDI
`define ENABLE_MIDI 0
`endif

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
    integer sink_reads = 0, ide_commands = 0;

    hps_ext transport (
        .clk_sys(clk), .EXT_BUS(ext_bus),
        .ext_din(mgmt_readdata), .ext_dout(mgmt_writedata),
        .ext_addr(mgmt_address), .ext_rd(mgmt_read), .ext_wr(mgmt_write),
        .ext_midi(), .ext_req({floppy_request, 3'b000, ide_request}),
        .ext_hotswap(2'b00)
    );
    spk286_at_machine dut (
        .clk(clk), .clk_cpu(clk), .cpu_sample_edge(1'b1), .reset(reset), .cpu_reset(1'b0), .clk_video(clk),
        .splashscreen(1'b0), .execute_enable(1'b1), .counter_clock(1'b0),
        .at286ctl_eff_opl2(2'd0), .at286ctl_eff_cms(1'b1),
        .at286ctl_eff_tandy(1'b0),
        .at286ctl_eff_mpu401(`ENABLE_MIDI),
        .midi_baudce(1'b1), .uart_baudce(1'b1),
        .midi_rx(1'b1), .uart2_rx(1'b1),
        .uart2_cts_n(1'b1), .uart2_dsr_n(1'b1), .uart2_dcd_n(1'b1),
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
        .unmapped_request(unmapped_request), .protocol_error(protocol_error)
    );
    always @(posedge clk) if (!reset) begin
        if (dut.io_sink_accept && !dut.at_write) sink_reads <= sink_reads + 1;
        if (dut.u_devices.u_storage_video.u_xtide.ide_io_write &&
            dut.at_address == 24'h0001F7) ide_commands <= ide_commands + 1;
        if (`ENABLE_CMS && dut.at_command_valid &&
            (dut.at_address[15:4] == 12'h01F) &&
            dut.u_devices.device_sound_candidate)
            $fatal(1, "C/MS decoder claimed an AT IDE port %04h",
                   dut.at_address[15:0]);
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
    integer i;
    initial begin
        repeat (8) @(negedge clk);
        reset = 0;
        repeat (4) @(negedge clk);
        host_word(16'h63, reply);
        check(reply[15:12] == 4'hE && reply[2:0] == 3'b110,
              "HPS did not see IDE reset request in bits 2:0");
        host_end();

        // Preserve the shared IDE engine's floating-bus response when no
        // drive is present. XUB bounds its polling using BIOS timer ticks.
        cpu_read_expect(16'h01F7, 8'hFF);
        cpu_read_expect(16'h03F6, 8'hFF);

        host_write(16'hF006, 16'h0089); // master present, slave absent
        host_regs(16'h0000, 16'h40A0); // host releases BSY after reset
        check(ide_request == 0, "HPS did not acknowledge IDE reset");

        // C/MS initialization and detection must not perturb the independent
        // AT IDE channel.  226h is the source-compatible C/MS detection write
        // that is most likely to expose an over-broad 220h decoder.
        if (`ENABLE_CMS) begin
            dut.u_cpu.io_write(16'h0220, 8'h00);
            dut.u_cpu.io_write(16'h0221, 8'h3F);
            dut.u_cpu.io_write(16'h0226, 8'hA5);
            cpu_read_expect(16'h022B, 8'hA5);
        end

        // The AT-only core must leave the old XT2IDE window unmapped.
        cpu_read_expect(16'h0300, 8'hFF);
        cpu_read_expect(16'h0307, 8'hFF);
        cpu_read_expect(16'h030E, 8'hFF);
        check(sink_reads == 3, "Legacy XT2IDE 300h window is still decoded");

        // The AT ROM uses the standard IDE channel 1F0h-1F7h plus 3F6h, and
        // REP INSW must arrive at the common IDE engine as one native ISA16
        // transaction at 1F0h.
        dut.u_cpu.io_write(16'h01F6, 8'hA0);
        dut.u_cpu.io_write(16'h01F7, 8'h20);
        check(ide_request == 4, "AT IDE command never reached HPS");
        host_read(16'hF005, reply);
        check(reply == 16'h20A0,
              "AT IDE command or selected drive mismatch");
        repeat (8) cpu_read_expect(16'h03F6, 8'h80);
        host_send_sector(3);
        host_regs(16'h0001, 16'h5EA0);
        check(irq_request[14], "AT IDE data-ready IRQ missing");
        cpu_read_expect(16'h03F6, 8'h58);
        check(irq_request[14], "AT alternate status incorrectly cleared IRQ");
        for (i = 0; i < 256; i = i + 1) begin
            dut.u_cpu.io_read_word(16'h01F0, expected);
            check(expected === payload(3, i),
                  $sformatf("AT IDE word %0d: expected %04h, got %04h",
                            i, payload(3, i), expected));
        end
        cpu_read_expect(16'h01F7, 8'h40);
        check(!irq_request[14], "AT IDE status read did not clear IRQ14");
        check(!protocol_error, "AT IDE standard-channel protocol fault");

        check(ide_commands == 1, "AT IDE command was duplicated or dropped");
        check(sink_reads == 3, "Valid AT IDE reads reached the FFh sink");
        check(!protocol_error, "AT protocol fault");
        $display("AT_XTIDE_MACHINE_PASS cpu_idle=%0d read_words=256 hps=1 decode=1 legacy_300=0",
                 dut.u_cpu.idle_cycles);
        $finish;
    end
    initial begin
        #100000000;
        $fatal(1, "AT XT-IDE machine test watchdog");
    end
endmodule
