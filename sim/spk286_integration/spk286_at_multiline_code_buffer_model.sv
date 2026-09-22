`timescale 1ns/1ps

// Simulation-only capacity/associativity experiment. This is NOT a production
// cache implementation or a BRAM/timing-closure claim. It retains the physical
// four-word SDRAM fill, bypass traffic and complete-before-response protocol.
// Runtime parameters are fixed before reset release. A one-clock hit penalty
// models a possible extra lookup stage without idealizing the physical owner.
module spk286_at_multiline_code_buffer_model #(
    parameter logic ENABLE = 1'b1
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

    localparam integer MAX_LINES = 128;
    integer code_lines = 1, code_ways = 1, code_hit_extra = 0;
    initial begin
        if ($value$plusargs("CODE_LINES=%d", code_lines)) begin end
        if ($value$plusargs("CODE_WAYS=%d", code_ways)) begin end
        if ($value$plusargs("CODE_HIT_EXTRA=%d", code_hit_extra)) begin end
        if (code_lines < 1 || code_lines > MAX_LINES ||
            (code_lines & (code_lines-1)) != 0 ||
            (code_ways != 1 && code_ways != 2) || code_ways > code_lines ||
            code_hit_extra < 0 || code_hit_extra > 1)
            $fatal(1, "Invalid multiline code buffer configuration");
        $display("CODE_BUFFER_CONFIG lines=%0d ways=%0d line_bytes=8 hit_extra=%0d",
                 code_lines, code_ways, code_hit_extra);
    end

    logic [1:0]  state_q;
    logic        physical_inflight_q;
    logic [1:0]  fill_index_q;
    logic [MAX_LINES-1:0] line_valid_q;
    logic [24:0] line_tag_q [0:MAX_LINES-1];
    logic [15:0] line_data_q [0:MAX_LINES-1][0:3];
    logic [MAX_LINES-1:0] lru_way_q;
    integer request_slot_q;
    logic hit_wait_q;

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

    function automatic logic write_touches_line(
        input logic [24:0] address,
        input logic [1:0]  byte_enable,
        input logic [24:0] tag
    );
        logic [24:0] first_byte;
        logic [24:0] second_byte;
        begin
            // Match KFSDRAM's address[24:1] and DQM lane semantics, including
            // an upper-byte command whose supplied address itself is odd.
            first_byte  = {address[24:1], 1'b0};
            second_byte = {address[24:1], 1'b1};
            write_touches_line =
                (byte_enable[0] && (line_base(first_byte) == tag)) ||
                (byte_enable[1] && (line_base(second_byte) == tag));
        end
    endfunction

    wire [24:0] input_line_base = line_base(in_address);
    wire [1:0] request_word_index = request_address_q[2:1];
    integer input_set, input_first_slot, hit_slot, victim_slot;
    logic tag_hit, invalid_slot_found;
    always_comb begin
        input_set = (int'(input_line_base) >> 3) & ((code_lines/code_ways)-1);
        input_first_slot = input_set * code_ways;
        hit_slot = input_first_slot;
        victim_slot = input_first_slot + (code_ways == 2 ? int'(lru_way_q[input_set]) : 0);
        tag_hit = 1'b0;
        invalid_slot_found = 1'b0;
        for (integer way = 0; way < 2; way = way + 1) begin
            if (way < code_ways) begin
                if (line_valid_q[input_first_slot+way] &&
                    line_tag_q[input_first_slot+way] == input_line_base) begin
                    tag_hit = 1'b1;
                    hit_slot = input_first_slot+way;
                end
                if (!line_valid_q[input_first_slot+way] && !invalid_slot_found) begin
                    victim_slot = input_first_slot+way;
                    invalid_slot_found = 1'b1;
                end
            end
        end
    end

    function automatic logic [MAX_LINES-1:0] touched_lines(
        input logic [24:0] address, input logic [1:0] lanes
    );
        begin
            touched_lines = '0;
            for (integer slot = 0; slot < MAX_LINES; slot = slot + 1)
                if (slot < code_lines && line_valid_q[slot] &&
                    write_touches_line(address, lanes, line_tag_q[slot]))
                    touched_lines[slot] = 1'b1;
        end
    endfunction

    wire cache_candidate = ENABLE && enable &&
                           (in_owner == OWNER_CPU) &&
                           !in_write && !in_refresh && in_code_fetch &&
                           (in_byte_enable != 2'b00) &&
                           cacheable_code_line(input_line_base);
    wire cache_hit = cache_candidate && tag_hit;
    wire cache_miss = cache_candidate && !cache_hit;
    wire input_present = in_valid && in_command_valid;
    // The integration drives cancel_cpu while the machine is held in boot
    // reset, including while the HPS loader is filling the BIOS window.
    // That signal is only allowed to cancel CPU ownership; loader, DMA and
    // refresh traffic must still pass through so main_rom_loaded can assert.
    wire input_cpu_cancelled = cancel_cpu && (in_owner == OWNER_CPU);
    wire current_cancelled = request_cancelled_q ||
                             (cancel_cpu && (request_owner_q == OWNER_CPU));

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
                in_ready            = !hit_wait_q;
                in_read_data        = current_cancelled ? 16'hFFFF :
                                      line_data_q[request_slot_q][request_word_index];
                in_read_data_valid  = !hit_wait_q;
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

                // If CPU reset arrives between beats there is no physical
                // command to issue.  Complete the already-accepted logical
                // read with a discarded value; if a beat is in flight, wait
                // for that beat to drain first.
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
                                          line_data_q[request_slot_q][request_word_index];
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
            request_slot_q          <= 0;
            hit_wait_q              <= 1'b0;
            lru_way_q               <= '0;
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
            // Invalid entries are never read. A complete fill initializes all
            // four words before publishing valid; no data-array reset needed.
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

                        if (cache_hit && in_accept) begin
                            state_q <= STATE_HIT;
                            request_slot_q <= hit_slot;
                            hit_wait_q <= (code_hit_extra != 0);
                            lru_way_q[input_set] <= (hit_slot == input_first_slot);
                            debug_hit_count <= debug_hit_count + 32'd1;
                        end else if (cache_miss && in_accept) begin
                            state_q             <= STATE_FILL;
                            physical_inflight_q <= 1'b1;
                            fill_index_q        <= 2'd0;
                            request_line_base_q <= input_line_base;
                            request_slot_q      <= victim_slot;
                            line_valid_q[victim_slot] <= 1'b0;
                            lru_way_q[input_set] <= (victim_slot == input_first_slot);
                            debug_miss_count    <= debug_miss_count + 32'd1;
                            debug_fill_count    <= debug_fill_count + 32'd1;
                        end else if (!cache_candidate && in_accept) begin
                            state_q             <= STATE_BYPASS;
                            physical_inflight_q <= 1'b1;
                            if (!in_write)
                                debug_physical_read_count <=
                                    debug_physical_read_count + 32'd1;
                            if (in_write && |touched_lines(in_address, in_byte_enable)) begin
                                line_valid_q <= line_valid_q & ~touched_lines(in_address, in_byte_enable);
                                debug_invalidation_count <=
                                    debug_invalidation_count + 32'($countones(touched_lines(in_address, in_byte_enable)));
                            end
                        end
                    end
                end

                STATE_HIT: begin
                    if (hit_wait_q) hit_wait_q <= 1'b0;
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
                        if (request_write_q && |touched_lines(request_address_q, request_byte_enable_q)) begin
                            line_valid_q <= line_valid_q & ~touched_lines(request_address_q, request_byte_enable_q);
                            debug_invalidation_count <=
                                debug_invalidation_count + 32'($countones(touched_lines(request_address_q, request_byte_enable_q)));
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
                        line_data_q[request_slot_q][fill_index_q] <= out_read_data;
                        debug_physical_read_count <=
                            debug_physical_read_count + 32'd1;
                        if ((fill_index_q == 2'd3) && out_ready) begin
                            physical_inflight_q <= 1'b0;
                            state_q     <= STATE_IDLE;
                            line_valid_q[request_slot_q] <= 1'b1;
                            line_tag_q[request_slot_q]   <= request_line_base_q;
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
            // CPU reset invalidates every cached line, even when IDLE or
            // serving another owner. It does not cancel DMA/loader completion.
            if (cancel_cpu) begin
                line_valid_q <= '0;
                if (|line_valid_q)
                    debug_invalidation_count <= debug_invalidation_count + 32'($countones(line_valid_q));
            end
        end
    end

`ifndef SYNTHESIS
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
