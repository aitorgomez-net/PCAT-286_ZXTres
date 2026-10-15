// Portable true dual-port RAM with the port list of the Quartus dpram in
// rtl/common/bram.vhd, as used by rtl/common/ide.v (positional parameters
// address width, data width). One process per port, so Vivado infers block
// RAM. Read-first on each port.
`timescale 1ns/1ps
module dpram #(
    parameter integer ADDR_WIDTH = 8,
    parameter integer DATA_WIDTH = 8
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
        if (wren_a) mem[address_a] <= data_a;
        q_a <= mem[address_a];
    end
    always_ff @(posedge clock) begin
        if (wren_b) mem[address_b] <= data_b;
        q_b <= mem[address_b];
    end
endmodule
