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
// One transaction is in flight at a time. The request (write flag, 64-bit
// word address, byte enables, data) crosses to the DDRAM domain in one
// at_cdc_snapshot, and the 64-bit result returns in another. AT addresses are
// byte addresses; a word read selects its 16-bit lane from the returned
// 64-bit word, a four-word burst (P03 line fill, always an aligned 8-byte
// line) is served by a single 64-bit read and returned as four beats.
//
// AT refresh needs no physical work on DDR3 and is acknowledged locally.
// A machine reset never abandons a physical access: a request that has
// crossed to the DDRAM domain completes there, and its late response is
// discarded here before another request may start.

module spk286_at_mister_ddram_owner #(
    // 64-bit word address of AT byte address 0 within the DDRAM window.
    // 29'h6200000 is byte 0x31000000, above the framebuffer at 0x30000000.
    parameter logic [28:0] DDRAM_BASE = 29'h6200000
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
    input  logic        ddr_done,
    input  logic [63:0] ddr_rdata
);

    // ------------------------------------------------------------------
    // AT clock domain
    // ------------------------------------------------------------------
    logic        active_q;
    logic        sent_q;
    logic        owner_refresh_q;
    logic        write_q;
    logic        burst_q;
    logic [24:0] address_q;
    logic [1:0]  byte_enable_q;
    logic [15:0] data_out_q;
    logic        response_pending_q;
    logic [15:0] response_data_q;
    logic        response_data_valid_q;
    logic [63:0] line_q;
    logic [1:0]  beat_q;
    logic        streaming_q;

    // Set when a request crosses, cleared only by its response. Not reset:
    // a reset while a request is in flight must still wait for its response.
    logic        inflight_q = 1'b0;

    logic        req_src_ready;
    logic        req_send;
    logic        resp_update;
    logic [63:0] resp_data;

    assign physical_idle = !active_q && !inflight_q;
    assign request_accept = !active_q && !inflight_q && req_src_ready &&
                            request_valid && request_command_valid &&
                            (request_byte_enable != 2'b00);
    assign req_send = active_q && !sent_q && !owner_refresh_q && !inflight_q &&
                      req_src_ready;

    assign request_ready = active_q && response_pending_q;
    assign request_read_data = response_data_q;
    assign request_read_data_valid = active_q && !owner_refresh_q && !write_q &&
                                     response_data_valid_q;

    assign debug_state = {active_q, sent_q, inflight_q, write_q, burst_q,
                          streaming_q, response_pending_q, owner_refresh_q};

    function automatic logic [15:0] lane(input logic [63:0] word, input logic [1:0] index);
        lane = word[16*index +: 16];
    endfunction

    wire [101:0] req_payload = {
        write_q,
        DDRAM_BASE + {7'd0, address_q[24:3]},
        write_q ? (8'(byte_enable_q) << {address_q[2:1], 1'b0}) : 8'hFF,
        {4{data_out_q}}
    };

    always_ff @(posedge clk) begin
        if (req_send)
            inflight_q <= 1'b1;
        else if (resp_update)
            inflight_q <= 1'b0;
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            active_q              <= 1'b0;
            sent_q                <= 1'b0;
            owner_refresh_q       <= 1'b0;
            write_q               <= 1'b0;
            burst_q               <= 1'b0;
            address_q             <= 25'd0;
            byte_enable_q         <= 2'b00;
            data_out_q            <= 16'h0000;
            response_pending_q    <= 1'b0;
            response_data_q       <= 16'h0000;
            response_data_valid_q <= 1'b0;
            line_q                <= 64'd0;
            beat_q                <= 2'd0;
            streaming_q           <= 1'b0;
            protocol_error        <= 1'b0;
        end else begin
            response_data_valid_q <= 1'b0;
            if (request_valid && request_command_valid &&
                (request_byte_enable == 2'b00))
                protocol_error <= 1'b1;
            if (request_accept && (request_burst === 1'b1) &&
                (request_write || (request_address[2:1] != 2'b00)))
                protocol_error <= 1'b1;

            if (request_accept) begin
                active_q           <= 1'b1;
                sent_q             <= 1'b0;
                owner_refresh_q    <= request_owner_refresh;
                write_q            <= request_write;
                burst_q            <= (request_burst === 1'b1);
                address_q          <= request_address;
                byte_enable_q      <= request_byte_enable;
                data_out_q         <= request_data_out;
                // Refresh has no physical work: complete on the next edge.
                response_pending_q <= request_owner_refresh;
                streaming_q        <= 1'b0;
                beat_q             <= 2'd0;
            end else if (active_q && request_ready) begin
                active_q           <= 1'b0;
                sent_q             <= 1'b0;
                response_pending_q <= 1'b0;
            end else if (req_send) begin
                sent_q <= 1'b1;
            end else if (active_q && sent_q && resp_update) begin
                if (write_q) begin
                    response_pending_q <= 1'b1;
                end else if (burst_q) begin
                    line_q                <= resp_data;
                    response_data_q       <= lane(resp_data, 2'd0);
                    response_data_valid_q <= 1'b1;
                    beat_q                <= 2'd1;
                    streaming_q           <= 1'b1;
                end else begin
                    response_data_q       <= lane(resp_data, address_q[2:1]);
                    response_data_valid_q <= 1'b1;
                    response_pending_q    <= 1'b1;
                end
            end else if (streaming_q) begin
                // Beats 1..3 of a line fill; ready accompanies the last.
                response_data_q       <= lane(line_q, beat_q);
                response_data_valid_q <= 1'b1;
                beat_q                <= beat_q + 2'd1;
                if (beat_q == 2'd3) begin
                    streaming_q        <= 1'b0;
                    response_pending_q <= 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Clock-domain crossing
    // ------------------------------------------------------------------
    logic [101:0] ddr_payload;
    logic         ddr_update;

    at_cdc_snapshot #(.WIDTH(102)) request_cdc (
        .src_clk(clk), .src_send(req_send), .src_data(req_payload),
        .src_ready(req_src_ready),
        .dst_clk(ddr_clk), .dst_data(ddr_payload), .dst_update(ddr_update)
    );

    logic resp_src_ready;
    at_cdc_snapshot #(.WIDTH(64)) response_cdc (
        .src_clk(ddr_clk), .src_send(ddr_done), .src_data(ddr_rdata),
        .src_ready(resp_src_ready),
        .dst_clk(clk), .dst_data(resp_data), .dst_update(resp_update)
    );

    // ------------------------------------------------------------------
    // DDRAM clock domain
    // ------------------------------------------------------------------
    // The captured payload stays stable until the next request, which
    // cannot be launched before this one has answered.
    logic ddr_pending_q = 1'b0;
    always_ff @(posedge ddr_clk) begin
        if (ddr_update)
            ddr_pending_q <= 1'b1;
        else if (ddr_done)
            ddr_pending_q <= 1'b0;
    end

    assign ddr_req   = ddr_pending_q;
    assign ddr_write = ddr_payload[101];
    assign ddr_addr  = ddr_payload[100:72];
    assign ddr_be    = ddr_payload[71:64];
    assign ddr_din   = ddr_payload[63:0];

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset) begin
            assert (!(request_ready && !active_q))
                else $error("AT DDRAM owner completed without an active request");
            assert (!(request_read_data_valid && write_q))
                else $error("AT DDRAM owner returned read data for a write");
            assert (burst_q || !request_read_data_valid || request_ready)
                else $error("AT DDRAM owner returned single-read data without ready");
        end
    end
    always_ff @(posedge ddr_clk) begin
        assert (!(ddr_done && !resp_src_ready))
            else $error("AT DDRAM owner response overran its crossing");
        assert (!(ddr_update && ddr_pending_q))
            else $error("AT DDRAM owner received a second request while one is pending");
    end
`endif

endmodule
