// AT-profile boot splash controller.
//
// The XT profile owns the splash lifetime in the core.  Keeping the AT
// profile's lifetime in a small, clocked block gives it the same behaviour:
// one second of boot settling followed by a five-second splash.  The OSD
// option is still authoritative and can remove the splash immediately.
// duration makes the splash ten or fifteen seconds instead (the ZXTRES+ OSD
// offers it; the MiSTer top ties it to five).
// F12 on the splash (paused) holds it, and the CPU, until pressed again.
`timescale 1ns/1ps

module spk286_at_splash_control (
    input  logic clk,
    input  logic reset,
    input  logic option_off,
    input  logic second_tick,
    input  logic paused,
    input  logic [1:0] duration,   // 0: 5 s, 1: 10 s, 2: 15 s
    output logic splash_active,
    // Raised for the last second of the splash so the picture can fade out
    // before the machine starts. F12 holds the splash, and lifts this too.
    output logic fade_out,
    // Hold the CPU before the image starts as well as while it is visible.
    // The pending interval must not become an unintended first BIOS run.
    output logic boot_hold
);
    logic       splash_pending_q;
    logic [3:0] splash_seconds_q;
    wire  [3:0] last_second = duration == 2'd2 ? 4'd14 :
                              duration == 2'd1 ? 4'd9 : 4'd4;

    assign boot_hold = reset | splash_pending_q | splash_active;
    // Registered: it crosses into the video clock domain, where a decode
    // glitch on its synchronizer would start the fade early.
    always_ff @(posedge clk or posedge reset) begin
        if (reset)
            fade_out <= 1'b0;
        else
            fade_out <= splash_active && (splash_seconds_q == last_second) && !paused &&
                        !option_off;
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            splash_pending_q <= 1'b1;
            splash_seconds_q <= 4'd0;
            splash_active    <= 1'b0;
        end else if (option_off) begin
            // Match the XT profile: changing the option to No removes an
            // already visible splash and prevents it from starting.
            splash_pending_q <= 1'b0;
            splash_seconds_q <= 4'd0;
            splash_active    <= 1'b0;
        end else if (splash_pending_q) begin
            // Give the BIOS/SDRAM path one second to settle before putting
            // the image on screen, as the XT profile does.
            if (second_tick) begin
                splash_pending_q <= 1'b0;
                splash_seconds_q <= 4'd0;
                splash_active    <= 1'b1;
            end
        end else if (splash_active && second_tick && !paused) begin
            if (splash_seconds_q == last_second) begin
                splash_active <= 1'b0;
            end else begin
                splash_seconds_q <= splash_seconds_q + 4'd1;
            end
        end
    end
endmodule
