// Completed UIO configuration, not independently synchronized parameter bits.
// Both sides retain their FPGA configuration state through local resets.
module at_video_output_config (
    input wire clk_sys, clk_video, src_idle, video_vs,
    input wire [39:0] phase_inc,
    input wire [16:0] burst_range,
    input wire pal, cvbs, yc, subcarrier_enable, csync,
    output wire [39:0] phase_video,
    output wire [16:0] burst_video,
    output wire pal_video, cvbs_video, yc_video, subcarrier_video, csync_video
);
    wire [61:0] pending;
    wire update;
    reg idle_q = 0;
    always @(posedge clk_sys) idle_q <= src_idle;
    at_cdc_snapshot #(.WIDTH(62)) config_mailbox (
        .src_clk(clk_sys), .src_send(src_idle && idle_q),
        .src_data({phase_inc,burst_range,pal,cvbs,yc,subcarrier_enable,csync}),
        .src_ready(), .dst_clk(clk_video), .dst_data(pending), .dst_update(update)
    );
    reg [61:0] active_q = 0;
    reg received_q = 0, vs_q = 0;
    always @(posedge clk_video) begin
        vs_q <= video_vs;
        if (update) received_q <= 1;
        // Bootstrap without a raster; subsequent complete packets apply at VS.
        if ((update && !received_q) || (vs_q && !video_vs)) active_q <= pending;
    end
    assign {phase_video,burst_video,pal_video,cvbs_video,yc_video,
            subcarrier_video,csync_video} = active_q;
endmodule
