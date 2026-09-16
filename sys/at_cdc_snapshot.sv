// Coherent, acknowledged latest-value transfer. Not a FIFO for commands.
// Both domains share FPGA configuration initialization, NOT independent resets.
// Stopping either clock is safe: the in-flight payload stays frozen until ack.
module at_cdc_snapshot #(parameter WIDTH = 1) (
    input wire src_clk,
    input wire src_send,
    input wire [WIDTH-1:0] src_data,
    output wire src_ready,
    input wire dst_clk,
    output reg [WIDTH-1:0] dst_data = 0,
    output reg dst_update = 0
);
    (* preserve *) reg [WIDTH-1:0] payload_q = 0;
    (* preserve *) reg req_q = 0;
    (* preserve *) reg ack_q = 0;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON", preserve *)
    reg ack_meta = 0, ack_sync = 0;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON", preserve *)
    reg req_meta = 0, req_sync = 0;

    assign src_ready = (req_q == ack_sync);
    always @(posedge src_clk) begin
        ack_meta <= ack_q;
        ack_sync <= ack_meta;
        if (src_send && src_ready) begin
            payload_q <= src_data;
            req_q <= ~req_q;
        end
    end
    always @(posedge dst_clk) begin
        req_meta <= req_q;
        req_sync <= req_meta;
        dst_update <= 0;
        if (req_sync != ack_q) begin
            // Earliest capture is the third destination edge after launch.
            // SDC bounds ONLY payload_q -> dst_data (not downstream logic).
            dst_data <= payload_q;
            dst_update <= 1;
            ack_q <= req_sync;
        end
    end
endmodule
