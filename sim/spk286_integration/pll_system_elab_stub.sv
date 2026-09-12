// Simulation-only replacement for the Quartus-generated PLL hierarchy.
// The profile elaboration test checks connectivity, not generated-clock
// behaviour; keeping the outputs tied to the reference clock makes that test
// independent of vendor primitives.
`timescale 1ns/1ps

module pll_system (
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,
    output wire outclk_1,
    output wire outclk_2,
    output wire outclk_3,
    output wire locked
);
    assign outclk_0 = refclk;
    assign outclk_1 = refclk;
    assign outclk_2 = refclk;
    assign outclk_3 = refclk;
    assign locked = !rst;
endmodule
