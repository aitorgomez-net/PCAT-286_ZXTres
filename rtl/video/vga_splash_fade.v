//============================================================================
//
//  VGA boot splash fade
//
//  Brightness for the splash palette, 0 (black) to 64 (exact colours), moved
//  once per frame of the mode 13h raster. It rises while the splash shows and
//  falls while fade_out is requested (the last second of the splash, unless
//  F12 holds it). It starts from black every time the splash appears.
//
//  At about 70 or 60 frames per second, the default steps fade in over half
//  a second and out over roughly one.
//
//============================================================================

module vga_splash_fade #(
    parameter [6:0] IN_STEP  = 7'd2,
    parameter [6:0] OUT_STEP = 7'd1
) (
    input  wire       clock,
    input  wire       reset,
    input  wire       active,
    input  wire       fade_out,
    input  wire       frame_tick,
    output reg  [6:0] level
);

    localparam [6:0] FULL = 7'd64;

    always @(posedge clock or posedge reset) begin
        if (reset)
            level <= 7'd0;
        else if (!active)
            level <= 7'd0;
        else if (frame_tick) begin
            if (fade_out)
                level <= (level > OUT_STEP) ? level - OUT_STEP : 7'd0;
            else
                level <= (level < FULL - IN_STEP) ? level + IN_STEP : FULL;
        end
    end

endmodule
