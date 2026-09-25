// Notify the user when a reset-only OSD setting has changed.
//
// The OSD hides Info notices while its menu is open, so wait until it closes.
// `pending` and `osd_status` may be asynchronous to `clock`; both are
// synchronized here. One notice is raised per menu close while a setting is
// pending. `info` is constant so it is valid when hps_io samples the request.

module reset_pending_notice #(
    parameter logic [15:0] INFO_WIDTH = 16'd256,
    parameter logic [7:0]  INFO_INDEX = 8'd1
) (
    input  logic       clock,
    input  logic       pending,
    input  logic       osd_status,
    input  logic       suppress,
    output logic [7:0] info,
    output logic       info_req = 1'b0
);

    (* ASYNC_REG = "TRUE" *) logic [1:0] pending_sync = 2'b00;
    (* ASYNC_REG = "TRUE" *) logic [2:0] osd_sync = 3'b000;
    logic [15:0] info_count = 16'd0;

    wire osd_closed = osd_sync[2] & ~osd_sync[1];

    assign info = INFO_INDEX;

    always_ff @(posedge clock) begin
        pending_sync <= {pending_sync[0], pending};
        osd_sync <= {osd_sync[1:0], osd_status};

        if (suppress) begin
            info_count <= 16'd0;
            info_req <= 1'b0;
        end else if (osd_closed && pending_sync[1]) begin
            info_count <= INFO_WIDTH;
            info_req <= 1'b1;
        end else if (info_count != 16'd0) begin
            info_count <= info_count - 16'd1;
            info_req <= 1'b1;
        end else begin
            info_req <= 1'b0;
        end
    end

endmodule
