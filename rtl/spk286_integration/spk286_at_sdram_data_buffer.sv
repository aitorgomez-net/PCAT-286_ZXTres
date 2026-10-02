`timescale 1ns/1ps

// PCAT RAM data-read buffer, below the common memory owner and the P03 code
// buffer. Two ways, 256 sets = 512 physical words = 1 KiB of data. Both ways
// read their combined tag/data RAM in parallel on local acceptance.
// RAM lookup; hits return one clock after local acceptance. A miss reads one
// complete word from SDRAM before allocation. All writes complete physically
// and update an already cached matching word (no write allocation or posting).
// CPU, DMA and loader writes use the same port. Code/burst/refresh traffic is
// passed through, including intermediate burst data-valid beats.
module spk286_at_sdram_data_buffer #(
    parameter logic ENABLE = 1'b1,
    parameter integer WORD_COUNT = 512
) (
    input logic clk, reset, cancel_cpu, enable,
    input logic in_valid, in_command_valid,
    input logic [1:0] in_owner,
    input logic in_write, in_refresh, in_code_fetch, in_burst,
    input logic [3:0] in_cycle_class,
    input logic [24:0] in_address,
    input logic [1:0] in_byte_enable,
    input logic [15:0] in_data_out,
    output logic in_accept, in_ready,
    output logic [15:0] in_read_data,
    output logic in_read_data_valid,

    output logic out_valid, out_command_valid,
    output logic [1:0] out_owner,
    output logic out_write, out_refresh, out_code_fetch, out_burst,
    output logic [3:0] out_cycle_class,
    output logic [24:0] out_address,
    output logic [1:0] out_byte_enable,
    output logic [15:0] out_data_out,
    input logic out_accept, out_ready,
    input logic [15:0] out_read_data,
    input logic out_read_data_valid,

    output logic [31:0] debug_hit_count, debug_miss_count,
    output logic [31:0] debug_fill_count, debug_write_update_count,
    output logic [1:0] debug_state
);
    localparam logic [1:0] OWNER_CPU = 2'd0;
    localparam logic [1:0] STATE_IDLE = 2'd0;
    localparam logic [1:0] STATE_LOOKUP = 2'd1;
    localparam logic [1:0] STATE_PHYSICAL = 2'd2;
    localparam integer SET_COUNT = WORD_COUNT / 2;
    localparam integer INDEX_BITS = (SET_COUNT > 1) ? $clog2(SET_COUNT) : 1;
    localparam integer TAG_LOW = $clog2(SET_COUNT) + 1;
    localparam integer TAG_BITS = 25 - TAG_LOW;

    logic [1:0] state_q;
    logic [SET_COUNT-1:0] valid0_q, valid1_q, replace_q;
    // No tag/data reset. Production uses two 256 x 32-bit M10K arrays,
    // with resettable valid bits and one replacement bit per set.
    (* ramstyle = "M10K" *) logic [TAG_BITS+15:0] words0_q [0:SET_COUNT-1];
    (* ramstyle = "M10K" *) logic [TAG_BITS+15:0] words1_q [0:SET_COUNT-1];
    logic [TAG_BITS+15:0] lookup0_q, lookup1_q;
    logic lookup_valid0_q, lookup_valid1_q, replace_way_q;
    logic [INDEX_BITS-1:0] index_q;
    logic [1:0] owner_q;
    logic write_q, refresh_q, code_q, burst_q, allocate_q, cancelled_q;
    logic [3:0] class_q;
    logic [24:0] address_q;
    logic [1:0] lanes_q;
    logic [15:0] data_q;

    wire [INDEX_BITS-1:0] input_index = (SET_COUNT == 1) ? '0 : in_address[INDEX_BITS:1];
    // Only canonical backend RAM addresses. BIOS/option ROM/UMB/video and
    // devices are excluded. Shifted extended RAM and the private EMS store
    // remain physical RAM; the machine resolves aliases/A20 before this port.
    wire ram_address = (in_address < 25'h00A0000) ||
                       ((in_address >= 25'h0100000) &&
                        (in_address < 25'h11E0000));
    wire candidate = ENABLE && enable && in_owner == OWNER_CPU &&
                     !in_write && !in_refresh && !in_code_fetch && !in_burst &&
                     in_cycle_class == 4'h5 && |in_byte_enable && ram_address;
    wire input_present = in_valid && in_command_valid;
    wire input_cancelled = cancel_cpu && in_owner == OWNER_CPU;
    wire current_cancelled = cancelled_q || (cancel_cpu && owner_q == OWNER_CPU);
    wire tag_hit0 = lookup_valid0_q && lookup0_q[TAG_BITS+15:16] == address_q[24:TAG_LOW];
    wire tag_hit1 = lookup_valid1_q && lookup1_q[TAG_BITS+15:16] == address_q[24:TAG_LOW];
    wire tag_hit = tag_hit0 || tag_hit1;
    wire hit_way = tag_hit1 && !tag_hit0;
    wire [15:0] hit_word = hit_way ? lookup1_q[15:0] : lookup0_q[15:0];
    // Invalid ways precede LRU replacement. Writes update data without
    // changing read recency; hits/fills make their way most recently used.
    wire fill_way = !lookup_valid0_q ? 1'b0 : !lookup_valid1_q ? 1'b1 : replace_way_q;
    wire physical_complete = state_q == STATE_PHYSICAL && out_ready &&
                             (write_q || refresh_q || out_read_data_valid);
    wire update_word = physical_complete && write_q && !refresh_q &&
                       ((tag_hit0 && valid0_q[index_q]) ||
                        (tag_hit1 && valid1_q[index_q])) && ENABLE && enable &&
                       !cancel_cpu && !current_cancelled;
    wire fill_word = physical_complete && allocate_q && !write_q &&
                     out_read_data_valid && ENABLE && enable &&
                     !cancel_cpu && !current_cancelled;
    logic [15:0] merged_write;

    always_comb begin
        merged_write = hit_word;
        if (lanes_q[0]) merged_write[7:0] = data_q[7:0];
        if (lanes_q[1]) merged_write[15:8] = data_q[15:8];
    end

    // The lookup and write use retained addresses. Accepted writes have enough
    // physical service time to read their old cached word before completion.
    // A nonmatching tag is left intact; CPU/DMA/loader writes all use this rule.
    always_ff @(posedge clk) begin
        if (!reset) begin
            if (state_q == STATE_IDLE && in_accept) begin
                lookup0_q <= words0_q[input_index];
                lookup1_q <= words1_q[input_index];
            end
            if (fill_word && !fill_way)
                words0_q[index_q] <= {address_q[24:TAG_LOW], out_read_data};
            else if (update_word && !hit_way)
                words0_q[index_q] <= {address_q[24:TAG_LOW], merged_write};
            if (fill_word && fill_way)
                words1_q[index_q] <= {address_q[24:TAG_LOW], out_read_data};
            else if (update_word && hit_way)
                words1_q[index_q] <= {address_q[24:TAG_LOW], merged_write};
        end
    end

    assign debug_state = state_q;
    assign in_accept = state_q == STATE_IDLE && input_present && !input_cancelled &&
                       (candidate || out_accept);
    always_comb begin
        in_ready = 1'b0;
        in_read_data = out_read_data;
        in_read_data_valid = 1'b0;
        out_valid = 1'b0;
        out_command_valid = 1'b0;
        out_owner = owner_q;
        out_write = write_q;
        out_refresh = refresh_q;
        out_code_fetch = code_q;
        out_burst = burst_q;
        out_cycle_class = class_q;
        out_address = address_q;
        out_byte_enable = lanes_q;
        out_data_out = data_q;
        case (state_q)
            STATE_IDLE: begin
                if (input_present && !input_cancelled) begin
                    if (!candidate) begin
                        // Transparent acceptance for every bypass access.
                        out_valid = 1'b1;
                        out_command_valid = 1'b1;
                        out_owner = in_owner;
                        out_write = in_write;
                        out_refresh = in_refresh;
                        out_code_fetch = in_code_fetch;
                        out_burst = in_burst;
                        out_cycle_class = in_cycle_class;
                        out_address = in_address;
                        out_byte_enable = in_byte_enable;
                        out_data_out = in_data_out;
                    end
                end
            end
            STATE_LOOKUP: begin
                if (current_cancelled || tag_hit) begin
                    in_ready = 1'b1;
                    in_read_data_valid = 1'b1;
                    in_read_data = current_cancelled ? 16'hFFFF : hit_word;
                end else begin
                    out_valid = 1'b1;
                    out_command_valid = 1'b1;
                    // Byte requests allocate the complete ordinary-RAM word.
                    // The CPU bridge still selects its original byte lane.
                    out_address = {address_q[24:1], 1'b0};
                    out_byte_enable = 2'b11;
                end
            end
            STATE_PHYSICAL: begin
                out_valid = 1'b1;
                if (allocate_q) begin
                    out_address = {address_q[24:1], 1'b0};
                    out_byte_enable = 2'b11;
                end
                // Intermediate code-fill beats must reach P03 even before
                // final READY. Cancelled bursts drain through their last beat.
                in_read_data = current_cancelled ? 16'hFFFF : out_read_data;
                in_read_data_valid = !write_q && !refresh_q && out_read_data_valid;
                in_ready = physical_complete;
            end
            default: begin end
        endcase
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state_q <= STATE_IDLE;
            valid0_q <= '0;
            valid1_q <= '0;
            replace_q <= '0;
            lookup_valid0_q <= 1'b0;
            lookup_valid1_q <= 1'b0;
            replace_way_q <= 1'b0;
            index_q <= '0;
            owner_q <= OWNER_CPU;
            write_q <= 1'b0;
            refresh_q <= 1'b0;
            code_q <= 1'b0;
            burst_q <= 1'b0;
            allocate_q <= 1'b0;
            cancelled_q <= 1'b0;
            class_q <= 4'h5;
            address_q <= '0;
            lanes_q <= '0;
            data_q <= '0;
            debug_hit_count <= 0;
            debug_miss_count <= 0;
            debug_fill_count <= 0;
            debug_write_update_count <= 0;
        end else begin
            if (cancel_cpu && state_q != STATE_IDLE && owner_q == OWNER_CPU)
                cancelled_q <= 1'b1;
            case (state_q)
                STATE_IDLE: begin
                    if (in_accept) begin
                        owner_q <= in_owner;
                        write_q <= in_write;
                        refresh_q <= in_refresh;
                        code_q <= in_code_fetch;
                        burst_q <= in_burst;
                        class_q <= in_cycle_class;
                        address_q <= in_address;
                        lanes_q <= in_byte_enable;
                        data_q <= in_data_out;
                        index_q <= input_index;
                        lookup_valid0_q <= valid0_q[input_index];
                        lookup_valid1_q <= valid1_q[input_index];
                        replace_way_q <= replace_q[input_index];
                        allocate_q <= candidate;
                        cancelled_q <= 1'b0;
                        state_q <= candidate ? STATE_LOOKUP : STATE_PHYSICAL;
                    end
                end
                STATE_LOOKUP: begin
                    if (in_ready) begin
                        state_q <= STATE_IDLE;
                        if (!current_cancelled) begin
                            replace_q[index_q] <= !hit_way;
                            debug_hit_count <= debug_hit_count + 1;
                        end
                    end else if (out_accept) begin
                        state_q <= STATE_PHYSICAL;
                        debug_miss_count <= debug_miss_count + 1;
                    end
                end
                STATE_PHYSICAL: begin
                    if (physical_complete) begin
                        state_q <= STATE_IDLE;
                        if (fill_word) begin
                            if (fill_way) valid1_q[index_q] <= 1'b1;
                            else valid0_q[index_q] <= 1'b1;
                            replace_q[index_q] <= !fill_way;
                            debug_fill_count <= debug_fill_count + 1;
                        end
                        if (update_word)
                            debug_write_update_count <= debug_write_update_count + 1;
                    end
                end
                default: state_q <= STATE_IDLE;
            endcase
            // CPU reset also flushes an idle buffer and a non-CPU transfer.
            // Non-CPU ownership continues; its old lookup cannot resurrect a
            // flushed line. Disabling also prevents stale re-enable hits.
            if (cancel_cpu || !ENABLE || !enable) begin
                valid0_q <= '0;
                valid1_q <= '0;
                replace_q <= '0;
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        assert (WORD_COUNT >= 2 && WORD_COUNT <= 1024 &&
                (WORD_COUNT & (WORD_COUNT-1)) == 0)
            else $fatal(1, "RAM buffer WORD_COUNT must be a power of two from 2 to 1024");
    end
    always_ff @(posedge clk) begin
        if (!reset) begin
            assert (!in_accept || state_q == STATE_IDLE)
                else $error("RAM buffer accepted outside IDLE");
            assert (!out_command_valid || out_valid)
                else $error("RAM buffer command without retained request");
            assert (!out_command_valid || !current_cancelled || state_q == STATE_IDLE)
                else $error("RAM buffer launched a cancelled CPU miss");
            assert (!fill_word || !burst_q)
                else $error("RAM buffer allocated a burst/device request");
            assert (!(tag_hit0 && tag_hit1))
                else $error("RAM buffer has duplicate physical tags in both ways");
        end
    end
`endif
endmodule
