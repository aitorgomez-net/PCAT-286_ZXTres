// AT-profile boot splash controller.
//
// The XT profile owns the splash lifetime in the core.  Keeping the AT
// profile's lifetime in a small, clocked block gives it the same behaviour:
// one second of boot settling followed by a five-second splash.  The OSD
// option is still authoritative and can remove the splash immediately.
`timescale 1ns/1ps

module spk286_at_splash_control (
    input  logic clk,
    input  logic reset,
    input  logic option_off,
    input  logic second_tick,
    output logic splash_active,
    // Hold the CPU before the image starts as well as while it is visible.
    // The pending interval must not become an unintended first BIOS run.
    output logic boot_hold
);
    logic       splash_pending_q;
    logic [2:0] splash_seconds_q;

    assign boot_hold = reset | splash_pending_q | splash_active;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            splash_pending_q <= 1'b1;
            splash_seconds_q <= 3'd0;
            splash_active    <= 1'b0;
        end else if (option_off) begin
            // Match the XT profile: changing the option to No removes an
            // already visible splash and prevents it from starting.
            splash_pending_q <= 1'b0;
            splash_seconds_q <= 3'd0;
            splash_active    <= 1'b0;
        end else if (splash_pending_q) begin
            // Give the BIOS/SDRAM path one second to settle before putting
            // the image on screen, as the XT profile does.
            if (second_tick) begin
                splash_pending_q <= 1'b0;
                splash_seconds_q <= 3'd0;
                splash_active    <= 1'b1;
            end
        end else if (splash_active && second_tick) begin
            if (splash_seconds_q == 3'd4) begin
                splash_active <= 1'b0;
            end else begin
                splash_seconds_q <= splash_seconds_q + 3'd1;
            end
        end
    end
endmodule
