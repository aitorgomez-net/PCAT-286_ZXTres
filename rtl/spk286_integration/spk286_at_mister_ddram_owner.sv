`timescale 1ns/1ps

// Physical DDR3 owner for the normalized AT memory backend.
//
// Drop-in alternative to spk286_at_mister_sdram_owner: the request side is
// the same serialized 16-bit transaction, so the memory port, read buffers
// and posted-write buffer above it are unchanged. The memory behind it is
// the DE10-Nano HPS DDR3, reached through the core's 64-bit DDRAM port,
// which runs in its own clock domain and is shared with the framebuffer
// clients in ega_ddr_arbiter.
//
// The HPS DDR3 answers far later than the SDRAM module, so the owner keeps a
// cache of the AT RAM in block RAM of the AT clock domain:
//
//  - direct mapped, 32-byte lines, 2^LINE_BITS lines (32 KiB by default);
//  - a read hit is answered from block RAM without leaving the AT domain;
//  - a read miss fetches the whole line with one four-beat DDRAM burst and
//    allocates it;
//  - writes go through to DDR3 and update a cached line in place; a write
//    miss does not allocate. A write completes for the AT side once it is
//    queued, so a store no longer waits for the DDRAM round trip.
//
// Requests cross to the DDRAM domain through one in-order queue, so a fill
// can never overtake an older write, and line data returns through a second
// queue. The DDRAM side removes a request only when it has completed, so an
// empty queue means DDR3 holds every accepted write. This owner is the only
// path to its DDR3 window (CPU, DMA and the HPS loader all come through the
// memory port above), which keeps the cache coherent without snooping.
//
// AT refresh needs no physical work on DDR3 and is acknowledged locally.
// A machine reset never abandons a physical access: queued writes still
// land, and a fill that is cut short leaves its line invalid; its late beats
// are discarded before another fill may start.

module spk286_at_mister_ddram_owner #(
    // 64-bit word address of AT byte address 0 within the DDRAM window.
    // 29'h6200000 is byte 0x31000000, above the framebuffer at 0x30000000.
    parameter logic [28:0] DDRAM_BASE = 29'h6200000,
    // log2 of the number of 32-byte cache lines: 10 is 32 KiB.
    parameter integer LINE_BITS = 10,
    // log2 of the number of requests queued towards the DDRAM domain.
    parameter integer QUEUE_BITS = 4
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        request_valid,
    input  logic        request_command_valid,
    input  logic        request_owner_refresh,
    input  logic        request_write,
    input  logic        request_code_fetch,
    input  logic        request_burst,
    input  logic [3:0]  request_cycle_class,
    input  logic [24:0] request_address,
    input  logic [1:0]  request_byte_enable,
    input  logic [15:0] request_data_out,
    output logic        request_accept,
    output logic        request_ready,
    output logic [15:0] request_read_data,
    output logic        request_read_data_valid,
    output logic        physical_idle,
    output logic [7:0]  debug_state,
    output logic        protocol_error,

    // DDRAM-domain client of ega_ddr_arbiter.
    input  logic        ddr_clk,
    output logic        ddr_req,
    output logic        ddr_write,
    output logic [28:0] ddr_addr,
    output logic [7:0]  ddr_be,
    output logic [63:0] ddr_din,
    output logic [7:0]  ddr_burstcnt,
    input  logic        ddr_rvalid,
    input  logic [63:0] ddr_rdata,
    input  logic        ddr_done
);

    localparam integer LINES     = 1 << LINE_BITS;
    localparam integer TAG_LOW   = 5 + LINE_BITS;
    localparam integer TAG_BITS  = 25 - TAG_LOW;
    // Queued request: {fill, 64-bit word address, byte lanes, data}.
    localparam integer REQUEST_BITS = 1 + 22 + 8 + 16;
    localparam integer LINE_BEATS = 4;

    localparam logic [2:0] S_IDLE   = 3'd0;
    localparam logic [2:0] S_LOOKUP = 3'd1;
    localparam logic [2:0] S_CHECK  = 3'd2;
    localparam logic [2:0] S_FILL   = 3'd3;
    localparam logic [2:0] S_STREAM = 3'd4;
    localparam logic [2:0] S_DONE   = 3'd5;

    // ------------------------------------------------------------------
    // AT clock domain
    // ------------------------------------------------------------------
    logic [2:0]  state_q;
    logic        write_q;
    logic        burst_q;
    logic [24:0] address_q;
    logic [1:0]  byte_enable_q;
    logic [15:0] data_out_q;
    logic [63:0] line_q;
    logic [1:0]  beat_q;
    logic [15:0] response_data_q;
    logic        response_data_valid_q;
    logic        response_ready_q;

    wire [LINE_BITS-1:0] index    = address_q[TAG_LOW-1:5];
    wire [TAG_BITS-1:0]  tag      = address_q[24:TAG_LOW];
    wire [1:0]           req_beat = address_q[4:3];
    wire [7:0]           lanes8   = 8'(byte_enable_q) << {address_q[2:1], 1'b0};

    // Block RAM: tags {valid, tag} and line data as eight byte lanes. Both
    // read the current request's set continuously; the result is used two
    // clocks after acceptance. Tags start invalid at configuration.
    (* ramstyle = "M10K, no_rw_check" *) logic [TAG_BITS:0] tag_ram [0:LINES-1];
    logic [TAG_BITS:0] tag_q;
    logic              tag_we;
    logic [TAG_BITS:0] tag_wdata;
    initial for (integer i = 0; i < LINES; i = i + 1) tag_ram[i] = '0;
    always_ff @(posedge clk) begin
        if (tag_we)
            tag_ram[index] <= tag_wdata;
        tag_q <= tag_ram[index];
    end

    wire  [63:0]          data_q;
    logic [7:0]           data_we;
    logic [LINE_BITS+1:0] data_waddr;
    logic [63:0]          data_wdata;
    genvar byte_lane;
    generate
        for (byte_lane = 0; byte_lane < 8; byte_lane = byte_lane + 1) begin : g_data_lane
            (* ramstyle = "M10K, no_rw_check" *) logic [7:0] data_ram [0:LINES*LINE_BEATS-1];
            logic [7:0] q;
            always_ff @(posedge clk) begin
                if (data_we[byte_lane])
                    data_ram[data_waddr] <= data_wdata[8*byte_lane +: 8];
                q <= data_ram[address_q[TAG_LOW-1:3]];
            end
            assign data_q[8*byte_lane +: 8] = q;
        end
    endgenerate

    wire hit = tag_q[TAG_BITS] && (tag_q[TAG_BITS-1:0] == tag);

    // Request queue (write side) and line-data queue (read side).
    logic                    queue_push;
    logic [REQUEST_BITS-1:0] queue_data;
    wire                     queue_full;
    wire                     queue_empty;
    wire                     beat_empty;
    wire [64:0]              beat_data;    // {failed, data}
    // Line beats are taken as they arrive, whether or not anyone waits.
    wire                     beat_take = !beat_empty;
    wire                     beat_failed = beat_data[64];

    // Set when a fill is queued, cleared by its last beat. Not reset: after
    // a machine reset the beats of an abandoned fill must still be drained
    // before another fill may start.
    logic       fill_outstanding_q = 1'b0;
    logic [1:0] fill_beat_q = 2'd0;
    wire fill_push = queue_push && queue_data[REQUEST_BITS-1];
    wire fill_last = beat_take && (beat_failed || fill_beat_q == 2'd3);
    always_ff @(posedge clk) begin
        if (fill_push)
            fill_outstanding_q <= 1'b1;
        else if (fill_last)
            fill_outstanding_q <= 1'b0;
        if (fill_last)
            fill_beat_q <= 2'd0;
        else if (beat_take)
            fill_beat_q <= fill_beat_q + 2'd1;
    end

    assign request_accept = (state_q == S_IDLE) && request_valid &&
                            request_command_valid && (request_byte_enable != 2'b00);
    assign request_ready = response_ready_q;
    assign request_read_data = response_data_q;
    assign request_read_data_valid = response_data_valid_q;
    assign physical_idle = (state_q == S_IDLE) && queue_empty && !fill_outstanding_q;
    assign debug_state = {state_q, fill_outstanding_q, queue_full, queue_empty,
                          write_q, burst_q};

    function automatic logic [15:0] lane(input logic [63:0] word, input logic [1:0] index);
        lane = word[16*index +: 16];
    endfunction

    // The requested 64-bit word of a line being filled: earlier beats were
    // kept in line_q; a failed fill reads as all ones.
    wire [63:0] fill_word = beat_failed ? {64{1'b1}} :
                            (fill_beat_q == req_beat) ? beat_data[63:0] : line_q;

    always_comb begin
        queue_push = 1'b0;
        queue_data = {1'b0, address_q[24:3], lanes8, data_out_q};
        tag_we     = 1'b0;
        tag_wdata  = {1'b1, tag};
        data_we    = 8'h00;
        data_waddr = address_q[TAG_LOW-1:3];
        data_wdata = {4{data_out_q}};
        if (state_q == S_CHECK && !queue_full) begin
            if (write_q) begin
                // Write through; update the cached copy only.
                queue_push = 1'b1;
                if (hit)
                    data_we = lanes8;
            end else if (!hit && !fill_outstanding_q) begin
                // The line stays invalid until its last beat has arrived.
                queue_push = 1'b1;
                queue_data = {1'b1, address_q[24:5], 2'b00, 8'hFF, 16'h0000};
                tag_we     = 1'b1;
                tag_wdata  = '0;
            end
        end
        if (state_q == S_FILL && beat_take) begin
            data_we    = beat_failed ? 8'h00 : 8'hFF;
            data_waddr = {index, fill_beat_q};
            data_wdata = beat_data[63:0];
            if (fill_last) begin
                tag_we    = !beat_failed;
                tag_wdata = {1'b1, tag};
            end
        end
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state_q               <= S_IDLE;
            write_q               <= 1'b0;
            burst_q               <= 1'b0;
            address_q             <= 25'd0;
            byte_enable_q         <= 2'b00;
            data_out_q            <= 16'h0000;
            line_q                <= 64'd0;
            beat_q                <= 2'd0;
            response_data_q       <= 16'h0000;
            response_data_valid_q <= 1'b0;
            response_ready_q      <= 1'b0;
            protocol_error        <= 1'b0;
        end else begin
            response_data_valid_q <= 1'b0;
            response_ready_q      <= 1'b0;
            if (request_valid && request_command_valid &&
                (request_byte_enable == 2'b00))
                protocol_error <= 1'b1;
            if (request_accept && (request_burst === 1'b1) &&
                (request_write || (request_address[2:1] != 2'b00)))
                protocol_error <= 1'b1;

            case (state_q)
                S_IDLE: if (request_accept) begin
                    write_q       <= request_write;
                    burst_q       <= (request_burst === 1'b1);
                    address_q     <= request_address;
                    byte_enable_q <= request_byte_enable;
                    data_out_q    <= request_data_out;
                    if (request_owner_refresh) begin
                        // No physical work: complete on the next edge.
                        response_ready_q <= 1'b1;
                        state_q          <= S_DONE;
                    end else begin
                        state_q <= S_LOOKUP;
                    end
                end

                // Tag and data RAM read the new request's set.
                S_LOOKUP: state_q <= S_CHECK;

                S_CHECK: if (write_q) begin
                    if (!queue_full) begin
                        response_ready_q <= 1'b1;
                        state_q          <= S_DONE;
                    end
                end else if (hit) begin
                    line_q                <= data_q;
                    response_data_q       <= burst_q ? lane(data_q, 2'd0)
                                                     : lane(data_q, address_q[2:1]);
                    response_data_valid_q <= 1'b1;
                    beat_q                <= 2'd1;
                    response_ready_q      <= !burst_q;
                    state_q               <= burst_q ? S_STREAM : S_DONE;
                end else if (!fill_outstanding_q && !queue_full) begin
                    state_q <= S_FILL;
                end

                S_FILL: if (beat_take) begin
                    if (fill_beat_q == req_beat)
                        line_q <= beat_data[63:0];
                    if (fill_last) begin
                        line_q                <= fill_word;
                        response_data_q       <= burst_q ? lane(fill_word, 2'd0)
                                                         : lane(fill_word, address_q[2:1]);
                        response_data_valid_q <= 1'b1;
                        beat_q                <= 2'd1;
                        response_ready_q      <= !burst_q;
                        state_q               <= burst_q ? S_STREAM : S_DONE;
                    end
                end

                // Beats 1..3 of a P03 line (one aligned 64-bit word); ready
                // accompanies the last.
                S_STREAM: begin
                    response_data_q       <= lane(line_q, beat_q);
                    response_data_valid_q <= 1'b1;
                    beat_q                <= beat_q + 2'd1;
                    if (beat_q == 2'd3) begin
                        response_ready_q <= 1'b1;
                        state_q          <= S_DONE;
                    end
                end

                // READY is visible for exactly this cycle.
                S_DONE: state_q <= S_IDLE;

                default: state_q <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Clock-domain crossing
    // ------------------------------------------------------------------
    wire                    head_empty;
    wire [REQUEST_BITS-1:0] head;
    logic                   head_done;

    at_cdc_fifo #(.WIDTH(REQUEST_BITS), .ADDR_BITS(QUEUE_BITS)) request_fifo (
        .wr_clk(clk), .wr_en(queue_push), .wr_data(queue_data),
        .wr_full(queue_full), .wr_empty(queue_empty),
        .rd_clk(ddr_clk), .rd_en(head_done), .rd_data(head), .rd_empty(head_empty)
    );

    logic        beat_push;
    logic [64:0] beat_push_data;
    wire         beat_full;
    at_cdc_fifo #(.WIDTH(65), .ADDR_BITS(3)) response_fifo (
        .wr_clk(ddr_clk), .wr_en(beat_push), .wr_data(beat_push_data),
        .wr_full(beat_full), .wr_empty(),
        .rd_clk(clk), .rd_en(beat_take), .rd_data(beat_data), .rd_empty(beat_empty)
    );

    // ------------------------------------------------------------------
    // DDRAM clock domain
    // ------------------------------------------------------------------
    // The head request is served in place and removed only when the arbiter
    // reports it done, so it stays stable for the whole access.
    logic       ddr_busy_q = 1'b0;
    logic [2:0] ddr_beats_q = 3'd0;
    wire        head_fill = head[REQUEST_BITS-1];

    assign ddr_req      = ddr_busy_q;
    assign ddr_write    = !head_fill;
    assign ddr_addr     = DDRAM_BASE + {7'd0, head[REQUEST_BITS-2 -: 22]};
    assign ddr_be       = head[23:16];
    assign ddr_din      = {4{head[15:0]}};
    assign ddr_burstcnt = head_fill ? 8'(LINE_BEATS) : 8'd1;
    assign head_done    = ddr_busy_q && ddr_done;

    // Every beat of a fill is forwarded. A burst that the arbiter abandons
    // (its read watchdog) is closed with one failed marker instead.
    always_comb begin
        beat_push      = 1'b0;
        beat_push_data = {1'b0, ddr_rdata};
        if (ddr_busy_q && head_fill) begin
            if (ddr_rvalid)
                beat_push = 1'b1;
            else if (ddr_done && ddr_beats_q != 3'(LINE_BEATS)) begin
                beat_push      = 1'b1;
                beat_push_data = {1'b1, {64{1'b1}}};
            end
        end
    end

    always_ff @(posedge ddr_clk) begin
        if (!ddr_busy_q) begin
            ddr_beats_q <= 3'd0;
            if (!head_empty)
                ddr_busy_q <= 1'b1;
        end else begin
            if (ddr_rvalid)
                ddr_beats_q <= ddr_beats_q + 3'd1;
            if (ddr_done)
                ddr_busy_q <= 1'b0;
        end
    end

`ifndef SYNTHESIS
    integer debug_hits = 0, debug_misses = 0, debug_writes = 0, debug_write_hits = 0;
    integer debug_queue_stalls = 0, debug_discarded_beats = 0;
    always_ff @(posedge clk) begin
        if (beat_take && (reset || state_q != S_FILL))
            debug_discarded_beats <= debug_discarded_beats + 1;
        if (!reset && state_q == S_CHECK && queue_full)
            debug_queue_stalls <= debug_queue_stalls + 1;
        if (!reset && state_q == S_CHECK) begin
            if (write_q && !queue_full) begin
                debug_writes <= debug_writes + 1;
                if (hit) debug_write_hits <= debug_write_hits + 1;
            end else if (!write_q && hit) begin
                debug_hits <= debug_hits + 1;
            end else if (!write_q && queue_push) begin
                debug_misses <= debug_misses + 1;
            end
        end
    end
    always_ff @(posedge clk) begin
        if (!reset) begin
            assert (!(beat_take && !fill_outstanding_q))
                else $error("AT DDRAM owner received a line beat without a fill");
            assert (!(response_data_valid_q && write_q))
                else $error("AT DDRAM owner returned read data for a write");
            assert (burst_q || !response_data_valid_q || response_ready_q)
                else $error("AT DDRAM owner returned single-read data without ready");
        end
    end
    always_ff @(posedge ddr_clk) begin
        assert (!(beat_push && beat_full))
            else $error("AT DDRAM owner line-data queue overflow");
        assert (!(ddr_busy_q && !head_fill && ddr_rvalid))
            else $error("AT DDRAM owner received read data for a write");
    end
`endif

endmodule
