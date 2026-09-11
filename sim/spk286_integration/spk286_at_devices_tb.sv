`timescale 1ns/1ps

module spk286_at_devices_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

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

    spk286_at_device_router devices (
        .clk(clk), .reset(reset),
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
        .dma_transfer_accept(devices_dma_transfer_accept),
        .dma_transfer_ready(devices_dma_transfer_ready),
        .dma_transfer_data_out(devices_dma_transfer_data_out),
        .dma_request(devices_dma_request), .irq6(irq6), .irq14(irq14),
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
        .transfer_data_in(16'h0000),
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
            while (!request_ready && cycles < 12) begin
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
            while (!request_ready && cycles < 12) begin
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
            while (!request_ready && cycles < 12) begin
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
                dma_beat_count = dma_beat_count + 1;
            end
            if (dma_terminal_count)
                dma_terminal_count_seen = dma_terminal_count_seen + 1;
            check(!(dma_grant && refresh_grant),
                  "A5 arbiter granted DMA and refresh together");
        end
    end

    initial begin : run
        logic [7:0] value;
        logic [15:0] word_value;
        integer cycles;

        repeat (3) @(negedge clk);
        reset = 1'b0;

        // 8042 keyboard output buffer, IRQ1 and output-port A20 control.
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
        router_read(16'h0064, value);
        check(value[2] && !value[0], "8042 status register was incorrect");

        // RTC index/data, NMI mask, periodic IRQ8 and deterministic seconds.
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

        // EGA register and A0000 aperture shadow are routed by the same table.
        router_write(16'h03C0, 8'hAA);
        router_read(16'h03C0, value);
        check(value == 8'hAA && video_io_selected == 1'b0,
              "EGA I/O register routing/readback failed");
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

        // Floppy command + A4 DMA1 channel 2: two beats and terminal IRQ6.
        dma_write(16'h000C, 8'h00);
        dma_write(16'h0004, 8'h00);
        dma_write(16'h0004, 8'h02);
        dma_write(16'h0005, 8'h01);
        dma_write(16'h0005, 8'h00);
        dma_write(16'h0081, 8'h01);
        dma_write(16'h000B, 8'h86);
        dma_write(16'h000A, 8'h02);
        router_write(16'h03F5, 8'h06);
        #1;
        check(devices_dma_request[2] && irq_request[6] == 1'b0,
              "floppy command did not request DMA channel 2");

        cycles = 0;
        while (((dma_beat_count < 2) ||
                (dma_terminal_count_seen < 1)) && cycles < 160) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        #1;
        check(dma_beat_count == 2 && dma_terminal_count_seen == 1,
              "floppy-like DMA did not complete two beats");
        check(dma_addresses[0] == 24'h010200 &&
              dma_addresses[1] == 24'h010201,
              "floppy DMA page/address sequencing was incorrect");
        check(irq6 && irq_request[6] && !devices_dma_request[2],
              "floppy terminal count did not produce IRQ6 and release DMA");
        router_read(16'h03F4, value);
        check(!irq6, "floppy status read did not clear IRQ6");

        check(!devices_protocol_error && !dma_protocol_error &&
              !arbiter_protocol_error,
              "A5 device integration raised a protocol error");
        $display("A5_AT_DEVICES_PASS keyboard=1 rtc_irq8=1 ata_irq14=1 floppy_dma_beats=%0d irq6=1 video=1",
                 dma_beat_count);
        $finish;
    end

    initial begin
        #300000;
        $fatal(1, "CHECK_FAIL: global timeout");
    end
endmodule
