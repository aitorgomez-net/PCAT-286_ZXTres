`timescale 1ns/1ps

// CPU bus pins -> production bridge, machine decode, router and SB/CMS.
// The CPU is a bus driver: this does not execute DOS or the game's code.
module spk286_at_soundblaster_machine_tb;
    logic clk = 0, reset = 1;
    always #10 clk = ~clk;
    logic sb_enabled = 1, cms_enabled = 0;
    logic [2:0] sb_irq_select = 5;
    wire [15:0] irq_request;
    wire protocol_error;
    integer sink_accesses = 0;

    spk286_at_machine dut (
        .clk(clk), .clk_cpu(clk), .cpu_sample_edge(1'b1),
        .reset(reset), .cpu_reset(1'b0), .clk_video(clk),
        .execute_enable(1'b1), .counter_clock(1'b0), .refresh_enable(1'b0),
        .splashscreen(1'b0), .ega_monitor_profile(2'd0),
        .at286ctl_status_effective(40'd0), .at286ctl_status_osd_match(18'd0),
        .at286ctl_eff_opl2(2'd2), .at286ctl_eff_cms(cms_enabled),
        .at286ctl_eff_sb(sb_enabled), .at286ctl_eff_sb_irq(sb_irq_select),
        .at286ctl_eff_tandy(1'b0), .at286ctl_eff_mpu401(1'b0),
        .at286ctl_eff_ems(1'b0), .at286ctl_eff_umb(1'b0),
        .installed_ram_size_osd(3'd0),
        .midi_baudce(1'b0), .uart_baudce(1'b0),
        .midi_rx(1'b1), .uart2_rx(1'b1), .uart2_cts_n(1'b1),
        .uart2_dsr_n(1'b1), .uart2_dcd_n(1'b1),
        .vga_enabled(1'b0), .vga_mode13_native(1'b0),
        .crt_h_offset(4'd0), .crt_v_offset(3'd0),
        .vsync_width_osd(3'd0), .hsync_width_osd(3'd0),
        .joy_clk_select(2'd0), .joy_opts(5'd0), .joy0(14'd0), .joy1(14'd0),
        .joya0(16'd0), .joya1(16'd0),
        .keyboard_byte_valid(1'b0), .keyboard_byte(8'd0),
        .periodic_tick(1'b0), .second_tick(1'b0), .parity_event(1'b0),
        .channel_check_event(1'b0), .external_nmi_event(1'b0),
        .mgmt_address(16'd0), .mgmt_writedata(16'd0),
        .mgmt_write(1'b0), .mgmt_read(1'b0), .use_mmc(2'd0),
        .floppy_write_protect(2'd0), .irq_request(irq_request),
        .memory_accept(1'b0), .memory_ready(1'b0),
        .memory_read_data(16'd0), .memory_read_data_valid(1'b0),
        .dma_memory_accept(1'b0), .dma_memory_ready(1'b0), .dma_memory_data_in(16'd0),
        .refresh_memory_accept(1'b0), .refresh_memory_ready(1'b0),
        .protocol_error(protocol_error)
    );

    always @(posedge clk) if (!reset) begin
        if (dut.io_sink_accept) sink_accesses <= sink_accesses + 1;
        if (protocol_error) $fatal(1, "AT SB machine protocol error");
    end

    task automatic check(input logic condition, input string message);
        if (condition !== 1'b1) $fatal(1, "%s", message);
    endtask

    task automatic cpu_read_expect(input logic [15:0] port, input logic [7:0] expected);
        logic [7:0] actual;
        begin
            dut.u_cpu.io_read(port, actual);
            check(actual === expected,
                  $sformatf("CPU port %04h: expected %02h, got %02h (sink_accesses=%0d)",
                            port, expected, actual, sink_accesses));
        end
    endtask

    task automatic dsp_reply(input logic [7:0] expected);
        begin
            cpu_read_expect(16'h022E, 8'hFF);
            cpu_read_expect(16'h022A, expected);
        end
    endtask

    task automatic wait_sb_irq(input integer line_number);
        integer cycles;
        begin
            // The DSP intentionally delays F2 by 256 clocks for games.
            cycles = 0;
            while (!irq_request[line_number] && cycles < 400) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            check(irq_request[line_number],
                  $sformatf("SB software IRQ not routed to IRQ%0d", line_number));
        end
    endtask

    logic [7:0] status_before, reset_reply, status_after, write_status;
    integer sinks_before;
    initial begin
        repeat (8) @(negedge clk);
        reset = 0;
        repeat (4) @(negedge clk);

        // Same reset/status sequence as the DOS DEBUG hardware diagnostic.
        dut.u_cpu.io_write(16'h0226, 8'h01);
        repeat (200) @(negedge clk); // 4 us reset pulse at 50 MHz
        dut.u_cpu.io_write(16'h0226, 8'h00);
        repeat (200) @(negedge clk);
        dut.u_cpu.io_read(16'h022E, status_before);
        dut.u_cpu.io_read(16'h022A, reset_reply);
        dut.u_cpu.io_read(16'h022E, status_after);
        dut.u_cpu.io_read(16'h022C, write_status);
        $display("AT_SB_MACHINE_DEBUG reads=%02h,%02h,%02h,%02h sink_accesses=%0d",
                 status_before, reset_reply, status_after, write_status, sink_accesses);
        check({status_before, reset_reply, status_after, write_status} === 32'hFFAA7F7F,
              "SB reset/status failed through CPU bus -> AT bridge -> machine -> router");

        dut.u_cpu.io_write(16'h022C, 8'hE1);
        dsp_reply(8'h03);
        dsp_reply(8'h00);
        cpu_read_expect(16'h022E, 8'h7F); // Each response consumed exactly once.
        dut.u_cpu.io_write(16'h022C, 8'hE0);
        dut.u_cpu.io_write(16'h022C, 8'h5A);
        dsp_reply(8'hA5);
        cpu_read_expect(16'h022E, 8'h7F);

        // Odd-port byte lane must reach the mixer and return to CPU D15:8.
        dut.u_cpu.io_write(16'h0224, 8'h22);
        dut.u_cpu.io_write(16'h0225, 8'hB5);
        cpu_read_expect(16'h0225, 8'hB5);

        dut.u_cpu.io_write(16'h022C, 8'hF2);
        wait_sb_irq(5);
        check(irq_request[5] && !irq_request[7], "SB software IRQ not routed to IRQ5");
        cpu_read_expect(16'h022E, 8'h7F);
        check(!irq_request[5] && !irq_request[7], "SB IRQ5 not acknowledged by 22Eh read");
        sb_irq_select = 7;
        dut.u_cpu.io_write(16'h022C, 8'hF2);
        wait_sb_irq(7);
        check(irq_request[7] && !irq_request[5], "SB software IRQ not routed to IRQ7");
        cpu_read_expect(16'h022E, 8'h7F);
        check(!irq_request[5] && !irq_request[7], "SB IRQ7 not acknowledged by 22Eh read");
        check(sink_accesses == 0, "A supported SB operation reached the unmapped I/O sink");
        $display("AT_SB_MACHINE_DETECTION_PASS reset=AA version=3.00 identify=A5 mixer=B5 irq=5,7");

        // Keep the rest of the shared 220h window unclaimed in SB mode.
        cpu_read_expect(16'h0220, 8'hFF);
        cpu_read_expect(16'h0224, 8'hFF); // Mixer index is write-only.
        cpu_read_expect(16'h022B, 8'hFF); // C/MS detection must be absent.
        check(sink_accesses == 3, "SB decoder claimed an unsupported port");

        // OSD effective selection: SB disabled, then C/MS on the same base.
        sb_enabled = 0;
        dut.u_cpu.io_write(16'h0226, 8'h01);
        cpu_read_expect(16'h022E, 8'hFF);
        cpu_read_expect(16'h022A, 8'hFF);
        check(sink_accesses == 6, "Disabled SB still claims I/O");
        cms_enabled = 1;
        sinks_before = sink_accesses;
        dut.u_cpu.io_write(16'h0226, 8'hA5);
        cpu_read_expect(16'h022B, 8'hA5);
        cpu_read_expect(16'h0224, 8'h7F);
        check(sink_accesses == sinks_before, "C/MS detection reached unmapped I/O");
        cpu_read_expect(16'h022A, 8'hFF);
        check(sink_accesses == sinks_before + 1, "SB DSP remains mapped in C/MS mode");
        $display("AT_SB_MACHINE_SELECTION_PASS disabled=open_bus cms=A5");
        $display("AT_SOUNDBLASTER_MACHINE_TEST_PASS");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "AT SB machine global timeout");
    end
endmodule
