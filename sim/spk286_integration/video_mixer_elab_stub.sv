// Structural AT-top test stub. The production build uses sys/video_mixer.sv.
// Icarus cannot elaborate that MiSTer module's hq2x/gamma implementation.
module video_mixer #(
    parameter LINE_LENGTH = 768,
    parameter HALF_DEPTH = 0,
    parameter GAMMA = 0
) (
    input CLK_VIDEO,
    output CE_PIXEL,
    input ce_pix,
    input scandoubler,
    input hq2x,
    inout [21:0] gamma_bus,
    input [(HALF_DEPTH ? 3 : 7):0] R,
    input [(HALF_DEPTH ? 3 : 7):0] G,
    input [(HALF_DEPTH ? 3 : 7):0] B,
    input HSync,
    input VSync,
    input HBlank,
    input VBlank,
    input HDMI_FREEZE,
    output freeze_sync,
    output [7:0] VGA_R,
    output [7:0] VGA_G,
    output [7:0] VGA_B,
    output VGA_VS,
    output VGA_HS,
    output VGA_DE
);
    assign CE_PIXEL = ce_pix;
    assign freeze_sync = 1'b0;
    assign VGA_R = R;
    assign VGA_G = G;
    assign VGA_B = B;
    assign VGA_VS = VSync;
    assign VGA_HS = HSync;
    assign VGA_DE = !(HBlank || VBlank);
endmodule
