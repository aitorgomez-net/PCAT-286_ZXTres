// Controller for the ZXTRES+ 2 MiB asynchronous SRAM (1M x 16 bit, 10 ns,
// chip enable tied low on the board).
//
// Two clients, a write port that wins over a read port. Every access is
// launched from a flip-flop on clk (57.27 MHz) and the pins change only on
// that clock, so a pin never moves less than a clock period (17.5 ns) after
// another:
//
//   read   launch (address, OE low), wait, sample at the second edge: 2 clocks
//          (34.9 ns after the address, the part needs 10 ns plus the pads)
//   write  launch (address, OE high), data driven and WE low for one clock,
//          WE high for one clock with address and data held: 3 clocks
//
// A client holds its request until the grant pulse (one clock, the clock
// after the launch) and may change address and data then. Read data comes
// back in order, rd_valid with rd_data, two clocks after the grant pulse.
//
// Active-low pin names follow the board: SRAM_WE, SRAM_OE, SRAM_UB, SRAM_LB.
module zxtres_sram_ctrl (
	input         clk,
	input         reset,

	input         wr_req,
	input  [19:0] wr_addr,
	input  [15:0] wr_data,
	output reg    wr_grant,

	input         rd_req,
	input  [19:0] rd_addr,
	output reg    rd_grant,
	output reg    rd_valid,
	output [15:0] rd_data,

	output reg [19:0] SRAM_A,
	inout      [15:0] SRAM_Q,
	output reg        SRAM_WE,
	output reg        SRAM_OE,
	output            SRAM_UB,
	output            SRAM_LB
);

localparam [2:0] IDLE = 3'd0, R1 = 3'd1, R2 = 3'd2, W1 = 3'd3, W2 = 3'd4, W3 = 3'd5;

reg [2:0]  st;
reg [15:0] dq_o;
reg        dq_oe;
(* IOB = "TRUE" *) reg [15:0] q_in;

assign SRAM_UB = 1'b0;
assign SRAM_LB = 1'b0;
assign SRAM_Q  = dq_oe ? dq_o : 16'hzzzz;
assign rd_data = q_in;

// The next access may start in IDLE, in R2 (whose edge also samples the
// data of the access before) and in W3 (the clock after WE went high).
wire launch_ok = st == IDLE || st == R2 || st == W3;

always @(posedge clk) begin
	q_in     <= SRAM_Q;
	wr_grant <= 1'b0;
	rd_grant <= 1'b0;
	rd_valid <= st == R2;

	if (reset) begin
		st      <= IDLE;
		SRAM_A  <= 20'd0;
		SRAM_WE <= 1'b1;
		SRAM_OE <= 1'b1;
		dq_oe   <= 1'b0;
		rd_valid <= 1'b0;
	end else begin
		case (st)
			R1: st <= R2;
			W1: begin
				dq_oe   <= 1'b1;
				SRAM_WE <= 1'b0;
				st      <= W2;
			end
			W2: begin
				SRAM_WE <= 1'b1;
				st      <= W3;
			end
			default: ;
		endcase

		if (launch_ok) begin
			if (wr_req) begin
				SRAM_A   <= wr_addr;
				dq_o     <= wr_data;
				SRAM_OE  <= 1'b1;
				SRAM_WE  <= 1'b1;
				dq_oe    <= 1'b0;
				wr_grant <= 1'b1;
				st       <= W1;
			end else if (rd_req) begin
				SRAM_A   <= rd_addr;
				SRAM_OE  <= 1'b0;
				SRAM_WE  <= 1'b1;
				dq_oe    <= 1'b0;
				rd_grant <= 1'b1;
				st       <= R1;
			end else begin
				SRAM_OE  <= 1'b1;
				dq_oe    <= 1'b0;
				st       <= IDLE;
			end
		end
	end
end

endmodule
