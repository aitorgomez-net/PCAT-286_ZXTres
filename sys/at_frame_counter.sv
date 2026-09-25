// Count normalized video VS edges in clk_sys. VS pulses must span at least
// two clk_sys cycles (real video VS pulses are many microseconds long).
// Register the source too: sync_fix forms VS from two video-domain signals.
module at_frame_counter (
    input wire clk_video,
    input wire clk_sys,
    input wire vs,
    output reg [7:0] frame_cnt = 0
);
    reg vs_video_q = 0;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON", preserve *)
    reg vs_meta = 0, vs_sync = 0;
    reg vs_seen = 0;

    always @(posedge clk_video) vs_video_q <= vs;
    always @(posedge clk_sys) begin
        vs_meta <= vs_video_q;
        vs_sync <= vs_meta;
        vs_seen <= vs_sync;
        if (vs_sync && !vs_seen) frame_cnt <= frame_cnt + 1'b1;
    end
endmodule
