// HDMI_TX_VS is registered in the selected transmitter clock domain. Its high/low
// intervals must span at least two clk_sys periods (video VS lasts us/ms).
// Keep receiving while HPS/PLL consumers are idle; only stage two is observed.
module at_hdmi_vsync (
    input wire clk_sys,
    input wire vs,
    output wire rise
);
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON", preserve *)
    reg vs_meta = 0, vs_sync = 0;
    reg vs_seen = 0;
    always @(posedge clk_sys) begin
        vs_meta <= vs;
        vs_sync <= vs_meta;
        vs_seen <= vs_sync;
    end
    assign rise = vs_sync & ~vs_seen;
endmodule
