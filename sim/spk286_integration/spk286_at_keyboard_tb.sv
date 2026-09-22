`timescale 1ns/1ps
module spk286_at_keyboard_tb;
    logic clk = 0;
    always #10 clk = ~clk;
    logic reset = 1;
    logic [10:0] ps2_key = 0;
    wire byte_valid, byte_ready, translate_set1, overflow;
    wire [7:0] key_byte;
    logic request_valid = 0, request_write = 0;
    logic [23:0] request_address = 0;
    logic [15:0] request_data_out = 0;
    wire accept, ready, read_valid, obf, irq1, protocol_error;
    wire [15:0] read_data;
    wire [7:0] output_byte;
    integer reads = 0;
    integer trace_file;
    string trace_path;
    localparam integer EXPECT_BYTE_TIMEOUT_CYCLES = 4096;

    spk286_at_keyboard adapter (
        .clk(clk), .reset(reset), .ps2_key(ps2_key),
        .translate_set1(translate_set1), .keyboard_byte_ready(byte_ready),
        .keyboard_byte_valid(byte_valid), .keyboard_byte(key_byte),
        .overflow(overflow)
    );
    spk286_at_8042 controller (
        .clk(clk), .reset(reset), .request_valid(request_valid),
        .request_command_valid(request_valid), .request_write(request_write),
        .request_io(1'b1), .request_address(request_address),
        .request_byte_enable(2'b01), .request_data_out(request_data_out),
        .request_accept(accept), .request_ready(ready),
        .request_read_data(read_data), .request_read_data_valid(read_valid),
        .keyboard_byte_valid(byte_valid), .keyboard_byte(key_byte),
        .keyboard_byte_ready(byte_ready), .keyboard_translate_set1(translate_set1),
        .keyboard_output_valid(obf), .keyboard_output_byte(output_byte),
        .irq1(irq1), .a20_enable(), .cpu_reset_request(),
        .side_effect_count(), .protocol_error(protocol_error)
    );

    task automatic write_port(input [15:0] port, input [7:0] value);
        @(negedge clk);
        request_valid = 1;
        request_write = 1;
        request_address = {8'h00, port};
        request_data_out = {8'h00, value};
        @(posedge clk); #1;
        if (!ready) $fatal(1, "Write did not complete");
        @(negedge clk);
        request_valid = 0;
        request_write = 0;
        @(negedge clk);
    endtask

    task automatic set_command_byte(input [7:0] value);
        write_port(16'h64, 8'h60);
        write_port(16'h60, value);
        if (translate_set1 !== value[6]) $fatal(1, "Translation bit was lost");
    endtask

    task automatic key_event(input bit pressed, input bit extended, input [7:0] code);
        @(negedge clk);
        ps2_key = {~ps2_key[10], pressed, extended, code};
        @(negedge clk);
    endtask

    task automatic expect_byte(input [7:0] expected, input bit log_key = 0);
        integer cycles;
        cycles = 0;
        // 8042 self-test/device replies are intentionally delayed by 1023
        // controller clocks; leave enough time for those alongside key bytes.
        while (!obf && cycles < EXPECT_BYTE_TIMEOUT_CYCLES) begin
            @(negedge clk);
            cycles = cycles + 1;
        end
        if (!obf || !irq1) $fatal(1, "Missing output/IRQ1 for %02x", expected);
        // Model slow BIOS service: queued prefixes/breaks must not overwrite
        // the current byte or disappear while the CPU has not read it yet.
        repeat (11) begin
            @(negedge clk);
            if (!obf || output_byte !== expected || byte_ready)
                $fatal(1, "OBF changed while full: expected %02x, got %02x", expected, output_byte);
        end
        request_valid = 1;
        request_write = 0;
        request_address = 24'h60;
        @(posedge clk); #1;
        if (!ready || !read_valid || read_data[7:0] !== expected || obf || irq1)
            $fatal(1, "Port 60h read/pop failed: expected %02x, got %04x", expected, read_data);
        if (log_key) $fdisplay(trace_file, "%02x", read_data[7:0]);
        reads = reads + 1;
        @(negedge clk);
        request_valid = 0;
        @(negedge clk);
    endtask

    task automatic expect_sequence(input [63:0] bytes_le, input integer length);
        for (integer i = 0; i < length; i = i + 1)
            expect_byte(bytes_le[8*i +: 8]);
    endtask

    task automatic expect_idle;
        repeat (20) @(negedge clk);
        if (obf || irq1 || byte_valid) $fatal(1, "Unexpected duplicate/stale key");
    endtask

    initial begin
        if (!$value$plusargs("TRACE=%s", trace_path)) trace_path = "keyboard_scan_trace.txt";
        trace_file = $fopen(trace_path, "w");
        if (trace_file == 0) $fatal(1, "Cannot open trace");
        repeat (3) @(negedge clk);
        reset = 0;
        set_command_byte(8'h65); // Exact command byte used by the patched ROM.

        // Regression for the reported A->Enter, B->M and double characters.
        // Burst events while OBF is full to test ordering and backpressure.
        key_event(1, 0, 8'h1C); key_event(0, 0, 8'h1C);
        key_event(1, 0, 8'h32); key_event(0, 0, 8'h32);
        expect_byte(8'h1E, 1); expect_byte(8'h9E, 1);
        expect_byte(8'h30, 1); expect_byte(8'hB0, 1);
        expect_idle();
        key_event(1, 0, 8'h12); key_event(1, 0, 8'h1C);
        key_event(0, 0, 8'h1C); key_event(0, 0, 8'h12);
        key_event(1, 0, 8'h5A); key_event(0, 0, 8'h5A);
        expect_byte(8'h2A, 1); expect_byte(8'h1E, 1);
        expect_byte(8'h9E, 1); expect_byte(8'hAA, 1);
        expect_byte(8'h1C, 1); expect_byte(8'h9C, 1);
        expect_idle();
        $fclose(trace_file);

        // Extended modifiers, arrows, keypad Enter, and F7 (>7F in set 2).
        key_event(1, 1, 8'h14); key_event(0, 1, 8'h14);
        key_event(1, 1, 8'h6B); key_event(0, 1, 8'h6B);
        expect_sequence(64'hCBE0_4BE0_9DE0_1DE0, 8);
        key_event(1, 1, 8'h5A); key_event(0, 1, 8'h5A);
        expect_sequence(64'h0000_0000_9CE0_1CE0, 4);
        key_event(1, 0, 8'h83); key_event(0, 0, 8'h83);
        expect_sequence(64'hC141, 2);

        key_event(1, 1, 8'h7C); key_event(0, 1, 8'h7C);
        expect_sequence(64'hAAE0_B7E0_37E0_2AE0, 8);
        key_event(1, 1, 8'h77); key_event(0, 1, 8'h77);
        expect_sequence(64'h0000_C59D_E145_1DE1, 6);
        expect_idle();

        // With translation disabled, restore genuine set-2 F0/E0 streams.
        set_command_byte(8'h05);
        key_event(1, 0, 8'h1C); key_event(0, 0, 8'h1C);
        expect_sequence(64'h1CF0_1C, 3);
        key_event(1, 1, 8'h14); key_event(0, 1, 8'h14);
        expect_sequence(64'h14F0_E014_E0, 5);
        key_event(1, 1, 8'h7C); key_event(0, 1, 8'h7C);
        expect_sequence(64'h7CE0_12E0, 4);
        expect_sequence(64'h12F0_E07C_F0E0, 6);
        key_event(1, 1, 8'h77); key_event(0, 1, 8'h77);
        expect_sequence(64'h77F0_14F0_E177_14E1, 8);
        expect_idle();

        // Retain events while AD inhibits the interface. Controller replies
        // must not be translated and must take priority over queued events.
        set_command_byte(8'h65);
        write_port(16'h64, 8'hAD);
        key_event(1, 0, 8'h32); key_event(0, 0, 8'h32);
        expect_idle();
        write_port(16'h64, 8'hAA);
        expect_byte(8'h55);
        write_port(16'h64, 8'hAB);
        expect_byte(8'h00);
        write_port(16'h64, 8'hAE);
        expect_sequence(64'hB030, 2);
        expect_idle();
        if (overflow || protocol_error) $fatal(1, "Unexpected queue/controller error");

        // Toggle 1 survives core reset without replay. Flush a partial E0
        // sequence and then ensure the next key starts cleanly.
        key_event(1, 1, 8'h6B);
        repeat (5) @(negedge clk);
        reset = 1;
        key_event(0, 1, 8'h6B);
        if (!ps2_key[10]) key_event(1, 0, 8'h1C);
        repeat (3) @(negedge clk);
        reset = 0;
        expect_idle();
        set_command_byte(8'h65);
        key_event(1, 0, 8'h32); key_event(0, 0, 8'h32);
        expect_sequence(64'hB030, 2);
        expect_idle();
        if (overflow || protocol_error) $fatal(1, "Unexpected reset error");

        // FIFO overflow is reported, never overwrites queued entries.
        write_port(16'h64, 8'hAD);
        for (integer i = 0; i < 33; i = i + 1) key_event(1, 0, 8'h1C);
        if (!overflow) $fatal(1, "Missing FIFO overflow indication");
        write_port(16'h64, 8'hAE);
        for (integer i = 0; i < 32; i = i + 1) expect_byte(8'h1E);
        expect_idle();
        $display("AT_KEYBOARD_PASS reads=%0d mapping=1 make_break=1 extended=1 raw_set2=1 backpressure=1 reset=1", reads);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "AT keyboard global timeout");
    end
endmodule
