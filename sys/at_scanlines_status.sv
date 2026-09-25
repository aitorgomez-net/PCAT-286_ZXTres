// Return the applied video scanline setting to the HPS register domain.
// Both bits travel together; FB enable is already local to clk_sys.
module at_scanlines_status (
    input wire clk_video,
    input wire clk_sys,
    input wire [1:0] scanlines,
    input wire fb_en,
    output reg [1:0] status = 0
);
    wire [1:0] scanlines_sys;
    at_cdc_snapshot #(.WIDTH(2)) config_mailbox (
        .src_clk(clk_video), .src_send(1'b1), .src_data(scanlines), .src_ready(),
        .dst_clk(clk_sys), .dst_data(scanlines_sys), .dst_update()
    );
    always @(posedge clk_sys) status <= fb_en ? 2'b00 : scanlines_sys;
endmodule
