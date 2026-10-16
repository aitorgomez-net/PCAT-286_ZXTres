//============================================================================
//
//  VGA boot splash palette
//
//  256 RGB666 entries for the splash picture held in the mode 13h framebuffer
//  (see SW/make_vga_splash_rom.py). The read is asynchronous, like the DAC it
//  stands in for during the splash, so the mode 13h renderer sees the colour
//  in the same cycle as the index. The emulated DAC is left untouched: the
//  machine starts with the palette state of a cold boot.
//
//============================================================================

module vga_splash_palette (
    input  wire [7:0] index,
    output wire [5:0] red,
    output wire [5:0] green,
    output wire [5:0] blue
);

    (* ramstyle = "MLAB" *) reg [17:0] palette [0:255];

    initial begin
        $readmemh("splash_vga_palette.hex", palette);
    end

    wire [17:0] entry = palette[index];

    assign red   = entry[17:12];
    assign green = entry[11:6];
    assign blue  = entry[5:0];

endmodule
