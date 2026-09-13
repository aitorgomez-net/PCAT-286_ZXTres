// Small simulation model for the Quartus-only dpram VHDL primitive used by
// common/ide.v.  This is deliberately kept in sim/ so it cannot shadow the
// synthesis implementation.
module dpram #(
    parameter integer ADDR_WIDTH = 12,
    parameter integer DATA_WIDTH = 16
) (
    input  logic                  clock,
    input  logic [ADDR_WIDTH-1:0] address_a,
    input  logic [DATA_WIDTH-1:0] data_a,
    input  logic                  wren_a,
    output logic [DATA_WIDTH-1:0] q_a,
    input  logic [ADDR_WIDTH-1:0] address_b,
    input  logic [DATA_WIDTH-1:0] data_b,
    input  logic                  wren_b,
    output logic [DATA_WIDTH-1:0] q_b
);
    logic [DATA_WIDTH-1:0] mem [0:(1 << ADDR_WIDTH)-1];

    always_ff @(posedge clock) begin
        if (wren_a)
            mem[address_a] <= data_a;
        q_a <= mem[address_a];

        if (wren_b)
            mem[address_b] <= data_b;
        q_b <= mem[address_b];
    end
endmodule
