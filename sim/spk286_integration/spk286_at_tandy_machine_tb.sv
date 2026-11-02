`timescale 1ns/1ps

// CPU bus pins -> production bridge, machine decode, router and SN76489.
// Writes at C0h and 1E0h-1E3h must reach the chip, not the unmapped sink.
module spk286_at_tandy_machine_tb;
    logic clk = 0, reset = 1;
    always #10 clk = ~clk;
    logic tandy_enabled = 1;
    wire signed [10:0] tandy_sound;
    wire protocol_error;
    integer sink_accesses = 0;
    integer chip_accepts = 0;
    integer chip_writes = 0;
    integer dma_accepts = 0;
    integer window_writes = 0;

    spk286_at_machine dut (
        .clk(clk), .clk_cpu(clk), .cpu_sample_edge(1'b1),
        .reset(reset), .video_reset(reset), .cpu_reset(1'b0), .clk_video(clk),
        .execute_enable(1'b1), .pause(1'b0), .counter_clock(1'b0), .refresh_enable(1'b0),
        .splashscreen(1'b0), .splash_fade_out(1'b0), .ega_monitor_profile(2'd0),
        .at286ctl_status_effective(40'd0), .at286ctl_status_osd_match(18'd0),
        .at286ctl_eff_opl2(2'd2), .at286ctl_eff_cms(1'b0),
        .at286ctl_eff_sb(1'b0), .at286ctl_eff_sb_irq(3'd5),
        .at286ctl_eff_tandy(tandy_enabled), .at286ctl_eff_mpu401(1'b0),
        .at286ctl_eff_ems(1'b0), .at286ctl_eff_umb(1'b0),
        .installed_ram_size_osd(3'd0),
        .midi_baudce(1'b0), .uart_baudce(1'b0),
        .midi_rx(1'b1), .uart1_rx(1'b1), .uart2_rx(1'b1), .uart2_cts_n(1'b1),
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
        .floppy_write_protect(2'd0), .irq_request(),
        .memory_accept(1'b0), .memory_ready(1'b0),
        .memory_read_data(16'd0), .memory_read_data_valid(1'b0),
        .dma_memory_accept(1'b0), .dma_memory_ready(1'b0), .dma_memory_data_in(16'd0),
        .refresh_memory_accept(1'b0), .refresh_memory_ready(1'b0),
        .tandy_sound(tandy_sound),
        .protocol_error(protocol_error)
    );

    always @(posedge clk) if (!reset) begin
        if (dut.io_sink_accept) sink_accesses <= sink_accesses + 1;
        if (dut.u_devices.u_sound.request_accept) chip_accepts <= chip_accepts + 1;
        // DMA2 takes of the C0h-CFh writes (reads and D0h-DFh are not counted).
        if (dut.dma_config_accept && dut.at_write && dut.at_address[15:4] == 12'h00C)
            dma_accepts <= dma_accepts + 1;
        if (protocol_error) $fatal(1, "AT Tandy machine protocol error");
    end

    task automatic check(input logic condition, input string message);
        if (condition !== 1'b1) $fatal(1, "%s", message);
    endtask

    task automatic chip_write(input logic [15:0] port, input logic [7:0] value);
        integer sinks_before;
        begin
            sinks_before = sink_accesses;
            dut.u_cpu.io_write(port, value);
            chip_writes++;
            if (port[15:4] == 12'h00C) window_writes++;
            check(sink_accesses == sinks_before,
                  $sformatf("Tandy write to %04h reached the unmapped I/O sink", port));
        end
    endtask

    task automatic sink_write(input logic [15:0] port);
        integer sinks_before;
        begin
            sinks_before = sink_accesses;
            dut.u_cpu.io_write(port, 8'h90);
            check(sink_accesses == sinks_before + 1,
                  $sformatf("Write to %04h did not reach the unmapped I/O sink", port));
        end
    endtask

    // Peak-to-peak of the chip output over 2 ms, after the 6 ms a tone
    // counter left at zero needs before it loads the new divider.
    task automatic swing(output integer value);
        integer lo, hi;
        begin
            repeat (300000) @(posedge clk);
            lo = 0; hi = 0;
            repeat (100000) begin
                @(posedge clk);
                if (tandy_sound < lo) lo = tandy_sound;
                if (tandy_sound > hi) hi = tandy_sound;
            end
            value = hi - lo;
        end
    endtask

    // Write PAT and its complement to a DMA2 address register and read both
    // back. The register's writes reach the SN76489 too; the DMA2 side
    // must still hold what was written.
    task automatic dma2_register_test(input logic [15:0] port, input logic [7:0] value);
        logic [7:0] first, second;
        begin
            dut.u_cpu.io_write(16'h00D8, 8'h00);
            dut.u_cpu.io_write(port, value);
            dut.u_cpu.io_write(port, ~value);
            dut.u_cpu.io_write(16'h00D8, 8'h00);
            dut.u_cpu.io_read(port, first);
            dut.u_cpu.io_read(port, second);
            window_writes += 2;       // DMA2 takes both writes to the register
            chip_writes += 2;         // the chip sees the two to the register
            check(first === value && second === ~value,
                  $sformatf("DMA2 %04h read back %02h %02h after %02h %02h",
                            port, first, second, value, ~value));
        end
    endtask

    integer value, dma_before;
    integer k;
    logic [7:0] pat;
    logic [7:0] rb;
    realtime burst_start, burst_ns;
    initial begin
        repeat (8) @(negedge clk);
        reset = 0;
        repeat (4) @(negedge clk);

        // The RLX/RSX port: channel 0 tone and volume through 1E0h.
        chip_write(16'h01E0, 8'h80);
        chip_write(16'h01E0, 8'h02);
        chip_write(16'h01E0, 8'h90);
        swing(value);
        check(value > 100, $sformatf("No tone through 1E0h (swing %0d)", value));
        // The PCjr/Tandy port and the odd lane of the RLX window.
        chip_write(16'h00C0, 8'h9F);
        chip_write(16'h01E3, 8'hBF);
        swing(value);
        check(value == 0, $sformatf("C0h did not silence channel 0 (swing %0d)", value));
        $display("AT_TANDY_MACHINE_PORTS_PASS 1E0h C0h 1E3h");

        // The BIOS's DMA2 test with the chip on: per register, clear the
        // byte flip-flop, write two bytes, clear it again and read them back.
        for (k = 0; k < 4; k++) begin
            pat = (k == 0) ? 8'hFF : (k == 1) ? 8'h00 : (k == 2) ? 8'hAA : 8'h55;
            dma2_register_test(16'h00C0, pat);
            dma2_register_test(16'h00C2, pat);
        end
        $display("AT_TANDY_MACHINE_DMA2_READBACK_PASS");

        // A music driver's burst: each write costs the chip's own wait,
        // 32 clocks of 3.58 MHz (8.9 us), as on a Tandy 1000, not three.
        burst_start = $realtime;
        repeat (2) begin
            chip_write(16'h00C0, 8'h9F);
            chip_write(16'h00C0, 8'hBF);
            chip_write(16'h01E0, 8'hDF);
            chip_write(16'h01E0, 8'hFF);
        end
        burst_ns = $realtime - burst_start;
        // Let the posted writes still queued behind the busy chip land.
        repeat (2000) @(negedge clk);
        // Back-to-back writes reach the busy chip once each: none twice, and
        // none taken by DMA2 instead while the chip is busy.
        check(chip_accepts == chip_writes,
              $sformatf("%0d chip writes for %0d CPU writes", chip_accepts, chip_writes));
        // DMA2 is behind the same C0h-CFh writes (the BIOS tests it there),
        // and sees each of them once, not only when the chip is idle.
        check(dma_accepts == window_writes,
              $sformatf("DMA2 took %0d of %0d C0h writes", dma_accepts, window_writes));
        check(burst_ns < 8 * 10000.0,
              $sformatf("8 writes took %0.1f us", burst_ns / 1000.0));
        $display("AT_TANDY_MACHINE_BURST_PASS writes=%0d burst_8=%0.1f_us",
                 chip_writes, burst_ns / 1000.0);

        // The Tandy DAC ports and the disabled chip stay unmapped.
        sink_write(16'h01E4);
        tandy_enabled = 0;
        sink_write(16'h01E0);
        // Disabled, C0h belongs to DMA2 alone.
        dma_before = dma_accepts;
        dut.u_cpu.io_write(16'h00C0, 8'h00);
        check(dma_accepts == dma_before + 1, "C0h did not reach DMA2 with Tandy disabled");
        $display("AT_TANDY_MACHINE_DECODE_PASS dac=sink disabled=sink c0_dma=1");
        $display("AT_TANDY_MACHINE_TEST_PASS");
        $finish;
    end

    initial begin
        #60000000;
        $fatal(1, "AT Tandy machine global timeout");
    end
endmodule
