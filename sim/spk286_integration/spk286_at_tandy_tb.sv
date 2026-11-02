`timescale 1ns/1ps

// Tandy 3-voice (SN76489) on the AT sound adapter: writes at C0h and at the
// RLX/RSX ports 1E0h-1E3h reach the chip, 1E4h and the disabled chip do not.
module spk286_at_tandy_tb;
    logic clk = 0;
    always #10 clk = ~clk;
    logic reset = 1;
    logic tandy_en = 1;
    logic request_valid = 0;
    logic [23:0] request_address = 0;
    logic [1:0] request_byte_enable = 0;
    logic [15:0] request_data_out = 0;
    wire sound_accept, sound_ready;
    wire signed [10:0] tandy_sound;

    spk286_at_sound sound (
        .clk(clk), .reset(reset), .warm_reset(1'b0),
        .cpu_sample_edge(1'b1), .opl2_io(2'd2),
        .cms_en(1'b0), .tandy_en(tandy_en), .sb_en(1'b0),
        .request_valid(request_valid), .request_command_valid(request_valid),
        .request_write(1'b1), .request_io(1'b1),
        .request_address(request_address),
        .request_byte_enable(request_byte_enable),
        .request_data_out(request_data_out),
        .request_accept(sound_accept), .request_ready(sound_ready),
        .request_read_data(), .request_read_data_valid(),
        .dma_transfer_valid(1'b0), .dma_transfer_complete(1'b0),
        .dma_transfer_read_from_memory(1'b0), .dma_memory_data_valid(1'b0),
        .dma_active_channel(3'd0), .dma_transfer_data_in(16'h0000),
        .dma_transfer_accept(), .dma_transfer_ready(),
        .dma_transfer_data_out(), .dma_request(), .sb_irq(),
        .opl2_sound(), .cms_sound_l(), .cms_sound_r(),
        .tandy_sound(tandy_sound), .sb_sound_l(), .sb_sound_r(),
        .side_effect_count(), .protocol_error()
    );

    task automatic check(input logic ok, input string message);
        if (ok !== 1'b1) $fatal(1, "AT_TANDY_FAIL: %s", message);
    endtask

    // Offer a byte write; return whether the adapter took it. A taken write
    // waits for the chip's ready, about 32 clocks of 3.58 MHz.
    task automatic io_write(input logic [15:0] port, input logic [7:0] value,
                            output logic taken);
        integer cycles;
        begin
            @(negedge clk);
            request_valid = 1;
            request_address = {8'h00, port};
            request_byte_enable = port[0] ? 2'b10 : 2'b01;
            request_data_out = port[0] ? {value, 8'h00} : {8'h00, value};
            #1;
            taken = sound_accept;
            @(negedge clk);
            request_valid = 0;
            request_address = 0;
            request_data_out = 0;
            if (taken) begin
                cycles = 0;
                while (!sound_ready && cycles < 1000) begin
                    @(negedge clk);
                    cycles++;
                end
                check(sound_ready, $sformatf("port %h timed out", port));
                @(negedge clk);
            end
        end
    endtask

    task automatic chip_write(input logic [15:0] port, input logic [7:0] value);
        logic taken;
        begin
            io_write(port, value, taken);
            check(taken, $sformatf("port %h not taken", port));
        end
    endtask

    task automatic not_taken(input logic [15:0] port);
        logic taken;
        begin
            io_write(port, 8'h90, taken);
            check(!taken, $sformatf("port %h taken", port));
        end
    endtask

    // Peak-to-peak and sign changes of the chip output over 2 ms. A tone
    // counter left at zero first runs through all 1024 steps (about 4.6 ms)
    // before it loads the new divider, so wait 6 ms first.
    task automatic measure(output integer swing, output integer changes);
        integer lo, hi;
        logic signed [10:0] last;
        begin
            repeat (300000) @(posedge clk);
            lo = 0; hi = 0; changes = 0; last = tandy_sound;
            repeat (100000) begin
                @(posedge clk);
                if (tandy_sound != last) changes++;
                last = tandy_sound;
                if (tandy_sound < lo) lo = tandy_sound;
                if (tandy_sound > hi) hi = tandy_sound;
            end
            swing = hi - lo;
        end
    endtask

    integer swing, changes;
    initial begin
        repeat (5) @(negedge clk);
        reset = 0;
        repeat (5) @(negedge clk);

        // Channel 0 at C0h: divider 020h (about 3.5 kHz), full volume.
        chip_write(16'h00C0, 8'h80);
        chip_write(16'h00C0, 8'h02);
        chip_write(16'h00C0, 8'h90);
        measure(swing, changes);
        check(swing > 100 && changes > 4, $sformatf("no tone from C0h (%0d, %0d)", swing, changes));

        // Silence it through 1E0h: the same chip answers there.
        chip_write(16'h01E0, 8'h9F);
        measure(swing, changes);
        check(swing == 0, $sformatf("1E0h did not silence channel 0 (%0d)", swing));

        // Channel 1 through 1E2h, volume through the odd lane at 1E3h.
        chip_write(16'h01E2, 8'hA0);
        chip_write(16'h01E2, 8'h02);
        chip_write(16'h01E3, 8'hB0);
        measure(swing, changes);
        check(swing > 100 && changes > 4, $sformatf("no tone from 1E2h/1E3h (%0d, %0d)", swing, changes));
        $display("AT_TANDY_PORTS_PASS C0h 1E0h 1E2h 1E3h");

        // 1E4h-1E7h was the Tandy DAC, which is not there.
        not_taken(16'h01E4);
        not_taken(16'h01E7);
        not_taken(16'h01DF);
        // Disabled in the OSD: neither window answers.
        tandy_en = 0;
        not_taken(16'h00C0);
        not_taken(16'h01E0);
        $display("AT_TANDY_DECODE_PASS dac=absent disabled=absent");
        $display("AT_TANDY_TEST_PASS");
        $finish;
    end

    initial begin
        #60000000;
        $fatal(1, "AT_TANDY_FAIL: global timeout");
    end
endmodule
