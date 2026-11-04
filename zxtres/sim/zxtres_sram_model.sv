// Behavioural model of the ZXTRES+ asynchronous SRAM (1M x 16, 10 ns) for
// simulation: reads follow the address after 10 ns, a write completes on
// the rising edge of WE. Reports an access that violates the 2-clock launch
// rule of zxtres_sram_ctrl by checking the address is stable while WE is low.
`timescale 1ns/1ps
module zxtres_sram_model (
	input  [19:0] SRAM_A,
	inout  [15:0] SRAM_Q,
	input         SRAM_WE,
	input         SRAM_OE,
	input         SRAM_UB,
	input         SRAM_LB
);
	reg [15:0] mem [0:1048575];
	integer errors = 0;
	reg [19:0] a_at_fall;

	always @(negedge SRAM_WE) a_at_fall = SRAM_A;
	always @(posedge SRAM_WE) begin
		if (a_at_fall !== SRAM_A) begin
			errors = errors + 1;
			$display("SRAM_MODEL address moved during write %h -> %h", a_at_fall, SRAM_A);
		end
		mem[SRAM_A] <= SRAM_Q;
	end

	wire [15:0] q = mem[SRAM_A];
	assign #10 SRAM_Q = (!SRAM_OE && SRAM_WE) ? q : 16'hzzzz;
endmodule
