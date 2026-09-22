// Counterfactual simulation ONLY: replace selected physical owner transactions
// with one word per clock, starting one clock after acceptance. CPU, bridge,
// memory-port arbitration, P03 hits/fills/invalidation and scoreboards remain.
// This is not a proposed SDRAM implementation or an achievable speed promise.
integer ideal_owner_mode = 0;
logic ideal_active = 0;
logic ideal_write = 0;
integer ideal_word = 0;
integer ideal_beat = 0;
integer ideal_length = 1;
// Mode 6 tests a 1 KiB direct-mapped data cache (512 individual words).
// Misses use the physical owner. Writes remain physical and update an already
// cached word after completion; a write miss does not allocate. This harness
// has no DMA/HPS writers, so it cannot validate system-wide cache coherence.
logic data_cache_valid [0:511] = '{default:0};
logic [23:0] data_cache_tag [0:511] = '{default:0};
logic [15:0] data_cache_data [0:511] = '{default:0};
logic [15:0] ideal_cached_data = 0;
integer data_cache_hits = 0;
integer data_cache_misses = 0;
integer data_cache_write_updates = 0;
wire [8:0] data_cache_index = p03_out_address[9:1];
wire data_cache_candidate = !p03_out_code && !p03_out_refresh &&
    p03_out_address < 25'h00A0000 && !p03_out_burst;
wire data_cache_hit = data_cache_candidate && data_cache_valid[data_cache_index] &&
    data_cache_tag[data_cache_index] == p03_out_address[24:1];
wire ideal_selected = ideal_owner_mode == 1 ||
    (ideal_owner_mode == 2 && p03_out_code) ||
    (ideal_owner_mode == 3 && !p03_out_code) ||
    (ideal_owner_mode == 4 && !p03_out_code && !p03_out_write) ||
    (ideal_owner_mode == 5 && p03_out_write) ||
    (ideal_owner_mode == 6 && data_cache_hit && !p03_out_write);
wire ideal_accept = ideal_selected && !ideal_active &&
    p03_out_valid && p03_out_command;
wire ideal_ready = ideal_active && (ideal_beat == ideal_length-1);
assign p03_out_accept = ideal_selected ? ideal_accept : physical_accept;
assign p03_out_ready = ideal_selected ? ideal_ready : physical_ready;
assign p03_out_read_valid = ideal_selected ? ideal_active && !ideal_write : physical_read_valid;
assign p03_out_read_data = ideal_selected ?
    (ideal_owner_mode == 6 ? ideal_cached_data : dram.mem[ideal_word + ideal_beat]) : physical_read_data;

always @(posedge clk) begin
    if (reset) begin
        ideal_active <= 0;
        ideal_beat <= 0;
        for (integer i = 0; i < 512; i++) data_cache_valid[i] = 0;
    end else begin
        if (ideal_owner_mode == 6 && p03_out_command && p03_out_accept &&
            data_cache_candidate && !p03_out_write) begin
            if (data_cache_hit) data_cache_hits++;
            else data_cache_misses++;
        end
        if (ideal_owner_mode == 6 && physical_ready && data_cache_candidate) begin
            if (!p03_out_write && physical_read_valid) begin
                data_cache_valid[data_cache_index] <= 1;
                data_cache_tag[data_cache_index] <= p03_out_address[24:1];
                data_cache_data[data_cache_index] <= physical_read_data;
            end else if (p03_out_write && data_cache_hit) begin
                if (p03_out_lanes[0]) data_cache_data[data_cache_index][7:0] <= p03_out_data[7:0];
                if (p03_out_lanes[1]) data_cache_data[data_cache_index][15:8] <= p03_out_data[15:8];
                data_cache_write_updates++;
            end
        end
        if (ideal_accept) begin
            if (p03_out_refresh || p03_out_lanes == 0 ||
                int'(p03_out_address[24:1]) + (p03_out_burst ? 4 : 1) > dram.MEM_WORDS)
                $fatal(1, "Ideal owner request outside supported backing memory");
            ideal_word <= int'(p03_out_address[24:1]);
            ideal_length <= p03_out_burst ? 4 : 1;
            ideal_beat <= 0;
            ideal_write <= p03_out_write;
            ideal_cached_data <= data_cache_data[data_cache_index];
            ideal_active <= 1;
            if (p03_out_write) begin
                if (p03_out_burst) $fatal(1, "Unexpected burst write");
                if (p03_out_lanes[0]) dram.mem[int'(p03_out_address[24:1])][7:0] <= p03_out_data[7:0];
                if (p03_out_lanes[1]) dram.mem[int'(p03_out_address[24:1])][15:8] <= p03_out_data[15:8];
            end
        end else if (ideal_active) begin
            if (!ideal_selected) $fatal(1, "Ideal selection changed before completion");
            if (ideal_ready) ideal_active <= 0;
            else ideal_beat <= ideal_beat + 1;
        end
    end
end
