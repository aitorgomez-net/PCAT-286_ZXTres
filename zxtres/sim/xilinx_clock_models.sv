// Behavioural stand-ins for the Xilinx clock primitives the ZXTRES
// designs use, for fast simulation (the unisim MMCM model is very slow in
// xsim). Only the parameters and outputs the designs use are modelled:
// CLKOUT0 and CLKOUT1 at CLKIN1 * CLKFBOUT_MULT_F / DIVIDE, LOCKED after
// 1 us. Phase relationships between outputs are not modelled.
`timescale 1ns/1ps
module MMCME2_BASE #(
    parameter real CLKIN1_PERIOD = 10.0,
    parameter int  DIVCLK_DIVIDE = 1,
    parameter real CLKFBOUT_MULT_F = 5.0,
    parameter real CLKOUT0_DIVIDE_F = 1.0,
    parameter int  CLKOUT1_DIVIDE = 1
) (
    input  wire CLKIN1, CLKFBIN, PWRDWN, RST,
    output wire CLKFBOUT, CLKFBOUTB,
    output reg  CLKOUT0 = 1'b0,
    output wire CLKOUT0B,
    output reg  CLKOUT1 = 1'b0,
    output wire CLKOUT1B, CLKOUT2, CLKOUT2B, CLKOUT3, CLKOUT3B, CLKOUT4, CLKOUT5, CLKOUT6,
    output reg  LOCKED = 1'b0
);
    localparam real VCO_PERIOD = CLKIN1_PERIOD * DIVCLK_DIVIDE / CLKFBOUT_MULT_F;
    localparam real HALF0 = VCO_PERIOD * CLKOUT0_DIVIDE_F / 2.0;
    localparam real HALF1 = VCO_PERIOD * CLKOUT1_DIVIDE / 2.0;

    initial begin
        #1000 LOCKED = 1'b1;
    end
    always #(HALF0) CLKOUT0 = !CLKOUT0;
    always #(HALF1) CLKOUT1 = !CLKOUT1;

    assign CLKFBOUT = CLKIN1;
    assign {CLKFBOUTB, CLKOUT0B, CLKOUT1B, CLKOUT2, CLKOUT2B, CLKOUT3, CLKOUT3B,
            CLKOUT4, CLKOUT5, CLKOUT6} = '0;
endmodule

module BUFG (input wire I, output wire O);
    assign O = I;
endmodule

// ODDR as used for forwarded clocks: SAME_EDGE, D1 on the rising edge and
// D2 on the falling edge of C.
module ODDR #(
    parameter DDR_CLK_EDGE = "SAME_EDGE",
    parameter INIT = 1'b0,
    parameter SRTYPE = "SYNC"
) (
    output reg  Q = INIT,
    input  wire C, CE, D1, D2, R, S
);
    always @(posedge C) if (CE) Q <= D1;
    always @(negedge C) if (CE) Q <= D2;
endmodule
