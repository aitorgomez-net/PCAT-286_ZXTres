// Shares the user_io block-device request lines between the IDE store
// (units 0 and 1), the CMOS store (unit 2) and the floppy store (units 3
// and 4). user_io latches one LBA and one unit per transfer, so two stores
// must not request at the same time:
// the first requester owns the lines until its request has dropped and its
// transfer window (sd_ack_x) has closed. A requester keeps asking until it is
// acknowledged, so a masked request just waits.
`timescale 1ns/1ps
module zxtres_sd_arb (
    input  logic        clk,
    input  logic        reset,

    // client A: the IDE store, units 0 and 1
    input  logic [1:0]  a_rd,
    input  logic [1:0]  a_wr,
    input  logic [31:0] a_lba,
    input  logic [7:0]  a_din,

    // client B: the CMOS store, unit 2
    input  logic        b_rd,
    input  logic        b_wr,
    input  logic [7:0]  b_din,

    // client C: the floppy store, units 3 and 4
    input  logic [1:0]  c_rd,
    input  logic [1:0]  c_wr,
    input  logic [31:0] c_lba,
    input  logic [7:0]  c_din,

    input  logic [4:0]  sd_ack_x,

    output logic [4:0]  sd_rd,
    output logic [4:0]  sd_wr,
    output logic [31:0] sd_lba,
    output logic [7:0]  sd_din
);
    wire a_req = |{a_rd, a_wr};
    wire b_req = b_rd | b_wr;
    wire c_req = |{c_rd, c_wr};

    typedef enum logic [1:0] {O_NONE, O_A, O_B, O_C} owner_t;
    owner_t owner_q = O_NONE;

    always_ff @(posedge clk) begin
        if (reset) begin
            owner_q <= O_NONE;
        end else begin
            case (owner_q)
                O_NONE: if (a_req)      owner_q <= O_A;
                        else if (b_req) owner_q <= O_B;
                        else if (c_req) owner_q <= O_C;
                O_A: if (!a_req && !(|sd_ack_x[1:0])) owner_q <= O_NONE;
                O_B: if (!b_req && !sd_ack_x[2])      owner_q <= O_NONE;
                O_C: if (!c_req && !(|sd_ack_x[4:3])) owner_q <= O_NONE;
                default: owner_q <= O_NONE;
            endcase
        end
    end

    always_comb begin
        sd_rd  = 5'b00000;
        sd_wr  = 5'b00000;
        sd_lba = 32'd0;
        sd_din = 8'h00;
        case (owner_q)
            O_A: begin
                sd_rd  = {3'b000, a_rd};
                sd_wr  = {3'b000, a_wr};
                sd_lba = a_lba;
                sd_din = a_din;
            end
            O_B: begin
                sd_rd  = {2'b00, b_rd, 2'b00};
                sd_wr  = {2'b00, b_wr, 2'b00};
                sd_din = b_din;
            end
            O_C: begin
                sd_rd  = {c_rd, 3'b000};
                sd_wr  = {c_wr, 3'b000};
                sd_lba = c_lba;
                sd_din = c_din;
            end
            default: ;
        endcase
    end
endmodule
