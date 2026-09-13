`timescale 1ns/1ps

module spk286_at_devices_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;
    logic clk_video = 1'b0;
    always #17.45 clk_video = ~clk_video;

    // CPU-facing normalized request.
    logic        request_valid = 1'b0;
    logic        request_command_valid = 1'b0;
    logic        request_write = 1'b0;
    logic        request_io = 1'b0;
    logic [23:0] request_address = 24'h000000;
    logic [1:0]  request_byte_enable = 2'b00;
    logic [15:0] request_data_out = 16'h0000;
    wire         request_accept;
    wire         request_ready;
    wire [15:0]  request_read_data;
    wire         request_read_data_valid;
    wire [3:0]   selected_device;
    wire         unmapped_request;

    logic        keyboard_byte_valid = 1'b0;
    logic [7:0]  keyboard_byte = 8'h00;
    wire         keyboard_output_valid;
    wire [7:0]   keyboard_output_byte;
    wire         irq1;
    wire         a20_enable;
    wire         cpu_reset_request;
    integer      cpu_reset_pulse_count = 0;
    logic        periodic_tick = 1'b0;
    logic        second_tick = 1'b0;
    wire         irq8;
    wire         nmi_mask;

    wire         devices_dma_transfer_accept;
    wire         devices_dma_transfer_ready;
    wire [15:0]  devices_dma_transfer_data_out;
    wire [7:0]   devices_dma_request;
    wire         irq6;
    wire         irq14;
    wire         ata_selected;
    wire         floppy_selected;
    wire         video_io_selected;
    wire         video_memory_selected;
    wire [15:0]  side_effect_count;
    wire [15:0]  irq_request;
    wire         devices_protocol_error;
    logic [15:0] mgmt_address = 16'h0000;
    logic [15:0] mgmt_writedata = 16'h0000;
    logic        mgmt_write = 1'b0;
    logic        mgmt_read = 1'b0;
    wire [15:0]  mgmt_readdata;
    logic [1:0]  floppy_write_protect = 2'b00;
    wire [1:0]   floppy_present;
    wire [1:0]   floppy_request;
    logic [1:0]  use_mmc = 2'b00;
    wire [2:0]   ide_request;

    // A4 DMA controller, driven by the A5 storage device's channel-2 request.
    logic        dma_config_valid = 1'b0;
    logic        dma_config_command_valid = 1'b0;
    logic        dma_config_write = 1'b0;
    logic        dma_config_io = 1'b0;
    logic [23:0] dma_config_address = 24'h000000;
    logic [1:0]  dma_config_byte_enable = 2'b00;
    logic [15:0] dma_config_data_out = 16'h0000;
    wire         dma_config_accept;
    wire         dma_config_ready;
    wire [15:0]  dma_config_read_data;
    wire         dma_config_read_data_valid;
    wire         dma_bus_request;
    wire         dma_transfer_valid;
    wire [2:0]   dma_active_channel;
    wire [23:0]  dma_transfer_address;
    wire [1:0]   dma_transfer_byte_enable;
    wire         dma_transfer_write_to_memory;
    wire         dma_transfer_read_from_memory;
    wire         dma_transfer_io_to_memory;
    wire         dma_transfer_memory_to_io;
    wire [15:0]  dma_transfer_data_out;
    wire         dma_transfer_complete;
    wire         dma_terminal_count;
    wire [7:0]   dma_request_state;
    wire [7:0]   dma_acknowledge;
    wire         dma_cascade_request;
    wire         dma_protocol_error;

    logic        cpu_hlda = 1'b1;
    logic        cpu_bridge_idle = 1'b1;
    logic        cpu_lock = 1'b0;
    logic        cpu_odd_word_active = 1'b0;
    logic        cpu_inta_lock_chain = 1'b0;
    logic        cpu_response_pending = 1'b0;
    wire         cpu_hold_request;
    wire         cpu_grant;
    wire         external_grant;
    wire         bus_owner_valid;
    wire [2:0]   bus_owner;
    wire         dma_grant;
    wire         refresh_grant;
    wire         loader_grant;
    wire         arbiter_protocol_error;
    wire         external_done = dma_transfer_complete;

    integer dma_beat_count = 0;
    integer dma_terminal_count_seen = 0;
    logic [23:0] dma_addresses [0:7];
    logic [1:0] dma_lanes [0:7];
    logic [15:0] dma_payloads [0:7];

    spk286_at_device_router devices (
        .clk(clk), .reset(reset),
        .clk_video(clk_video), .splashscreen(1'b0),
        .request_valid(request_valid),
        .request_command_valid(request_command_valid),
        .request_write(request_write), .request_io(request_io),
        .request_address(request_address),
        .request_byte_enable(request_byte_enable),
        .request_data_out(request_data_out),
        .request_accept(request_accept), .request_ready(request_ready),
        .request_read_data(request_read_data),
        .request_read_data_valid(request_read_data_valid),
        .selected_device(selected_device),
        .unmapped_request(unmapped_request),
        .keyboard_byte_valid(keyboard_byte_valid),
        .keyboard_byte(keyboard_byte),
        .keyboard_output_valid(keyboard_output_valid),
        .keyboard_output_byte(keyboard_output_byte), .irq1(irq1),
        .a20_enable(a20_enable), .cpu_reset_request(cpu_reset_request),
        .periodic_tick(periodic_tick), .second_tick(second_tick),
        .irq8(irq8), .nmi_mask(nmi_mask),
        .dma_transfer_valid(dma_transfer_valid),
        .dma_transfer_complete(dma_transfer_complete),
        .dma_terminal_count(dma_terminal_count),
        .dma_active_channel(dma_active_channel),
        .dma_transfer_data_in(16'h0000),
        .dma_transfer_accept(devices_dma_transfer_accept),
        .dma_transfer_ready(devices_dma_transfer_ready),
        .dma_transfer_data_out(devices_dma_transfer_data_out),
        .dma_request(devices_dma_request), .irq6(irq6), .irq14(irq14),
        .mgmt_address(mgmt_address), .mgmt_writedata(mgmt_writedata),
        .mgmt_write(mgmt_write), .mgmt_read(mgmt_read),
        .mgmt_readdata(mgmt_readdata),
        .floppy_write_protect(floppy_write_protect),
        .floppy_present(floppy_present), .floppy_request(floppy_request),
        .use_mmc(use_mmc), .ide_request(ide_request),
         .ata_selected(ata_selected), .floppy_selected(floppy_selected),
        .video_io_selected(video_io_selected),
        .video_memory_selected(video_memory_selected),
        .side_effect_count(side_effect_count), .irq_request(irq_request),
        .protocol_error(devices_protocol_error)
    );

    spk286_at_dma dma (
        .clk(clk), .reset(reset),
        .request_valid(dma_config_valid),
        .request_command_valid(dma_config_command_valid),
        .request_write(dma_config_write), .request_io(dma_config_io),
        .request_address(dma_config_address),
        .request_byte_enable(dma_config_byte_enable),
        .request_data_out(dma_config_data_out),
        .request_accept(dma_config_accept), .request_ready(dma_config_ready),
        .request_read_data(dma_config_read_data),
        .request_read_data_valid(dma_config_read_data_valid),
        .dma_request(devices_dma_request), .dma_grant(dma_grant),
        .transfer_accept(devices_dma_transfer_accept),
        .transfer_ready(devices_dma_transfer_ready),
        .transfer_data_in(devices_dma_transfer_data_out),
        .dma_bus_request(dma_bus_request),
        .dma_transfer_valid(dma_transfer_valid),
        .dma_active_channel(dma_active_channel),
        .dma_transfer_address(dma_transfer_address),
        .dma_transfer_byte_enable(dma_transfer_byte_enable),
        .dma_transfer_write_to_memory(dma_transfer_write_to_memory),
        .dma_transfer_read_from_memory(dma_transfer_read_from_memory),
        .dma_transfer_io_to_memory(dma_transfer_io_to_memory),
        .dma_transfer_memory_to_io(dma_transfer_memory_to_io),
        .dma_transfer_data_out(dma_transfer_data_out),
        .dma_transfer_complete(dma_transfer_complete),
        .dma_terminal_count(dma_terminal_count),
        .dma_request_state(dma_request_state),
        .dma_acknowledge(dma_acknowledge),
        .cascade_request(dma_cascade_request),
        .protocol_error(dma_protocol_error)
    );

    spk286_at_arbiter arbiter (
        .clk(clk), .reset(reset), .cpu_hlda(cpu_hlda),
        .cpu_bridge_idle(cpu_bridge_idle), .cpu_lock(cpu_lock),
        .cpu_odd_word_active(cpu_odd_word_active),
        .cpu_inta_lock_chain(cpu_inta_lock_chain),
        .cpu_response_pending(cpu_response_pending),
        .dma_request(dma_bus_request), .refresh_request(1'b0),
        .loader_request(1'b0), .loader_reset_owner(1'b0),
        .external_done(external_done), .cpu_hold_request(cpu_hold_request),
        .cpu_grant(cpu_grant), .external_grant(external_grant),
        .bus_owner_valid(bus_owner_valid), .bus_owner(bus_owner),
        .dma_grant(dma_grant), .refresh_grant(refresh_grant),
        .loader_grant(loader_grant), .protocol_error(arbiter_protocol_error)
    );

    task automatic check(input logic condition, input string message);
        if (!condition)
            $fatal(1, "CHECK_FAIL: %s", message);
    endtask

    task automatic router_write_lane(
        input logic [15:0] port,
        input logic [15:0] data,
        input logic [1:0]  lanes
    );
        integer cycles;
        begin
            @(negedge clk);
            request_address = {8'h00, port};
            request_byte_enable = lanes;
            request_data_out = data;
            request_valid = 1'b1;
            request_command_valid = 1'b1;
            request_write = 1'b1;
            request_io = 1'b1;
            #1;
            check(request_accept, "AT device write was not accepted");
            @(posedge clk);
            @(negedge clk);
            request_valid = 1'b0;
            request_command_valid = 1'b0;
            request_write = 1'b0;
            request_io = 1'b0;
            cycles = 0;
            while (!request_ready && cycles < 64) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            check(request_ready, "AT device write did not complete");
            @(posedge clk);
        end
    endtask

    task automatic router_write(input logic [15:0] port, input logic [7:0] value);
        begin
            router_write_lane(port,
                              port[0] ? {value, 8'h00} : {8'h00, value},
                              port[0] ? 2'b10 : 2'b01);
        end
    endtask

    task automatic router_write_word(input logic [15:0] port,
                                     input logic [15:0] value);
        begin
            router_write_lane(port, value, 2'b11);
        end
    endtask

    task automatic router_read_lane(
        input logic [15:0] port,
        input logic [1:0]  lanes,
        output logic [7:0]  value
    );
        integer cycles;
        begin
            @(negedge clk);
            request_address = {8'h00, port};
            request_byte_enable = lanes;
            request_data_out = 16'h0000;
            request_valid = 1'b1;
            request_command_valid = 1'b1;
            request_write = 1'b0;
            request_io = 1'b1;
            #1;
            check(request_accept, "AT device read was not accepted");
            @(posedge clk);
            @(negedge clk);
            request_valid = 1'b0;
            request_command_valid = 1'b0;
            request_io = 1'b0;
            cycles = 0;
            while (!request_ready && cycles < 64) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            check(request_ready && request_read_data_valid,
                  "AT device read did not return data");
            value = lanes[1] ? request_read_data[15:8] : request_read_data[7:0];
            @(posedge clk);
        end
    endtask

    task automatic router_read(input logic [15:0] port, output logic [7:0] value);
        begin
            router_read_lane(port, port[0] ? 2'b10 : 2'b01, value);
        end
    endtask

    task automatic router_read_word(input logic [15:0] port,
                                    output logic [15:0] value);
        integer cycles;
        begin
            @(negedge clk);
            request_address = {8'h00, port};
            request_byte_enable = 2'b11;
            request_data_out = 16'h0000;
            request_valid = 1'b1;
            request_command_valid = 1'b1;
            request_write = 1'b0;
            request_io = 1'b1;
            #1;
            check(request_accept, "AT device word read was not accepted");
            @(posedge clk);
            @(negedge clk);
            request_valid = 1'b0;
            request_command_valid = 1'b0;
            request_io = 1'b0;
            cycles = 0;
            while (!request_ready && cycles < 64) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            check(request_ready && request_read_data_valid,
                  "AT device word read did not return data");
            value = request_read_data;
            @(posedge clk);
        end
    endtask

    task automatic dma_write(input logic [15:0] port, input logic [7:0] value);
        begin
            @(negedge clk);
            dma_config_address = {8'h00, port};
            dma_config_byte_enable = port[0] ? 2'b10 : 2'b01;
            dma_config_data_out = port[0] ? {value, 8'h00} :
                                             {8'h00, value};
            dma_config_valid = 1'b1;
            dma_config_command_valid = 1'b1;
            dma_config_write = 1'b1;
            dma_config_io = 1'b1;
            #1;
            check(dma_config_accept, "A4 DMA setup write was not accepted");
            @(posedge clk);
            @(negedge clk);
            dma_config_valid = 1'b0;
            dma_config_command_valid = 1'b0;
            dma_config_write = 1'b0;
            dma_config_io = 1'b0;
            #1;
            check(dma_config_ready, "A4 DMA setup write did not complete");
            @(posedge clk);
        end
    endtask

    task automatic mgmt_write_word(input logic [15:0] address,
                                   input logic [15:0] value);
        begin
            @(negedge clk);
            mgmt_address = address;
            mgmt_writedata = value;
            mgmt_write = 1'b1;
            @(posedge clk);
            @(negedge clk);
            mgmt_write = 1'b0;
        end
    endtask

    task automatic fdc_wait_host_write;
        logic [7:0] status;
        integer cycles;
        begin
            status = 8'h00;
            cycles = 0;
            while (((status & 8'hC0) != 8'h80) && cycles < 20000) begin
                router_read(16'h03F4, status);
                cycles = cycles + 1;
            end
            check((status & 8'hC0) == 8'h80,
                  "FDC did not enter host-write phase");
        end
    endtask

    task automatic fdc_write_fifo(input logic [7:0] value);
        begin
            fdc_wait_host_write();
            router_write(16'h03F5, value);
        end
    endtask

    task automatic fdc_read_fifo(output logic [7:0] value);
        logic [7:0] status;
        integer cycles;
        begin
            status = 8'h00;
            cycles = 0;
            while (((status & 8'hC0) != 8'hC0) && cycles < 20000) begin
                router_read(16'h03F4, status);
                cycles = cycles + 1;
            end
            check((status & 8'hC0) == 8'hC0,
                  "FDC did not enter result phase");
            router_read(16'h03F5, value);
        end
    endtask

    task automatic pulse_periodic_tick;
        begin
            @(negedge clk);
            periodic_tick = 1'b1;
            @(posedge clk);
            @(negedge clk);
            periodic_tick = 1'b0;
        end
    endtask

    task automatic pulse_second_tick;
        begin
            @(negedge clk);
            second_tick = 1'b1;
            @(posedge clk);
            @(negedge clk);
            second_tick = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (reset) begin
            dma_beat_count = 0;
            dma_terminal_count_seen = 0;
        end else begin
            if (dma_transfer_valid && devices_dma_transfer_accept) begin
                if (dma_beat_count < 8)
                    dma_addresses[dma_beat_count] = dma_transfer_address;
                if (dma_beat_count < 8) begin
                    dma_lanes[dma_beat_count] = dma_transfer_byte_enable;
                    dma_payloads[dma_beat_count] = dma_transfer_data_out;
                end
                dma_beat_count = dma_beat_count + 1;
            end
            if (dma_terminal_count)
                dma_terminal_count_seen = dma_terminal_count_seen + 1;
            check(!(dma_grant && refresh_grant),
                  "A5 arbiter granted DMA and refresh together");
        end
    end

    always @(posedge cpu_reset_request)
        cpu_reset_pulse_count = cpu_reset_pulse_count + 1;

    initial begin : run
        logic [7:0] value;
        logic [15:0] word_value;
        integer cycles;

        repeat (3) @(negedge clk);
        reset = 1'b0;

        // IBM 5170 8042 command protocol exercised by the Landmark U126 and
        // keyboard-scan-lines diagnostics.
        router_read(16'h0064, value);
        check(value[4] && !value[2] && !value[1] && !value[0],
              "8042 power-on status was incorrect");
        router_write(16'h0064, 8'hAA);
        router_read(16'h0064, value);
        check(value[3] && value[2] && value[0],
              "8042 self-test did not set command/system/output status");
        router_read(16'h0060, value);
        check(value == 8'h55, "8042 AA self-test response was not 55h");
        router_write(16'h0064, 8'hAB);
        router_read(16'h0060, value);
        check(value == 8'h00, "8042 AB interface-test response was not 00h");

        router_write(16'h0064, 8'h60);
        router_read(16'h0064, value);
        check(value[3], "8042 status did not remember a command-port write");
        router_write(16'h0060, 8'h44);
        router_read(16'h0064, value);
        check(!value[3] && value[2] && !value[0],
              "8042 command-byte write produced incorrect status");
        router_write(16'h0064, 8'h20);
        router_read(16'h0060, value);
        check(value == 8'h44, "8042 command-byte readback was incorrect");

        router_write(16'h0064, 8'hAD);
        router_write(16'h0064, 8'h20);
        router_read(16'h0060, value);
        check(value[4], "8042 disable command did not set command-byte bit 4");
        router_write(16'h0064, 8'hAE);
        router_write(16'h0064, 8'h20);
        router_read(16'h0060, value);
        check(!value[4], "8042 enable command did not clear command-byte bit 4");
        router_write(16'h0064, 8'hC0);
        router_read(16'h0060, value);
        check(value == 8'hA0, "8042 AT input-port image was incorrect");
        router_write(16'h0064, 8'hE0);
        router_read(16'h0060, value);
        check(value == 8'h03, "8042 idle test-input image was incorrect");

        // Restore translated keyboard input with IRQ1 enabled, then exercise
        // the host-byte output buffer and output-port A20 control.
        router_write(16'h0064, 8'h60);
        router_write(16'h0060, 8'h45);
        keyboard_byte = 8'h1C;
        keyboard_byte_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        keyboard_byte_valid = 1'b0;
        #1;
        check(keyboard_output_valid && keyboard_output_byte == 8'h1C &&
              irq1 && irq_request[1], "8042 keyboard byte/IRQ1 path failed");
        router_read(16'h0060, value);
        check(value == 8'h1C && !irq1, "8042 data read did not pop IRQ1");
        router_write(16'h0064, 8'hD1);
        router_write(16'h0060, 8'h03);
        check(a20_enable && !cpu_reset_request,
              "8042 output port did not enable A20 safely");
        router_write(16'h0064, 8'hD0);
        router_read(16'h0060, value);
        check(value == 8'h03, "8042 output-port readback was incorrect");
        router_read(16'h0064, value);
        check(value[4] && value[3] && value[2] && !value[1] && !value[0],
              "8042 status register was incorrect");

        // Both documented AT reset forms must produce a CPU-local pulse.
        cycles = cpu_reset_pulse_count;
        router_write(16'h0064, 8'hFE);
        #1;
        check(cpu_reset_pulse_count > cycles,
              "8042 FE reset command did not pulse CPU reset");
        cycles = cpu_reset_pulse_count;
        router_write(16'h0064, 8'hD1);
        router_write(16'h0060, 8'hFE);
        #1;
        check(cpu_reset_pulse_count > cycles,
              "8042 D1/FE reset sequence did not pulse CPU reset");

        // RTC index/data, MiSTer F4xx host time, NMI mask, periodic IRQ8 and
        // deterministic seconds.
        mgmt_write_word(16'hF400, 16'h0042);
        router_write(16'h0070, 8'h00);
        router_read(16'h0071, value);
        check(value == 8'h42,
              "RTC did not receive the MiSTer F4xx management write");
        router_write(16'h0070, 8'h15);
        router_read(16'h0071, value);
        check(value == 8'h80, "RTC did not advertise 640 KiB base memory");
        router_write(16'h0070, 8'h17);
        router_read(16'h0071, value);
        check(value == 8'h80, "RTC did not advertise 384 KiB extended memory");
        router_write(16'h0070, 8'h0B);
        router_write(16'h0071, 8'h42);
        check(!nmi_mask, "RTC NMI mask did not clear");
        pulse_periodic_tick();
        #1;
        check(irq8 && irq_request[8], "RTC periodic tick did not assert IRQ8");
        router_write(16'h0070, 8'h0C);
        router_read(16'h0071, value);
        check(value[6] && !irq8, "RTC status-C read did not clear IRQ8");
        router_write(16'h0070, 8'h00);
        router_write(16'h0071, 8'h59);
        pulse_second_tick();
        router_read(16'h0071, value);
        check(value == 8'h00, "RTC second tick was not deterministic BCD time");
        router_write(16'h0070, 8'h8C);
        check(nmi_mask, "RTC index write did not set the NMI mask");

        // ATA primary channel: IDENTIFY command, status IRQ14 and word data.
        router_write(16'h01F7, 8'hEC);
        #1;
        check(irq14 && irq_request[14], "ATA command did not assert IRQ14");
        router_read_word(16'h01F0, word_value);
        check(word_value == 16'h0040, "ATA IDENTIFY data was not deterministic");
        router_read(16'h01F7, value);
        check(value == 8'h58 && !irq14, "ATA status read did not clear IRQ14");

        // XT2IDE-compatible secondary window: management presence, command
        // status, high-byte latch at 308h, and the single 309h hole.
        mgmt_write_word(16'hF006, 16'h0009);
        router_read(16'h0307, value);
        check(value == 8'h80 && ide_request == 3'b110,
              "XT-IDE status/presence path was incorrect");
        router_write(16'h0308, 8'hA5);
        router_read(16'h0308, value);
        check(value == 8'hA5, "XT-IDE high-byte latch did not round-trip");
        router_read(16'h0309, value);
        check(value == 8'hFF, "XT-IDE 309h hole was unexpectedly decoded");
        router_read(16'h030E, value);
        check(value == 8'h80, "XT-IDE alternate status was not decoded");

        // EGA register and A0000 aperture are routed by the same table.
        router_write(16'h03C0, 8'hAA);
        router_write(16'h03C2, 8'h63);
        router_read(16'h03CC, value);
        check(value == 8'h63 && video_io_selected == 1'b0,
              "EGA register programming/readback failed");
        // Enable all four planes before exercising the planar aperture.  The
        // frontend intentionally waits for the sequencer configuration toggle
        // instead of guessing a CPU write mask at reset.
        router_write(16'h03C4, 8'h02);
        router_write(16'h03C5, 8'h0F);
        router_write(16'h03C4, 8'h04);
        router_write(16'h03C5, 8'h06);
        @(negedge clk);
        request_address = 24'h0A0000;
        request_byte_enable = 2'b01;
        request_data_out = 16'h005A;
        request_valid = 1'b1;
        request_command_valid = 1'b1;
        request_write = 1'b1;
        request_io = 1'b0;
        #1;
        check(request_accept && selected_device == 4'd3 &&
              video_memory_selected, "EGA memory aperture was not selected");
        @(posedge clk);
        @(negedge clk);
        request_valid = 1'b0;
        request_command_valid = 1'b0;
        request_write = 1'b0;
        @(negedge clk);
        while (!request_ready) @(negedge clk);
        @(posedge clk);
        router_read_lane(16'h0000, 2'b01, value);
        // The read above intentionally exercises an unmapped deterministic
        // sink; the aperture read follows with a memory request.
        check(value == 8'hFF, "unmapped I/O did not return deterministic FFh");

        @(negedge clk);
        request_address = 24'h0A0000;
        request_byte_enable = 2'b01;
        request_valid = 1'b1;
        request_command_valid = 1'b1;
        request_write = 1'b0;
        request_io = 1'b0;
        #1;
        check(request_accept, "EGA memory read was not accepted");
        @(posedge clk);
        @(negedge clk);
        request_valid = 1'b0;
        request_command_valid = 1'b0;
        request_io = 1'b0;
        while (!request_ready) @(negedge clk);
        check(request_read_data_valid && request_read_data[7:0] == 8'h5A,
              "EGA memory aperture readback failed");
        @(posedge clk);

        // The IBM 5170 adapter sequence resets the uPD765 through DOR, senses
        // the reset interrupt and programs Specify.  This is the sequence used
        // by the Landmark "FLOPPY ADAPTER" test.
        mgmt_write_word(16'hF200, 16'h0001);
        mgmt_write_word(16'hF201, 16'h0000);
        mgmt_write_word(16'hF202, 16'd80);
        mgmt_write_word(16'hF203, 16'd15);
        mgmt_write_word(16'hF204, 16'd2400);
        mgmt_write_word(16'hF205, 16'd2);
        check(floppy_present[0], "FDC media-present state was not retained");

        router_write(16'h03F2, 8'h0C);
        router_write(16'h03F2, 8'h08);
        router_write(16'h03F2, 8'h0C);
        cycles = 0;
        while (!irq6 && cycles < 64) begin
            @(negedge clk);
            cycles = cycles + 1;
        end
        check(irq6 && irq_request[6],
              "DOR reset release did not assert IRQ6");
        fdc_write_fifo(8'h08);
        fdc_read_fifo(value);
        check((value & 8'hC0) == 8'hC0,
              "Sense Interrupt did not report controller reset");
        fdc_read_fifo(value);
        check(value == 8'h00, "Sense Interrupt returned a wrong cylinder");
        fdc_write_fifo(8'h03);
        fdc_write_fifo(8'hCF);
        fdc_write_fifo(8'h02);

        // Program DMA1 channel 2 exactly as an AT floppy read: physical
        // 010200h, 512 byte count, device-to-memory, single transfer mode.
        dma_write(16'h000C, 8'h00);
        dma_write(16'h0004, 8'h00);
        dma_write(16'h0004, 8'h02);
        dma_write(16'h0005, 8'hFF);
        dma_write(16'h0005, 8'h01);
        dma_write(16'h0081, 8'h01);
        dma_write(16'h000B, 8'h46);
        dma_write(16'h000A, 8'h02);

        router_write(16'h03F2, 8'h1C);
        fdc_write_fifo(8'h66);
        fdc_write_fifo(8'h00);
        fdc_write_fifo(8'h00);
        fdc_write_fifo(8'h00);
        fdc_write_fifo(8'h01);
        fdc_write_fifo(8'h02);
        fdc_write_fifo(8'h09);
        fdc_write_fifo(8'h2A);
        fdc_write_fifo(8'hFF);

        cycles = 0;
        while (!floppy_request[0] && cycles < 20000) begin
            @(negedge clk);
            cycles = cycles + 1;
        end
        check(floppy_request == 2'b01,
              "FDC did not request sector data from hps_ext");
        for (cycles = 0; cycles < 512; cycles = cycles + 1)
            mgmt_write_word(16'hF20F, {8'h00, cycles[7:0]});

        cycles = 0;
        while (((dma_beat_count < 512) ||
                (dma_terminal_count_seen < 1)) && cycles < 5000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        #1;
        check(dma_beat_count == 512 && dma_terminal_count_seen == 1,
              "FDC DMA did not complete one 512-byte sector");
        check(dma_addresses[0] == 24'h010200 &&
               dma_addresses[1] == 24'h010201,
              "floppy DMA page/address sequencing was incorrect");
        check(dma_lanes[0] == 2'b01 && dma_payloads[0][7:0] == 8'h00 &&
              dma_lanes[1] == 2'b10 && dma_payloads[1][15:8] == 8'h01,
              "floppy DMA did not align even/odd bytes to SDRAM lanes");
        cycles = 0;
        while (!irq6 && cycles < 10000) begin
            @(negedge clk);
            cycles = cycles + 1;
        end
        check(irq6 && irq_request[6] && !devices_dma_request[2],
              "FDC terminal count did not produce IRQ6 and release DMA");
        for (cycles = 0; cycles < 7; cycles = cycles + 1) begin
            fdc_read_fifo(value);
            if (cycles == 0)
                check((value & 8'hC0) == 8'h00,
                      "FDC read result reported an abnormal termination");
        end
        check(!irq6, "FDC result read did not clear IRQ6");

        check(!devices_protocol_error && !dma_protocol_error &&
              !arbiter_protocol_error,
              "A5 device integration raised a protocol error");
        $display("A5_AT_DEVICES_PASS keyboard=1 rtc_irq8=1 ata_irq14=1 fdc_reset_sense_specify=1 floppy_dma_beats=%0d irq6=1 video=1",
                 dma_beat_count);
        $finish;
    end

    initial begin
        #5000000;
        $fatal(1, "CHECK_FAIL: global timeout");
    end
endmodule
