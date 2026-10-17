//============================================================================
//
//  Splash fade level: rises 2 per frame to 64 while the splash shows, falls
//  1 per frame while fade_out is held, goes back up if fade_out is released
//  (F12 hold), ignores clocks between frames and restarts from black every
//  time the splash appears.
//
//============================================================================

`timescale 1ns/1ps
`default_nettype wire

module vga_splash_fade_tb;

    reg clock = 1'b0;
    always #5 clock = ~clock;

    reg reset = 1'b1;
    reg active = 1'b0;
    reg fade_out = 1'b0;
    reg frame_tick = 1'b0;
    wire [6:0] level;

    vga_splash_fade dut (
        .clock(clock), .reset(reset), .active(active),
        .fade_out(fade_out), .frame_tick(frame_tick), .level(level)
    );

    integer errors = 0;
    integer frames;

    task frame;
        begin
            @(negedge clock) frame_tick = 1'b1;
            @(negedge clock) frame_tick = 1'b0;
            repeat (3) @(negedge clock);
        end
    endtask

    task expect_level(input [6:0] want, input [8*24-1:0] what);
        begin
            if (level !== want) begin
                $display("FAIL: %0s: level %0d, expected %0d", what, level, want);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        repeat (2) @(negedge clock);
        reset = 1'b0;
        frame;
        expect_level(7'd0, "inactive");

        active = 1'b1;
        repeat (10) @(negedge clock);
        expect_level(7'd0, "no frame yet");
        frame;
        expect_level(7'd2, "first frame");
        for (frames = 1; frames < 32; frames = frames + 1)
            frame;
        expect_level(7'd64, "after 32 frames");
        frame;
        expect_level(7'd64, "saturated");

        fade_out = 1'b1;
        repeat (10) frame;
        expect_level(7'd54, "fading out");
        fade_out = 1'b0;                     // F12 holds the splash
        frame;
        expect_level(7'd56, "fade reversed");
        fade_out = 1'b1;
        repeat (80) frame;
        expect_level(7'd0, "faded out");

        active = 1'b0;
        @(negedge clock);
        @(negedge clock);
        expect_level(7'd0, "splash over");
        fade_out = 1'b0;
        active = 1'b1;
        frame;
        expect_level(7'd2, "restarts from black");

        if (errors == 0)
            $display("PASS: splash fade ramps 0->64 in 32 frames and back");
        else
            $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
