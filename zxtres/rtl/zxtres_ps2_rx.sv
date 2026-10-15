// PS/2 device-to-host receiver: one byte per 11-bit frame (start, eight data
// bits LSB first, odd parity, stop), sampled on the falling edges of the
// PS/2 clock after a glitch filter. A frame with a bad start, parity or stop
// bit is dropped and flagged. A frame left incomplete for about 1 ms (no
// clock edge) is abandoned, so a lost bit cannot shift every later byte.
`timescale 1ns/1ps
module zxtres_ps2_rx #(
    parameter int unsigned CLK_KHZ = 50000
) (
    input  logic       clk,
    input  logic       reset,
    input  logic       ps2_clk,
    input  logic       ps2_data,
    output logic [7:0] data,
    output logic       strobe,     // one clock, data valid
    output logic       error       // one clock, frame dropped
);
    localparam int unsigned TIMEOUT = CLK_KHZ;   // about 1 ms

    (* ASYNC_REG = "TRUE" *) logic [1:0] clk_sync = 2'b11, data_sync = 2'b11;
    logic [3:0] clk_history = 4'hF;
    logic       clk_filtered = 1'b1;
    always_ff @(posedge clk) begin
        clk_sync  <= {clk_sync[0], ps2_clk};
        data_sync <= {data_sync[0], ps2_data};
        clk_history <= {clk_history[2:0], clk_sync[1]};
        if (&clk_history)       clk_filtered <= 1'b1;
        else if (~|clk_history) clk_filtered <= 1'b0;
    end

    logic        clk_filtered_q = 1'b1;
    wire         falling = clk_filtered_q && !clk_filtered;
    logic [3:0]  bit_count;
    logic [9:0]  shift;
    logic [$clog2(TIMEOUT + 1)-1:0] idle;

    always_ff @(posedge clk) begin
        clk_filtered_q <= clk_filtered;
        strobe <= 1'b0;
        error  <= 1'b0;
        if (reset) begin
            bit_count <= '0;
            idle <= '0;
        end else if (falling) begin
            idle <= '0;
            if (bit_count == 4'd10) begin
                bit_count <= '0;
                // shift = {parity, data[7:0], start}, the stop bit is on the line now.
                if (!shift[0] && data_sync[1] && (^shift[9:1])) begin
                    data <= shift[8:1];
                    strobe <= 1'b1;
                end else begin
                    error <= 1'b1;
                end
            end else begin
                shift <= {data_sync[1], shift[9:1]};
                bit_count <= bit_count + 4'd1;
            end
        end else if (bit_count != '0) begin
            if (idle == TIMEOUT[$bits(idle)-1:0]) begin
                bit_count <= '0;
                idle <= '0;
            end else begin
                idle <= idle + 1'b1;
            end
        end
    end
endmodule
