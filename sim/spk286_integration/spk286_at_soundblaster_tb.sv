`timescale 1ns/1ps

// Exercise the migrated AT adapter, not just the imported ISA Sound Blaster.
// CPU accesses use both AT byte lanes and discard the live address after
// acceptance. DMA uses the production AT controller with delayed RAM reads.
module spk286_at_soundblaster_tb;
    logic clk = 0;
    always #10 clk = ~clk;
    logic reset = 1;
    logic request_valid = 0;
    logic request_write = 0;
    logic [23:0] request_address = 0;
    logic [1:0] request_byte_enable = 0;
    logic [15:0] request_data_out = 0;
    wire sound_accept, sound_ready, sound_read_valid;
    wire dma_accept, dma_ready, dma_read_valid;
    wire [15:0] sound_read_data, dma_read_data;
    wire [7:0] dma_request;
    wire dma_bus_request, dma_valid, dma_complete, dma_tc;
    wire [2:0] dma_channel;
    wire [23:0] dma_address;
    wire [1:0] dma_lanes;
    wire dma_write_memory, dma_read_memory;
    wire endpoint_accept, endpoint_ready;
    wire [15:0] endpoint_data, dma_data;
    wire sb_irq, dma_error;
    reg [7:0] ram [0:255];
    integer memory_delay = 0;
    wire memory_valid = dma_valid && dma_read_memory &&
                        (memory_delay >= 3 + int'(dma_address[1:0]));
    wire [15:0] memory_byte = memory_valid ?
                              {8'h00, ram[dma_address[7:0]]} : 16'hDEAD;

    spk286_at_sound sound (
        .clk(clk), .reset(reset), .warm_reset(1'b0),
        .cpu_sample_edge(1'b1), .opl2_io(2'd2),
        .cms_en(1'b0), .tandy_en(1'b0), .sb_en(1'b1),
        .request_valid(request_valid), .request_command_valid(request_valid),
        .request_write(request_write), .request_io(1'b1),
        .request_address(request_address),
        .request_byte_enable(request_byte_enable),
        .request_data_out(request_data_out),
        .request_accept(sound_accept), .request_ready(sound_ready),
        .request_read_data(sound_read_data),
        .request_read_data_valid(sound_read_valid),
        .dma_transfer_valid(dma_valid), .dma_transfer_complete(dma_complete),
        .dma_transfer_read_from_memory(dma_read_memory),
        .dma_memory_data_valid(memory_valid), .dma_active_channel(dma_channel),
        .dma_transfer_data_in(memory_byte),
        .dma_transfer_accept(endpoint_accept), .dma_transfer_ready(endpoint_ready),
        .dma_transfer_data_out(endpoint_data), .dma_request(dma_request),
        .sb_irq(sb_irq), .opl2_sound(), .cms_sound_l(), .cms_sound_r(),
        .tandy_sound(), .sb_sound_l(), .sb_sound_r(),
        .side_effect_count(), .protocol_error()
    );

    spk286_at_dma dma (
        .clk(clk), .reset(reset),
        .request_valid(request_valid), .request_command_valid(request_valid),
        .request_write(request_write), .request_io(1'b1),
        .request_address(request_address),
        .request_byte_enable(request_byte_enable),
        .request_data_out(request_data_out),
        .request_accept(dma_accept), .request_ready(dma_ready),
        .request_read_data(dma_read_data), .request_read_data_valid(dma_read_valid),
        .dma_request(dma_request), .dma_grant(dma_bus_request),
        .transfer_accept(endpoint_accept), .transfer_ready(endpoint_ready),
        .transfer_data_in(endpoint_data), .dma_bus_request(dma_bus_request),
        .dma_transfer_valid(dma_valid), .dma_active_channel(dma_channel),
        .dma_transfer_address(dma_address), .dma_transfer_byte_enable(dma_lanes),
        .dma_transfer_write_to_memory(dma_write_memory),
        .dma_transfer_read_from_memory(dma_read_memory),
        .dma_transfer_io_to_memory(), .dma_transfer_memory_to_io(),
        .dma_transfer_data_out(dma_data), .dma_transfer_complete(dma_complete),
        .dma_terminal_count(dma_tc), .dma_request_state(), .dma_acknowledge(),
        .cascade_request(), .protocol_error(dma_error)
    );

    task automatic check(input logic ok, input string message);
        if (ok !== 1'b1) $fatal(1, "AT_SB_FAIL: %s", message);
    endtask

    task automatic io_cycle(input logic wr, input logic [15:0] port,
                            input logic [7:0] value, output logic [7:0] result);
        integer cycles;
        logic [15:0] answer;
        begin
            @(negedge clk);
            request_valid = 1;
            request_write = wr;
            request_address = {8'h00, port};
            request_byte_enable = port[0] ? 2'b10 : 2'b01;
            request_data_out = port[0] ? {value, 8'h00} : {8'h00, value};
            #1;
            check(sound_accept ^ dma_accept, $sformatf("port %h not accepted", port));
            @(negedge clk);
            request_valid = 0;
            request_address = 0;
            request_data_out = 0;
            cycles = 0;
            while (!(sound_ready || dma_ready) && cycles < 40) begin
                @(negedge clk);
                cycles++;
            end
            check(sound_ready || dma_ready, $sformatf("port %h timed out", port));
            if (!wr) begin
                check(sound_read_valid || dma_read_valid, "missing read data valid");
                answer = sound_read_valid ? sound_read_data : dma_read_data;
                result = port[0] ? answer[15:8] : answer[7:0];
                check((port[0] ? answer[7:0] : answer[15:8]) == 0,
                      "read data leaked into the other AT byte lane");
            end else result = 0;
            @(negedge clk);
        end
    endtask

    task automatic io_write(input logic [15:0] port, input logic [7:0] value);
        logic [7:0] unused;
        io_cycle(1, port, value, unused);
    endtask

    task automatic io_read(input logic [15:0] port, output logic [7:0] value);
        io_cycle(0, port, 0, value);
    endtask

    task automatic dsp_write(input logic [7:0] value);
        logic [7:0] status;
        integer polls;
        begin
            status = 8'hFF;
            polls = 0;
            while (status[7] && polls < 300) begin
                io_read(16'h022C, status);
                polls++;
            end
            check(!status[7], "DSP write busy did not clear");
            io_write(16'h022C, value);
        end
    endtask

    task automatic expect_reply(input logic [7:0] expected);
        logic [7:0] status, value;
        integer polls;
        begin
            status = 0;
            polls = 0;
            while (!status[7] && polls < 300) begin
                io_read(16'h022E, status);
                polls++;
            end
            check(status[7], "DSP read-ready did not assert");
            io_read(16'h022A, value);
            check(value == expected,
                  $sformatf("DSP reply expected %h, got %h", expected, value));
        end
    endtask

    task automatic reset_dsp;
        begin
            io_write(16'h0226, 1);
            repeat (200) @(negedge clk); // ISA reset pulse >= 3 us.
            io_write(16'h0226, 0);
            expect_reply(8'hAA);
        end
    endtask

    task automatic program_dma1(input logic [15:0] address,
                                input logic [15:0] count,
                                input logic [7:0] mode);
        begin
            io_write(16'h000A, 8'h05); // Mask channel 1 while programming.
            io_write(16'h000C, 0);
            io_write(16'h0002, address[7:0]);
            io_write(16'h0002, address[15:8]);
            io_write(16'h0003, count[7:0]);
            io_write(16'h0003, count[15:8]);
            io_write(16'h0083, 0);
            io_write(16'h000B, mode);
            io_write(16'h000A, 8'h01);
        end
    endtask

    integer beats = 0;
    integer playback_acks = 0;
    integer terminal_counts = 0;
    logic playback = 0;
    logic [23:0] expected_address = 0;
    always @(posedge clk) begin
        if (!dma_valid || dma_complete) memory_delay <= 0;
        else memory_delay <= memory_delay + 1;
        if (!reset) begin
            check(!dma_error, "AT DMA protocol error");
            if (dma_tc) terminal_counts <= terminal_counts + 1;
            if (dma_valid && endpoint_accept) begin
                check(dma_channel == 1, "DMA used a channel other than 1");
                check(dma_address == expected_address, "DMA address skipped or repeated");
                expected_address <= expected_address + 1;
                check(dma_lanes == (dma_address[0] ? 2'b10 : 2'b01),
                      "DMA byte lane does not match address");
                if (dma_write_memory)
                    ram[dma_address[7:0]] <= dma_address[0] ? dma_data[15:8] : dma_data[7:0];
                else check(memory_valid, "playback accepted before RAM responded");
                beats <= beats + 1;
            end
            if (playback && sound.GEN_SOUND_BLASTER.u_soundblaster.dsp_dma_ack) begin
                check(sound.GEN_SOUND_BLASTER.u_soundblaster.dsp_dma_readdata ==
                      ((8'h30 + 8'(playback_acks)) ^ 8'h5A),
                      "DSP received the wrong PCM byte");
                playback_acks <= playback_acks + 1;
            end
        end
    end

    task automatic wait_beats(input integer expected);
        integer cycles;
        begin
            cycles = 0;
            while (beats < expected && cycles < 300000) begin
                @(negedge clk);
                cycles++;
            end
            check(beats == expected, "DMA did not transfer the expected byte count");
            repeat (20) @(negedge clk);
        end
    endtask

    logic [7:0] value;
    integer cycles;
    initial begin
        for (integer i = 0; i < 256; i++) ram[i] = 8'(i) ^ 8'h5A;
        repeat (12) @(negedge clk);
        reset = 0;
        reset_dsp();
        io_read(16'h022E, value);
        check(!value[7], "reset reply was not consumed exactly once");
        dsp_write(8'hE1);
        expect_reply(8'h03);
        expect_reply(8'h00);
        io_read(16'h022E, value);
        check(!value[7], "DSP version reply was duplicated");
        dsp_write(8'hE0);
        dsp_write(8'h5A);
        expect_reply(8'hA5);
        io_write(16'h0224, 8'h04);
        io_write(16'h0225, 8'hA4);
        io_read(16'h0225, value);
        check(value == 8'hB5, "SB Pro mixer odd-lane readback failed");
        $display("AT_SB_DETECTION_PASS reset=AA version=3.00 identify=A5 mixer=B5");

        dsp_write(8'hF2);
        repeat (400) @(negedge clk);
        check(sb_irq, "DSP F2 did not assert IRQ");
        io_read(16'h022C, value);
        check(sb_irq, "unrelated status read cleared IRQ");
        io_read(16'h022E, value);
        check(!sb_irq, "DSP status read did not acknowledge IRQ");

        // CT-VOICE-style E2 authentication: the two replies must reach RAM,
        // including the odd byte lane, through the actual AT DMA controller.
        io_write(16'h000D, 0);
        io_write(16'h00DA, 0);
        io_write(16'h00D6, 8'hC0);
        io_write(16'h00D4, 0);
        expected_address = 24'h001200;
        program_dma1(16'h1200, 1, 8'h45);
        dsp_write(8'hE2);
        dsp_write(8'h9C);
        wait_beats(1);
        check(ram[0] == 8'hB4, "first E2 DMA identification reply incorrect");
        dsp_write(8'hE2);
        dsp_write(8'hFE);
        wait_beats(2);
        check(ram[1] == 8'h0F, "second E2 DMA identification reply incorrect");
        check(terminal_counts == 1, "E2 DMA terminal count incorrect");
        $display("AT_SB_DMA_ID_PASS channel=1 replies=B4,0F lanes=even,odd");

        reset_dsp();
        expected_address = 24'h001230;
        program_dma1(16'h1230, 31, 8'h49);
        playback = 1;
        dsp_write(8'hD1);
        dsp_write(8'h40);
        dsp_write(8'hC0);
        dsp_write(8'h14);
        dsp_write(31);
        dsp_write(0);
        wait_beats(34);
        cycles = 0;
        while (!sb_irq && cycles < 20000) begin
            @(negedge clk);
            cycles++;
        end
        check(sb_irq, "PCM block did not complete with IRQ");
        check(playback_acks == 32, "DSP consumed the wrong PCM byte count");
        check(terminal_counts == 2, "PCM DMA terminal count incorrect");
        io_read(16'h022E, value);
        check(!sb_irq, "PCM completion IRQ did not clear");
        repeat (1000) @(negedge clk);
        check(beats == 34 && playback_acks == 32 && !dma_request[1],
              "extra DMA request after block completion");
        $display("AT_SB_PCM_PASS bytes=32 delayed_ram=1 irq_ack=1");
        $display("AT_SOUNDBLASTER_TEST_PASS");
        $finish;
    end

    initial begin
        #20000000;
        $fatal(1, "AT_SB_FAIL: global timeout");
    end
endmodule
