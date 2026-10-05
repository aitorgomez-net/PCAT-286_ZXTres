// Preserve target bytes read only for historical length qualification. Preview
// is not an architectural queue consumption: IP/prefix state advance on replay.
`ifndef SPK286_TARGET_REPLAY_SV
`define SPK286_TARGET_REPLAY_SV
`timescale 1ns/1ps
module spk286_target_replay (
    input logic clk, reset, cancel, start,
    input logic capture,
    input logic [7:0] capture_data,
    input logic consume,
    output logic valid,
    output logic [7:0] data,
    output logic [3:0] count
);
    logic [7:0] bytes_q [0:9];
    // This small buffer has a registered head, not a RAM-addressed read port.
    // Decode/exception backpressure must not start at an asynchronous RAM read
    // and return through the same read pointer. No extra handshake edge is
    // added: slot zero is already the next byte before a consumer accepts it.
    logic [3:0] write_q, count_q;
    logic take_capture, take_consume;
    assign count = count_q;
    assign valid = count_q != 4'd0;
    assign data = valid ? bytes_q[0] : 8'd0;
    // Capacity is the total number captured in this epoch, not just current
    // occupancy. Consuming a byte never permits an eleventh target byte.
    assign take_capture = capture && write_q < 4'd10;
    assign take_consume = consume && valid;
    always_ff @(posedge clk) begin
        if (reset || cancel || start) begin
            write_q <= 4'd0;
            count_q <= 4'd0;
        end else begin
            if (take_consume) begin
                for (integer slot = 0; slot < 9; slot = slot + 1)
                    bytes_q[slot] <= bytes_q[slot + 1];
            end
            if (take_capture) begin
                // A simultaneous accepted pop shifts first; the newly
                // captured byte replaces the tail at its resulting position.
                bytes_q[take_consume ? count_q - 4'd1 : count_q] <= capture_data;
                write_q <= write_q + 4'd1;
            end
            case ({take_capture, take_consume})
                2'b10: count_q <= count_q + 4'd1;
                2'b01: count_q <= count_q - 4'd1;
                default: ;
            endcase
        end
    end
endmodule
`endif
