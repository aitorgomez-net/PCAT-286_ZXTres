`timescale 1ns/1ps

// Program the production AT video adapter through its CPU request mailbox.
// Every dot emitted in the rendered EGA window must survive the blanking
// sent to the HDMI mixer/capture, including the last text column.
module spk286_at_video_window_tb;
    logic clk = 0, clk_video = 0, reset = 1;
    logic run_video = 1;
    always #10 clk = ~clk;
    always #17.462 if (run_video) clk_video = ~clk_video;
    logic valid = 0, command_valid = 0, write_cycle = 0, io_cycle = 1;
    logic [23:0] address = 0;
    logic [1:0] lanes = 1;
    logic [15:0] data_out = 0;
    wire accept, ready;
    wire [15:0] data_in;
    wire hblank, vblank, de, dot;
    logic [3:0] h_offset = 0;
    logic vga_enabled = 0;
    logic [7:0] last_read;
    logic machine_reset = 1;
    logic [1:0] selected_profile = 0;
    wire [1:0] applied_profile;
    ega_monitor_profile_latch profile_latch (
        .clock(clk), .reset_active(machine_reset),
        .selected(selected_profile), .applied(applied_profile)
    );

    spk286_at_video_adapter dut (
        .clk(clk), .reset(reset), .clk_video(clk_video), .splashscreen(1'b0),
        .ega_monitor_profile(applied_profile), .vga_enabled(vga_enabled), .vga_mode13_native(1'b1),
        .crt_h_offset(h_offset), .crt_v_offset(3'd0),
        .vsync_width_osd(3'd0), .hsync_width_osd(3'd0),
        .request_valid(valid), .request_command_valid(command_valid),
        .request_write(write_cycle), .request_io(io_cycle),
        .request_address(address), .request_byte_enable(lanes),
        .request_data_out(data_out), .request_accept(accept), .request_ready(ready),
        .request_read_data(data_in), .request_read_data_valid(),
        .video_hblank(hblank), .video_vblank(vblank), .video_de(de),
        .video_dot_toggle(dot)
    );

    task automatic access_byte(input logic wr, io,
                               input logic [23:0] addr, input logic [7:0] value);
        integer cycles;
        begin
            @(negedge clk);
            valid = 1;
            command_valid = 1;
            write_cycle = wr;
            io_cycle = io;
            address = addr;
            lanes = addr[0] ? 2'b10 : 2'b01;
            data_out = addr[0] ? {value, 8'h00} : {8'h00, value};
            #1;
            if (!accept) $fatal(1, "Video request rejected at %06h", addr);
            @(negedge clk);
            command_valid = 0;
            cycles = 0;
            while (!ready && cycles < 256) begin
                @(negedge clk);
                cycles++;
            end
            if (!ready) $fatal(1, "Video request timed out at %06h", addr);
            last_read = addr[0] ? data_in[15:8] : data_in[7:0];
            @(negedge clk);
            valid = 0;
            repeat (2) @(negedge clk);
        end
    endtask

    task automatic io_write(input logic [15:0] port, input logic [7:0] value);
        access_byte(1, 1, {8'd0, port}, value);
    endtask

    task automatic indexed_write(input logic [15:0] port, input logic [7:0] index, value);
        begin
            io_write(port, index);
            io_write(port + 1, value);
        end
    endtask

    task automatic attr_write(input logic [7:0] index, value);
        begin
            access_byte(0, 1, 24'h0003DA, 0);
            io_write(16'h03C0, index);
            io_write(16'h03C0, value);
            io_write(16'h03C0, 8'h20);
        end
    endtask

    logic [7:0] crtc [0:24];
    integer mode, offset_index;
    task automatic program_mode(input integer mode_number);
        begin
            // Standard BIOS 80-column text, 200 or 350 scanlines. Mode 2
            // reuses the 200-line CRTC for 640x200 planar graphics.
            if (mode_number == 1) begin
                crtc = '{8'h5B,8'h4F,8'h53,8'h37,8'h52,8'h00,8'h6C,8'h1F,
                         8'h00,8'h0D,8'h0B,8'h0C,8'h00,8'h00,8'h00,8'h00,
                         8'h5E,8'h2B,8'h5D,8'h28,8'h0F,8'h5E,8'h0A,8'hA3,8'hFF};
            end else begin
                crtc = '{8'h70,8'h4F,8'h5C,8'h2F,8'h5F,8'h07,8'h04,8'h11,
                         8'h00,8'h07,8'h06,8'h07,8'h00,8'h00,8'h00,8'h00,
                         8'hE1,8'h24,8'hC7,8'h28,8'h08,8'hE0,8'hF0,8'hA3,8'hFF};
                if (mode_number == 2) begin
                    crtc[2]=8'h59; crtc[3]=8'h2D; crtc[4]=8'h5E; crtc[5]=8'h06;
                    crtc[9]=8'h01; crtc[16]=8'hE0; crtc[17]=8'h23;
                    crtc[20]=8'h00; crtc[21]=8'hDF; crtc[22]=8'hEF; crtc[23]=8'hC2;
                end
            end
            io_write(16'h03C2, mode_number == 1 ? 8'hA7 : 8'h23);
            indexed_write(16'h03C4, 1, 8'h01);
            indexed_write(16'h03C4, 2, mode_number == 2 ? 8'h0F : 8'h03);
            indexed_write(16'h03C4, 3, 0);
            indexed_write(16'h03C4, 4, mode_number == 2 ? 8'h06 : 8'h03);
            for (integer j = 0; j <= 24; j++) indexed_write(16'h03D4, 8'(j), crtc[j]);
            for (integer j = 0; j < 16; j++) attr_write(8'(j), 8'(j));
            attr_write(8'h10, mode_number == 2 ? 8'h01 : 8'h08);
            attr_write(8'h11, 0);
            attr_write(8'h12, 8'h0F);
            attr_write(8'h13, 0);
            indexed_write(16'h03CE, 5, mode_number == 2 ? 8'h00 : 8'h10);
            indexed_write(16'h03CE, 6, mode_number == 2 ? 8'h0D : 8'h0E);
            indexed_write(16'h03CE, 8, 8'hFF);
            // A real VRAM write arms the display activation state machine.
            access_byte(1, 0, 24'h0B8000, 8'h41);
        end
    endtask

    task automatic next_dot;
        logic previous_dot;
        begin
            previous_dot = dot;
            do @(negedge clk_video); while (dot == previous_dot);
        end
    endtask

    integer width, clipped;
    task automatic measure_line;
        begin
            // Start in blanking, then observe an entire rendered scanline.
            while (de) next_dot();
            while (!de) next_dot();
            width = 0;
            clipped = 0;
            while (de) begin
                width++;
                if (hblank || vblank) clipped++;
                next_dot();
            end
            $display("AT_VIDEO_WINDOW mode=%0d offset=%0d rendered=%0d clipped=%0d",
                     mode, h_offset, width, clipped);
            if (width != 640 || clipped != 0)
                $fatal(1, "HDMI blanking loses rendered pixels: width=%0d clipped=%0d", width, clipped);
        end
    endtask

    task check_profile(input logic [1:0] expected);
        repeat(60) @(negedge clk);
        if(dut.u_ega.ega_monitor_profile !== expected)
            $fatal(1,"Video profile differs: expected=%0d got=%0d",expected,dut.u_ega.ega_monitor_profile);
        if(dut.u_ega_switch_sense_host.monitor_profile !== expected)
            $fatal(1,"Host switch profile differs from raster");
    endtask

    initial begin
        // Profile changes are accepted only while the CPU is held in reset.
        // The raster/mailbox may keep running during the boot splash.
        @(negedge clk); selected_profile=1;
        check_profile(1);
        reset=0; machine_reset=0; selected_profile=2;
        check_profile(1); // OSD change remains pending during normal execution.
        machine_reset=1; h_offset=6;
        check_profile(2);
        if(dut.video_geometry[3:0] !== 6) $fatal(1,"Geometry corrupted by profile transfer");
        // Verify the actual four BIOS switch-sense reads for an MDA monitor.
        for(integer sw=0;sw<4;sw++) begin
            io_write(16'h03C2,8'(sw*4));
            access_byte(0,1,24'h0003C2,0);
            if(last_read !== ((4'b1011 & (4'b1000 >> sw)) ? 8'h10 : 8'h00))
                $fatal(1,"MDA BIOS switch read failed at selector %0d",sw);
        end
        @(negedge clk_video); run_video=0;
        @(negedge clk); selected_profile=1;
        repeat(20) @(negedge clk);
        selected_profile=2;
        repeat(20) @(negedge clk);
        selected_profile=0;
        repeat(20) @(negedge clk);
        run_video=1; check_profile(0);
        // Repeat a warm reset without resetting the live mailbox toggles.
        reset=1; selected_profile=1; check_profile(1);
        reset=0; selected_profile=0; check_profile(0);
        machine_reset=0; h_offset=0;
        $display("AT_MONITOR_PROFILE_CDC_PASS profiles=0,1,2 pending_until_reset=1 switch_reads=4 stopped_clock=1 warm_reset=1");
        for (mode = 0; mode < 3; mode++) begin
            @(negedge clk);
            reset = 1;
            repeat (20) @(negedge clk);
            reset = 0;
            repeat (20) @(negedge clk);
            program_mode(mode);
            repeat (4) @(negedge vblank);
            for (offset_index = 0; offset_index < 2; offset_index++) begin
                h_offset = offset_index == 0 ? 0 : 6;
                repeat (100) @(negedge clk_video);
                repeat (3) measure_line();
            end
        end
        $display("AT_VIDEO_WINDOW_TEST_PASS text200=640 text350=640 graphics200=640 offsets=0,6");

        // Exercise the mode crossing with actual CPU I/O, immediately followed
        // by memory transactions. The I/O acknowledgement must leave enough
        // time for the registered packed/planar selection to reach the CPU.
        vga_enabled = 1;
        indexed_write(16'h03C4, 2, 8'h01);
        indexed_write(16'h03C4, 4, 8'h0E);
        indexed_write(16'h03CE, 4, 8'h00);
        indexed_write(16'h03CE, 5, 8'h40);
        indexed_write(16'h03CE, 6, 8'h05);
        io_write(16'h03CD, 8'h13);
        if (!dut.vga_packed_memory_active) $fatal(1, "Packed mode not ready after I/O ack");
        access_byte(1, 0, 24'h0A0123, 8'hA5);
        access_byte(0, 0, 24'h0A0123, 0);
        if (last_read != 8'hA5) $fatal(1, "Packed framebuffer readback failed");
        indexed_write(16'h03C4, 4, 8'h06);
        if (dut.vga_packed_memory_active) $fatal(1, "Mode X not ready after I/O ack");
        access_byte(1, 0, 24'h0A0123, 8'h3C);
        access_byte(0, 0, 24'h0A0123, 0);
        if (last_read != 8'h3C) $fatal(1, "Planar framebuffer readback failed: %h", last_read);
        for (integer k = 0; k < 8; k++) begin
            // GC06.misc_reg[0] was the reported asynchronous path.
            indexed_write(16'h03CE, 6, 8'h04);
            if (!dut.vga_packed_memory_active) $fatal(1, "GC06 packed selection late");
            access_byte(0, 0, 24'h0A0123, 0);
            if (last_read != 8'hA5) $fatal(1, "Packed data damaged by planar write");
            indexed_write(16'h03CE, 6, 8'h05);
            if (dut.vga_packed_memory_active) $fatal(1, "GC06 planar selection late");
            access_byte(0, 0, 24'h0A0123, 0);
            if (last_read != 8'h3C) $fatal(1, "Planar data lost across mode change");
        end
        $display("AT_VIDEO_MODE_CDC_PASS packed=A5 planar=3C switches=16");
        $finish;
    end

    initial begin
        #300000000;
        $fatal(1, "AT video window timeout");
    end
endmodule
