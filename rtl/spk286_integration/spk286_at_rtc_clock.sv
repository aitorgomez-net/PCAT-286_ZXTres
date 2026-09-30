// RTC reference enables from the fixed 50 MHz AT clock. These are one-cycle
// pulses, not derived clocks. 32768 / 50000000 reduces to 256 / 390625;
// the fractional divider gives 1525/1526-clock intervals with no rate drift.
// Keep the one-second enable independent of RTC rate programming (and usable
// by the boot splash). CPU /2 diagnostic mode does not change this timebase.
`timescale 1ns/1ps
module spk286_at_rtc_clock (
    input  logic clk,
    input  logic reset,
    output logic tick_32768,
    output logic second_tick
);
    logic [18:0] phase_q;
    logic [25:0] second_count_q;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            phase_q <= 19'd0;
            second_count_q <= 26'd0;
            tick_32768 <= 1'b0;
            second_tick <= 1'b0;
        end else begin
            if (phase_q >= 19'd390369) begin
                phase_q <= phase_q - 19'd390369;
                tick_32768 <= 1'b1;
            end else begin
                phase_q <= phase_q + 19'd256;
                tick_32768 <= 1'b0;
            end

            second_tick <= (second_count_q == 26'd49_999_999);
            if (second_count_q == 26'd49_999_999)
                second_count_q <= 26'd0;
            else
                second_count_q <= second_count_q + 1'b1;
        end
    end
endmodule
