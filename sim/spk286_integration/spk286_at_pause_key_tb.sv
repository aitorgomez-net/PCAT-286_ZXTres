`timescale 1ns/1ps

// F12 pause front end: F12 never reaches the machine, its release toggles the
// pause, presses are dropped while paused (releases are not), and nothing
// toggles while the splash holds the machine.
module spk286_at_pause_key_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    logic allow = 1'b1;
    logic [10:0] key_in = 11'd0;
    wire  [10:0] key_out;
    wire         pause;

    always #10 clk = ~clk;

    spk286_at_pause_key dut (
        .clk(clk), .reset(reset), .allow(allow),
        .ps2_key_in(key_in), .ps2_key_out(key_out), .pause(pause)
    );

    integer forwarded = 0;
    logic [10:0] key_out_q = 11'd0;
    logic [9:0]  last_forwarded = 10'd0;
    always @(posedge clk) begin
        if (key_out[10] != key_out_q[10]) begin
            forwarded = forwarded + 1;
            last_forwarded = key_out[9:0];
        end
        key_out_q <= key_out;
    end

    task automatic send(input logic pressed, input logic extended, input logic [7:0] code);
        begin
            @(negedge clk);
            key_in = {~key_in[10], pressed, extended, code};
            repeat (3) @(negedge clk);
        end
    endtask

    task automatic expect_forwarded(input integer count, input string what);
        begin
            if (forwarded != count)
                $fatal(1, "%s: %0d events forwarded, expected %0d", what, forwarded, count);
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        reset = 1'b0;
        repeat (2) @(negedge clk);

        send(1'b1, 1'b0, 8'h1C);              // A down
        send(1'b0, 1'b0, 8'h1C);              // A up
        expect_forwarded(2, "ordinary keys");
        if (last_forwarded != {1'b0, 1'b0, 8'h1C})
            $fatal(1, "forwarded event changed");

        send(1'b1, 1'b0, 8'h07);              // F12 down
        if (pause) $fatal(1, "pause toggled on the F12 press");
        send(1'b0, 1'b0, 8'h07);              // F12 up
        if (!pause) $fatal(1, "F12 release did not pause");
        expect_forwarded(2, "F12 reached the machine");

        send(1'b1, 1'b0, 8'h1B);              // S down while paused
        expect_forwarded(2, "press forwarded while paused");
        send(1'b0, 1'b0, 8'h1B);              // S up while paused
        expect_forwarded(3, "release dropped while paused");

        send(1'b1, 1'b1, 8'h07);              // E0 07 is not F12
        expect_forwarded(3, "extended press forwarded while paused");

        send(1'b1, 1'b0, 8'h07);
        send(1'b0, 1'b0, 8'h07);
        if (pause) $fatal(1, "second F12 did not resume");
        expect_forwarded(3, "F12 forwarded on resume");

        // Splash hold: F12 is swallowed and does nothing, keys still pass.
        allow = 1'b0;
        send(1'b1, 1'b0, 8'h07);
        send(1'b0, 1'b0, 8'h07);
        if (pause) $fatal(1, "F12 paused the machine during the splash hold");
        send(1'b1, 1'b0, 8'h1C);
        expect_forwarded(4, "keys during the splash hold");
        allow = 1'b1;

        // A machine reset clears the pause and replays nothing.
        send(1'b1, 1'b0, 8'h07);
        send(1'b0, 1'b0, 8'h07);
        if (!pause) $fatal(1, "pause did not engage");
        @(negedge clk);
        reset = 1'b1;
        repeat (2) @(negedge clk);
        reset = 1'b0;
        repeat (4) @(negedge clk);
        if (pause) $fatal(1, "reset did not clear the pause");
        expect_forwarded(4, "event replayed after reset");

        $display("AT_PAUSE_KEY_PASS forwarded=%0d", forwarded);
        $finish;
    end
endmodule
