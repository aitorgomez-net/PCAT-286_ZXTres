// zxtres_ps2_key: set-2 bytes to ps2_key events, and Win+F12 kept from the
// core. Run with zxtres/sim/run_ps2_key_test.sh.
`timescale 1ns/1ps
module zxtres_ps2_key_tb;
    logic clk = 1'b0;
    always #10 clk = !clk;
    logic reset = 1'b1, osd_open = 1'b0, byte_valid = 1'b0;
    logic [7:0] byte_in = 8'h00;
    wire [10:0] ps2_key;
    zxtres_ps2_key dut (.clk(clk), .reset(reset), .osd_open(osd_open),
                        .byte_valid(byte_valid), .byte_in(byte_in), .ps2_key(ps2_key));

    logic toggle_seen = 1'b0;
    int events = 0;
    logic [9:0] last = '0;
    always @(posedge clk) if (!reset && ps2_key[10] != toggle_seen) begin
        toggle_seen <= ps2_key[10];
        events++;
        last <= ps2_key[9:0];
    end

    task automatic send(input logic [7:0] value);
        @(negedge clk) begin byte_valid = 1'b1; byte_in = value; end
        @(negedge clk) byte_valid = 1'b0;
        repeat (2) @(negedge clk);
    endtask
    // A key: make (or break) of a set-2 code, E0 prefix for extended keys.
    task automatic key(input bit extended, input bit make, input logic [7:0] code);
        if (extended) send(8'hE0);
        if (!make) send(8'hF0);
        send(code);
    endtask
    task automatic expect_events(input int count, input string what);
        if (events != count) $fatal(1, "%s: %0d events, expected %0d", what, events, count);
    endtask

    initial begin
        repeat (3) @(negedge clk);
        reset = 1'b0;
        repeat (2) @(negedge clk);

        key(0, 1, 8'h07);                          // F12 alone reaches the core
        expect_events(1, "F12 make");
        if (last != {1'b1, 1'b0, 8'h07}) $fatal(1, "F12 make event %h", last);
        key(0, 0, 8'h07);
        expect_events(2, "F12 break");
        if (last != {1'b0, 1'b0, 8'h07}) $fatal(1, "F12 break event %h", last);

        key(1, 1, 8'h1F);                          // left Win down: an event
        expect_events(3, "LWin make");
        key(0, 1, 8'h07);                          // Win+F12: none
        key(0, 0, 8'h07);
        expect_events(3, "Win+F12");
        key(1, 0, 8'h1F);
        expect_events(4, "LWin break");

        key(1, 1, 8'h27);                          // right Win, released before F12
        key(0, 1, 8'h07);
        key(1, 0, 8'h27);
        key(0, 0, 8'h07);                          // the release of a menu F12: none
        expect_events(6, "RWin+F12, Win released first");
        key(0, 1, 8'h07);                          // then F12 alone again
        expect_events(7, "F12 after Win+F12");
        key(0, 0, 8'h07);

        // Win+F12 opens the OSD; the Win release is hidden from the core,
        // and the Windows key counts as up once the OSD closes.
        key(1, 1, 8'h1F);
        key(0, 1, 8'h07);
        key(0, 0, 8'h07);
        expect_events(9, "Win+F12 before the OSD");
        osd_open = 1'b1;
        repeat (3) @(negedge clk);
        osd_open = 1'b0;
        repeat (3) @(negedge clk);
        key(0, 1, 8'h07);
        expect_events(10, "F12 after the OSD closed");
        key(0, 0, 8'h07);

        key(0, 1, 8'h1C);                          // other keys untouched
        key(0, 0, 8'h1C);
        expect_events(13, "A");
        $display("ZXTRES_PS2_KEY_PASS");
        $finish;
    end
endmodule
