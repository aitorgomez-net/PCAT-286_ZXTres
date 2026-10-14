`timescale 1ns/1ps

// Simulation model of the MiSTer DDRAM port (64-bit Avalon-MM, burst reads,
// byte-enabled writes) for the AT RAM window. Storage is kept as 16-bit AT
// words, mem[byte_address >> 1], the same layout as spk286_sdram_pin_model,
// so testbenches can inspect and preload RAM identically with either owner.
// Waitrequest and read latency are pseudo-random but deterministic.

module spk286_ddram_avalon_model #(
    parameter logic [28:0] BASE = 29'h6200000,
    parameter integer MEM_WORDS = 1 << 24
) (
    input  wire        clk,
    output wire        busy,
    input  wire [7:0]  burstcnt,
    input  wire [28:0] addr,
    input  wire [63:0] din,
    input  wire [7:0]  be,
    input  wire        we,
    input  wire        rd,
    output reg  [63:0] dout = 64'd0,
    output reg         dout_ready = 1'b0,
    output integer     read_count = 0,
    output integer     write_count = 0
);
    logic [15:0] mem [0:MEM_WORDS-1];

    reg [31:0] lfsr = 32'h1234_5678;
    reg busy_q = 1'b1;
    assign busy = busy_q;

    logic [28:0] rq_addr  [0:15];
    integer      rq_beats [0:15];
    integer      rq_delay [0:15];
    integer      rq_head = 0, rq_count = 0;
    integer      write_beat = 0;

    function automatic integer word_index(input logic [28:0] a, input integer lane);
        word_index = (a - BASE) * 4 + lane;
    endfunction

    always @(posedge clk) begin : model
        integer slot, lane, w;
        lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        busy_q <= (lfsr[2:0] == 3'd0);
        dout_ready <= 1'b0;
        if (rd && !busy) begin
            if (addr < BASE || word_index(addr, 3) >= MEM_WORDS)
                $fatal(1, "DDRAM model read outside the AT window: %h", addr);
            if (rq_count == 16) $fatal(1, "DDRAM model read queue overflow");
            slot = (rq_head + rq_count) % 16;
            rq_addr[slot]  = addr;
            rq_beats[slot] = burstcnt;
            rq_delay[slot] = 6 + lfsr[7:3];
            rq_count = rq_count + 1;
        end
        if (we && !busy) begin
            if (addr < BASE || word_index(addr + write_beat, 3) >= MEM_WORDS)
                $fatal(1, "DDRAM model write outside the AT window: %h", addr);
            for (lane = 0; lane < 4; lane = lane + 1) begin
                w = word_index(addr + write_beat, lane);
                if (be[2*lane])     mem[w][7:0]  = din[16*lane +: 8];
                if (be[2*lane + 1]) mem[w][15:8] = din[16*lane + 8 +: 8];
            end
            write_count = write_count + 1;
            write_beat = (write_beat + 1 == burstcnt) ? 0 : write_beat + 1;
        end
        if (rq_count != 0) begin
            if (rq_delay[rq_head] != 0)
                rq_delay[rq_head] = rq_delay[rq_head] - 1;
            else begin
                for (lane = 0; lane < 4; lane = lane + 1)
                    dout[16*lane +: 16] <= mem[word_index(rq_addr[rq_head], lane)];
                dout_ready <= 1'b1;
                read_count = read_count + 1;
                rq_addr[rq_head] = rq_addr[rq_head] + 1;
                rq_beats[rq_head] = rq_beats[rq_head] - 1;
                if (rq_beats[rq_head] == 0) begin
                    rq_head = (rq_head + 1) % 16;
                    rq_count = rq_count - 1;
                end
            end
        end
    end
endmodule
