// In-order dual-clock FIFO for commands that must neither be dropped nor
// merged (at_cdc_snapshot keeps only the latest value). Gray-coded pointers
// cross through two-stage synchronizers; the storage is block RAM, so no
// timed path crosses between the clocks through it.
//
// The read side is first-word-fall-through: rd_data holds the oldest entry
// whenever rd_empty is low, and rd_en removes it. A consumer may keep the
// entry at the head while it works on it and remove it when done; the
// writer then cannot reuse that slot, and wr_empty (the write side's view
// that every entry has been removed) becomes "every entry has completed".
//
// Both domains share FPGA configuration initialization, NOT independent
// resets: the pointers start equal and are never cleared, so a reset on
// either side can neither drop nor replay an entry.
module at_cdc_fifo #(
    parameter WIDTH = 8,
    parameter ADDR_BITS = 4   // at least 2
) (
    input  wire             wr_clk,
    input  wire             wr_en,
    input  wire [WIDTH-1:0] wr_data,
    output wire             wr_full,
    output wire             wr_empty,
    input  wire             rd_clk,
    input  wire             rd_en,
    output reg  [WIDTH-1:0] rd_data = 0,
    output wire             rd_empty
);
    localparam DEPTH = 1 << ADDR_BITS;
    (* ramstyle = "M10K, no_rw_check" *) reg [WIDTH-1:0] mem [0:DEPTH-1];

    reg [ADDR_BITS:0] wr_bin = 0;
    reg [ADDR_BITS:0] rd_bin = 0;
    (* preserve *) reg [ADDR_BITS:0] wr_gray = 0;
    (* preserve *) reg [ADDR_BITS:0] rd_gray = 0;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON", preserve *)
    reg [ADDR_BITS:0] wr_gray_meta = 0, wr_gray_sync = 0;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON", preserve *)
    reg [ADDR_BITS:0] rd_gray_meta = 0, rd_gray_sync = 0;

    function [ADDR_BITS:0] to_gray(input [ADDR_BITS:0] value);
        to_gray = value ^ (value >> 1);
    endfunction

    // Full: the write pointer is one lap ahead of the synchronized read
    // pointer, which in Gray code differs in the two top bits only.
    assign wr_full  = wr_gray == {~rd_gray_sync[ADDR_BITS:ADDR_BITS-1],
                                  rd_gray_sync[ADDR_BITS-2:0]};
    assign wr_empty = wr_gray == rd_gray_sync;
    assign rd_empty = rd_gray == wr_gray_sync;

    wire wr_take = wr_en && !wr_full;
    wire [ADDR_BITS:0] wr_bin_next = wr_bin + {{ADDR_BITS{1'b0}}, wr_take};
    always @(posedge wr_clk) begin
        rd_gray_meta <= rd_gray;
        rd_gray_sync <= rd_gray_meta;
        if (wr_take)
            mem[wr_bin[ADDR_BITS-1:0]] <= wr_data;
        wr_bin  <= wr_bin_next;
        wr_gray <= to_gray(wr_bin_next);
    end

    // An entry becomes visible two read edges after its pointer moved, so
    // the block RAM write has completed at least one read period earlier.
    // Reading at the next pointer keeps the head valid on every cycle.
    wire rd_take = rd_en && !rd_empty;
    wire [ADDR_BITS:0] rd_bin_next = rd_bin + {{ADDR_BITS{1'b0}}, rd_take};
    always @(posedge rd_clk) begin
        wr_gray_meta <= wr_gray;
        wr_gray_sync <= wr_gray_meta;
        rd_bin  <= rd_bin_next;
        rd_gray <= to_gray(rd_bin_next);
        rd_data <= mem[rd_bin_next[ADDR_BITS-1:0]];
    end
endmodule
