// Structural AT-top test stub for Icarus, which cannot elaborate the
// production converter's initialized colour-weight arrays.
module video_monochrome_converter (
    input clk_vid,
    input ce_pix,
    input [2:0] gfx_mode,
    input [7:0] R,
    input [7:0] G,
    input [7:0] B,
    input HSync,
    input VSync,
    input HBlank,
    input VBlank,
    output [7:0] R_OUT,
    output [7:0] G_OUT,
    output [7:0] B_OUT,
    output HSync_OUT,
    output VSync_OUT,
    output HBlank_OUT,
    output VBlank_OUT
);
    assign R_OUT = R;
    assign G_OUT = G;
    assign B_OUT = B;
    assign HSync_OUT = HSync;
    assign VSync_OUT = VSync;
    assign HBlank_OUT = HBlank;
    assign VBlank_OUT = VBlank;
endmodule
