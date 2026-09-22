`timescale 1ns/1ps

// Direct-mapped P03 instruction buffer for the physical AT memory owner.
//
// The upstream memory port still serializes CPU, DMA, loader and refresh
// ownership.  This block only changes CPU code-fetch reads that are safe to
// read ahead: 64 aligned 8-byte lines, each filled by one four-word SDRAM
// burst. All other traffic is passed through unchanged.
//
// There is deliberately no speculative response, write posting or dirty
// state.  A fill completes physically before its one logical CPU response is
// published. Any write that touches a cached line invalidates it, no
// matter whether the writer is CPU, DMA or the HPS loader.

module spk286_at_sdram_read_buffer #(
    parameter logic ENABLE = 1'b1,
    parameter integer LINE_COUNT = 64
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        cancel_cpu,
    input  logic        enable,

    input  logic        in_valid,
    input  logic        in_command_valid,
    input  logic [1:0]  in_owner,
    input  logic        in_write,
    input  logic        in_refresh,
    input  logic        in_code_fetch,
    input  logic [3:0]  in_cycle_class,
    input  logic [24:0] in_address,
    input  logic [1:0]  in_byte_enable,
    input  logic [15:0] in_data_out,
    output logic        in_accept,
    output logic        in_ready,
    output logic [15:0] in_read_data,
    output logic        in_read_data_valid,

    output logic        out_valid,
    output logic        out_command_valid,
    output logic [1:0]  out_owner,
    output logic        out_write,
    output logic        out_refresh,
    output logic        out_code_fetch,
    output logic        out_burst,
    output logic [3:0]  out_cycle_class,
    output logic [24:0] out_address,
    output logic [1:0]  out_byte_enable,
    output logic [15:0] out_data_out,
    input  logic        out_accept,
    input  logic        out_ready,
    input  logic [15:0] out_read_data,
    input  logic        out_read_data_valid,

    output logic [31:0] debug_hit_count,
    output logic [31:0] debug_miss_count,
    output logic [31:0] debug_fill_count,
    output logic [31:0] debug_physical_read_count,
    output logic [31:0] debug_invalidation_count,
    output logic [4:0]  debug_state
);

    localparam logic [1:0] OWNER_CPU = 2'd0;

    localparam logic [1:0] STATE_IDLE   = 2'd0;
    localparam logic [1:0] STATE_HIT    = 2'd1;
    localparam logic [1:0] STATE_BYPASS = 2'd2;
    localparam logic [1:0] STATE_FILL   = 2'd3;

    logic [1:0]  state_q;
    logic        physical_inflight_q;
    logic [1:0]  fill_index_q;
    localparam integer INDEX_BITS = (LINE_COUNT > 1) ? $clog2(LINE_COUNT) : 1;
    localparam integer TAG_LOW = 3 + $clog2(LINE_COUNT);
    localparam integer DATA_ADDRESS_BITS = $clog2(LINE_COUNT * 4);
    logic [LINE_COUNT-1:0] line_valid_q;
    logic [24:TAG_LOW] line_tag_q [0:LINE_COUNT-1];
    // Synchronous read, no array reset: Quartus can infer one M10K for the
    // 256x16 production data array. Tags/valid bits have an asynchronous lookup.
    (* ramstyle = "M10K" *) logic [15:0] line_data_q [0:LINE_COUNT*4-1];
    logic [15:0] hit_data_q;
    logic [15:0] fill_word_q;
    logic [INDEX_BITS-1:0] request_index_q;

    logic [1:0]  request_owner_q;
    logic        request_write_q;
    logic        request_refresh_q;
    logic        request_code_fetch_q;
    logic [3:0]  request_cycle_class_q;
    logic [24:0] request_address_q;
    logic [1:0]  request_byte_enable_q;
    logic [15:0] request_data_out_q;
    logic [24:0] request_line_base_q;
    logic        request_cancelled_q;

    assign debug_state = {state_q, physical_inflight_q,
                          request_cancelled_q, |line_valid_q};

    // Addresses are already canonical backend byte addresses. Reapplying
    // CPU BIOS aliases here would turn shifted high RAM into BIOS hits.
    function automatic logic [24:0] line_base(input logic [24:0] address);
        begin
            line_base = {address[24:3], 3'b000};
        end
    endfunction

    function automatic logic cacheable_code_line(input logic [24:0] base);
        begin
            // Four full words must be legal.  The aligned upper bound is
            // therefore eight bytes below each inclusive region limit.
            cacheable_code_line =
                (base <= 25'h009FFF8) ||
                ((base >= 25'h00F0000) && (base <= 25'h00FFFF8)) ||
                ((base >= 25'h0100000) && (base <= 25'h11DFFF8));
        end
    endfunction

    function automatic logic [INDEX_BITS-1:0] line_index(input logic [24:0] address);
        begin
            line_index = (LINE_COUNT == 1) ? '0 : INDEX_BITS'(address >> 3);
        end
    endfunction

    // Quartus 17 does not synthesize $countones. Keep the diagnostic count
    // equivalent using a fixed elaboration-time loop (pruned in NO_DEBUG).
    function automatic logic [31:0] valid_line_count(input logic [LINE_COUNT-1:0] valid_bits);
        begin
            valid_line_count = 32'd0;
            for (integer slot = 0; slot < LINE_COUNT; slot = slot + 1)
                valid_line_count = valid_line_count + {31'd0, valid_bits[slot]};
        end
    endfunction

    wire [24:0] input_line_base = line_base(in_address);
    wire [INDEX_BITS-1:0] input_index = line_index(in_address);
    wire [1:0] request_word_index = request_address_q[2:1];
    wire input_tag_hit = line_valid_q[input_index] &&
                         (line_tag_q[input_index] == in_address[24:TAG_LOW]);
    wire request_tag_hit = line_valid_q[request_index_q] &&
                           (line_tag_q[request_index_q] == request_address_q[24:TAG_LOW]);
    // Backend lanes address {address[24:1], 0/1}, not address and address+1.
    // Both physical bytes are always in the same aligned eight-byte line,
    // including an upper-byte write supplied at the odd last-byte address.
    wire input_write_hit = in_write && (|in_byte_enable) && input_tag_hit;
    wire request_write_hit = request_write_q && (|request_byte_enable_q) && request_tag_hit;

    wire cache_candidate = ENABLE && enable &&
                           (in_owner == OWNER_CPU) &&
                           !in_write && !in_refresh && in_code_fetch &&
                           (in_byte_enable != 2'b00) &&
                           cacheable_code_line(input_line_base);
    wire cache_hit = cache_candidate && input_tag_hit;
    wire cache_miss = cache_candidate && !cache_hit;
    wire input_present = in_valid && in_command_valid;
    // The integration drives cancel_cpu while the machine is held in boot
    // reset, including while the HPS loader is filling the BIOS window.
    // That signal is only allowed to cancel CPU ownership; loader, DMA and
    // refresh traffic must still pass through so main_rom_loaded can assert.
    wire input_cpu_cancelled = cancel_cpu && (in_owner == OWNER_CPU);
    wire current_cancelled = request_cancelled_q ||
                             (cancel_cpu && (request_owner_q == OWNER_CPU));

    // Capture the hit word on the same edge that accepts its address. The
    // existing STATE_HIT response consumes the registered RAM output, without
    // another lookup clock or dependence on live upstream metadata.
    always_ff @(posedge clk) begin
        if (!reset) begin
            if (state_q == STATE_IDLE && in_accept && cache_hit)
                hit_data_q <= line_data_q[DATA_ADDRESS_BITS'({input_index, in_address[2:1]})];
            if (state_q == STATE_FILL && physical_inflight_q &&
                !current_cancelled && out_read_data_valid)
                line_data_q[DATA_ADDRESS_BITS'({request_index_q, fill_index_q})] <= out_read_data;
            if (state_q == STATE_FILL && physical_inflight_q && !current_cancelled &&
                out_read_data_valid && out_ready && fill_index_q == 2'd3)
                line_tag_q[request_index_q] <= request_line_base_q[24:TAG_LOW];
        end
    end

    always_comb begin
        in_accept            = 1'b0;
        in_ready             = 1'b0;
        in_read_data        = 16'h0000;
        in_read_data_valid  = 1'b0;

        out_valid           = 1'b0;
        out_command_valid   = 1'b0;
        out_owner           = request_owner_q;
        out_write           = request_write_q;
        out_refresh         = request_refresh_q;
        out_code_fetch      = request_code_fetch_q;
        out_burst           = 1'b0;
        out_cycle_class     = request_cycle_class_q;
        out_address         = request_address_q;
        out_byte_enable     = request_byte_enable_q;
        out_data_out        = request_data_out_q;

        case (state_q)
            STATE_IDLE: begin
                // A hit is accepted locally.  The response is registered by
                // entering STATE_HIT, so the upstream protocol never sees a
                // combinational data response.
                if (input_present && !input_cpu_cancelled) begin
                    if (cache_hit) begin
                        in_accept = 1'b1;
                    end else begin
                        // Misses and non-cacheable requests are sent to the
                        // owner.  A miss starts with the first full-word beat
                        // of its canonical line.
                        out_valid         = 1'b1;
                        out_command_valid = 1'b1;
                        if (cache_miss) begin
                            out_owner       = OWNER_CPU;
                            out_write       = 1'b0;
                            out_refresh     = 1'b0;
                            out_code_fetch  = 1'b1;
                            out_burst       = 1'b1;
                            out_cycle_class = in_cycle_class;
                            out_address      = input_line_base;
                            out_byte_enable  = 2'b11;
                            out_data_out     = 16'h0000;
                        end else begin
                            out_owner       = in_owner;
                            out_write       = in_write;
                            out_refresh     = in_refresh;
                            out_code_fetch  = in_code_fetch;
                            out_cycle_class = in_cycle_class;
                            out_address      = in_address;
                            out_byte_enable  = in_byte_enable;
                            out_data_out     = in_data_out;
                        end
                        in_accept = out_accept;
                    end
                end
            end

            STATE_HIT: begin
                in_ready            = 1'b1;
                in_read_data        = current_cancelled ? 16'hFFFF :
                                      hit_data_q;
                in_read_data_valid  = 1'b1;
            end

            STATE_BYPASS: begin
                out_valid         = 1'b1;
                out_command_valid = !physical_inflight_q;
                if (physical_inflight_q && out_ready &&
                    (request_write_q || request_refresh_q ||
                     out_read_data_valid ||
                     current_cancelled)) begin
                    in_ready            = 1'b1;
                    in_read_data        = current_cancelled ? 16'hFFFF :
                                          out_read_data;
                    // Refresh completes on READY without returning a data
                    // word.  Ordinary read owners still require the
                    // physical data-valid indication.
                    in_read_data_valid  = !request_write_q &&
                                           !request_refresh_q;
                end
            end

            STATE_FILL: begin
                out_valid         = 1'b1;
                out_command_valid = !physical_inflight_q && !current_cancelled;
                out_owner         = OWNER_CPU;
                out_write         = 1'b0;
                out_refresh       = 1'b0;
                out_code_fetch    = 1'b1;
                out_burst         = 1'b1;
                out_cycle_class   = request_cycle_class_q;
                // KFSDRAM advances the column internally for the burst; the
                // base address must remain stable for the whole owner
                // transaction.
                out_address       = request_line_base_q;
                out_byte_enable   = 2'b11;
                out_data_out      = 16'h0000;

                // A cancelled accepted burst must drain through final READY.
                // Intermediate data-valid beats cannot release its owner.
                if (current_cancelled) begin
                    if (!physical_inflight_q ||
                        (out_ready && out_read_data_valid)) begin
                        in_ready            = 1'b1;
                        in_read_data        = 16'hFFFF;
                        in_read_data_valid  = 1'b1;
                    end
                end else if (physical_inflight_q && out_read_data_valid &&
                             (fill_index_q == 2'd3) && out_ready) begin
                    in_ready           = 1'b1;
                    in_read_data        = (request_word_index == 2'd3) ?
                                          out_read_data :
                                          fill_word_q;
                    in_read_data_valid = 1'b1;
                end
            end

            default: begin
            end
        endcase
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state_q                 <= STATE_IDLE;
            physical_inflight_q     <= 1'b0;
            fill_index_q            <= 2'd0;
            line_valid_q            <= '0;
            request_index_q         <= '0;
            fill_word_q             <= 16'h0000;
            request_owner_q         <= OWNER_CPU;
            request_write_q         <= 1'b0;
            request_refresh_q       <= 1'b0;
            request_code_fetch_q    <= 1'b0;
            request_cycle_class_q  <= 4'h0;
            request_address_q       <= 25'h0000000;
            request_byte_enable_q   <= 2'b00;
            request_data_out_q      <= 16'h0000;
            request_line_base_q     <= 25'h0000000;
            request_cancelled_q     <= 1'b0;
            debug_hit_count         <= 32'd0;
            debug_miss_count        <= 32'd0;
            debug_fill_count        <= 32'd0;
            debug_physical_read_count <= 32'd0;
            debug_invalidation_count <= 32'd0;
        end else begin
            if (cancel_cpu && state_q != STATE_IDLE &&
                request_owner_q == OWNER_CPU) begin
                request_cancelled_q <= 1'b1;
            end

            case (state_q)
                STATE_IDLE: begin
                    physical_inflight_q <= 1'b0;
                    request_cancelled_q <= 1'b0;
                    if (input_present && !input_cpu_cancelled) begin
                        request_owner_q       <= in_owner;
                        request_write_q       <= in_write;
                        request_refresh_q     <= in_refresh;
                        request_code_fetch_q  <= in_code_fetch;
                        request_cycle_class_q <= in_cycle_class;
                        request_address_q     <= in_address;
                        request_byte_enable_q <= in_byte_enable;
                        request_data_out_q    <= in_data_out;
                        request_index_q       <= input_index;

                        if (cache_hit && in_accept) begin
                            state_q <= STATE_HIT;
                            debug_hit_count <= debug_hit_count + 32'd1;
                        end else if (cache_miss && in_accept) begin
                            state_q             <= STATE_FILL;
                            physical_inflight_q <= 1'b1;
                            fill_index_q        <= 2'd0;
                            request_line_base_q <= input_line_base;
                            line_valid_q[input_index] <= 1'b0;
                            debug_miss_count    <= debug_miss_count + 32'd1;
                            debug_fill_count    <= debug_fill_count + 32'd1;
                        end else if (!cache_candidate && in_accept) begin
                            state_q             <= STATE_BYPASS;
                            physical_inflight_q <= 1'b1;
                            if (!in_write)
                                debug_physical_read_count <=
                                    debug_physical_read_count + 32'd1;
                            if (input_write_hit) begin
                                line_valid_q[input_index] <= 1'b0;
                                debug_invalidation_count <=
                                    debug_invalidation_count + 32'd1;
                            end
                        end
                    end
                end

                STATE_HIT: begin
                    if (in_ready) begin
                        state_q             <= STATE_IDLE;
                        request_cancelled_q <= 1'b0;
                        if (current_cancelled)
                            line_valid_q <= '0;
                    end
                end

                STATE_BYPASS: begin
                    if (cancel_cpu && request_owner_q == OWNER_CPU)
                        request_cancelled_q <= 1'b1;
                    if (physical_inflight_q && out_ready &&
                        (request_write_q || request_refresh_q ||
                         out_read_data_valid ||
                         current_cancelled)) begin
                        state_q             <= STATE_IDLE;
                        physical_inflight_q <= 1'b0;
                        request_cancelled_q <= 1'b0;
                        if (request_write_hit) begin
                            line_valid_q[request_index_q] <= 1'b0;
                            debug_invalidation_count <=
                                debug_invalidation_count + 32'd1;
                        end
                    end
                end

                STATE_FILL: begin
                    if (cancel_cpu && request_owner_q == OWNER_CPU)
                        request_cancelled_q <= 1'b1;

                    if (current_cancelled) begin
                        if (in_ready) begin
                            state_q             <= STATE_IDLE;
                            physical_inflight_q <= 1'b0;
                            request_cancelled_q <= 1'b0;
                            line_valid_q        <= '0;
                        end
                    end else if (!physical_inflight_q) begin
                        if (out_accept) begin
                            physical_inflight_q <= 1'b1;
                            debug_physical_read_count <=
                                debug_physical_read_count + 32'd1;
                        end
                    end else if (out_read_data_valid) begin
                        if (fill_index_q == request_word_index)
                            fill_word_q <= out_read_data;
                        debug_physical_read_count <=
                            debug_physical_read_count + 32'd1;
                        if ((fill_index_q == 2'd3) && out_ready) begin
                            physical_inflight_q <= 1'b0;
                            state_q     <= STATE_IDLE;
                            line_valid_q[request_index_q] <= 1'b1;
                            request_cancelled_q <= 1'b0;
                        end else begin
                            fill_index_q <= fill_index_q + 2'd1;
                        end
                    end
                end

                default: begin
                    state_q <= STATE_IDLE;
                end
            endcase
            // CPU reset flushes every line, including while IDLE or while a
            // DMA/loader transaction completes. It never cancels those owners.
            if (cancel_cpu) begin
                line_valid_q <= '0;
                if (|line_valid_q)
                    debug_invalidation_count <= debug_invalidation_count + valid_line_count(line_valid_q);
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        assert (LINE_COUNT >= 1 && LINE_COUNT <= 128 &&
                (LINE_COUNT & (LINE_COUNT - 1)) == 0)
            else $fatal(1, "P03 LINE_COUNT must be a power of two from 1 to 128");
    end
    always_ff @(posedge clk) begin
        if (!reset) begin
            assert (!(in_accept && state_q != STATE_IDLE))
                else $error("P03 accepted an upstream command outside IDLE");
            assert (!(in_read_data_valid && !in_ready))
                else $error("P03 published read data without ready");
            assert (!(out_command_valid && !out_valid))
                else $error("P03 published a command without a request");
        end
    end
`endif

endmodule
