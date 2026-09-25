// HPS display options cross as one held value, then apply in vertical blank.
// No independent mailbox resets: configuration init is shared by both clocks.
module at_video_options_cdc (
    input wire clk_sys,
    input wire src_idle,
    input wire [6:0] options,
    input wire clk_video,
    input wire video_reset,
    input wire vblank,
    output reg [1:0] scale = 0,
    output reg [2:0] display = 0,
    output reg [12:0] arx = 13'd4,
    output reg [12:0] ary = 13'd3
);
    reg [6:0] sent_q = 0;
    wire ready;
    wire [6:0] pending;
    wire send = src_idle && ready && (options != sent_q);
    always @(posedge clk_sys) begin
        if (send) sent_q <= options;
    end
    // HPS status is written in 16-bit words. Display straddles words 0/1;
    // wait for the transaction to end before sampling the combined fields.
    at_cdc_snapshot #(.WIDTH(7)) config_mailbox (
        .src_clk(clk_sys), .src_send(send), .src_data(options), .src_ready(ready),
        .dst_clk(clk_video), .dst_data(pending), .dst_update()
    );
    reg vblank_q = 1;
    always @(posedge clk_video) begin
        vblank_q <= vblank;
        if (video_reset || (vblank && !vblank_q)) begin
            display <= pending[6:4];
            scale <= pending[3:2];
            arx <= (pending[1:0] == 2'd0) ? 13'd4 :
                   ({11'd0, pending[1:0]} - 13'd1);
            ary <= (pending[1:0] == 2'd0) ? 13'd3 : 13'd0;
        end
    end
endmodule
