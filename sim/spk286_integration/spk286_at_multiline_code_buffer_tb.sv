`timescale 1ns/1ps

// Simulation-only contract test. The byte scoreboard knows no cache tags,
// replacement policy or DUT internals. Backend accepts commands late and
// inserts gaps between burst words so READY cannot stand in for data-valid.
module spk286_at_multiline_code_buffer_tb #(
    parameter logic ENABLE = 1'b1,
    parameter integer LINE_COUNT = 64,
    parameter logic SYNC_TAGS = (LINE_COUNT > 128)
);
    logic clk = 0;
    always #5 clk = ~clk;
    logic reset = 1, cancel_cpu = 0, enable = 1;
    logic in_valid = 0, in_command_valid = 0;
    logic [1:0] in_owner = 0;
    logic in_write = 0, in_refresh = 0, in_code_fetch = 0;
    logic [3:0] in_cycle_class = 5;
    logic [24:0] in_address = 0;
    logic [1:0] in_byte_enable = 3;
    logic [15:0] in_data_out = 0;
    wire in_accept, in_ready, in_read_data_valid;
    wire [15:0] in_read_data;
    wire out_valid, out_command_valid, out_write, out_refresh;
    wire out_code_fetch, out_burst;
    wire [1:0] out_owner, out_byte_enable;
    wire [3:0] out_cycle_class;
    wire [24:0] out_address;
    wire [15:0] out_data_out;
    wire out_accept, out_ready, out_read_data_valid;
    wire [15:0] out_read_data;
    wire [31:0] debug_hit_count, debug_miss_count, debug_fill_count;
    wire [31:0] debug_physical_read_count, debug_invalidation_count;
    wire [4:0] debug_state;
`ifdef PCAT_PRODUCTION_CODE_BUFFER
    spk286_at_sdram_read_buffer #(.ENABLE(ENABLE), .LINE_COUNT(LINE_COUNT), .SYNC_TAGS(SYNC_TAGS)) dut (.*);
`else
    spk286_at_multiline_code_buffer_model #(.ENABLE(ENABLE)) dut (.*);
`endif

    integer lines = 1, ways = 1, extra = 0, sets;
    integer checks = 0, requests = 0, cycles = 0, accept_tick = 0, completion_tick = 0;
    integer commands = 0, read_beats = 0, write_commands = 0;
    // Sparse byte memories retain the entire physical address. The reference
    // is updated by the logical caller, the backend only by accepted traffic.
    logic [24:0] memory_address [0:1023], reference_address [0:1023];
    logic [7:0] memory_value [0:1023], reference_value [0:1023];
    integer memory_count = 0, reference_count = 0;
    function automatic logic [7:0] initial_byte(input logic [24:0] address);
        initial_byte = address[7:0] ^ address[15:8] ^ address[23:16] ^
                       {7'b0, address[24]} ^ 8'hA7;
    endfunction
    function automatic logic [7:0] backend_byte(input logic [24:0] address,
                                              input integer written_bytes);
        logic [7:0] result;
        result = initial_byte(address);
        for (integer i = 0; i < written_bytes; i = i + 1)
            if (memory_address[i] == address) result = memory_value[i];
        return result;
    endfunction
    function automatic logic [7:0] reference_byte(input logic [24:0] address);
        logic [7:0] result;
        result = initial_byte(address);
        for (integer i = 0; i < reference_count; i = i + 1)
            if (reference_address[i] == address) result = reference_value[i];
        return result;
    endfunction
    function automatic logic [15:0] expected_word(input logic [24:0] address);
        logic [24:0] aligned_address;
        aligned_address = {address[24:1], 1'b0};
        return {reference_byte(aligned_address + 25'd1),
                reference_byte(aligned_address)};
    endfunction
    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (!condition) begin
            $display("MULTILINE_FAIL lines=%0d ways=%0d extra=%0d ENABLE=%0d request=%0d cycle=%0d %s",
                     lines, ways, extra, ENABLE, requests, cycles, message);
            $fatal(1);
        end
    endtask

    logic backend_active = 0, backend_write = 0, backend_refresh = 0;
    logic backend_burst = 0;
    logic [24:0] backend_address = 0;
    logic [1:0] backend_owner = 0, backend_lanes = 0;
    logic backend_code = 0;
    logic [3:0] backend_class = 0;
    logic [15:0] backend_data = 0;
    integer acceptance_delay = 0, response_delay = 0, backend_beat = 0;
    wire [24:0] beat_address = {backend_address[24:1], 1'b0} + 25'(2 * backend_beat);
    assign out_accept = !reset && !backend_active && out_valid &&
                        out_command_valid && acceptance_delay == 2;
    assign out_read_data_valid = backend_active && response_delay == 0 &&
                                 !backend_write && !backend_refresh;
    assign out_read_data = {backend_byte(beat_address + 25'd1, memory_count),
                            backend_byte(beat_address, memory_count)};
    assign out_ready = backend_active && response_delay == 0 &&
                       (!backend_burst || backend_beat == 3);

    // Check the physical transaction independently from the test driver.
    always @(posedge clk) begin
        cycles = cycles + 1;
        if (reset) begin
            backend_active <= 0;
            acceptance_delay <= 0;
            response_delay <= 0;
            backend_beat <= 0;
        end else begin
            check(!(in_read_data_valid && !in_ready), "upstream data without READY");
            check(!(out_command_valid && !out_valid), "physical command without valid");
            if (!backend_active) begin
                if (out_valid && out_command_valid && !out_accept)
                    acceptance_delay <= acceptance_delay + 1;
                else acceptance_delay <= 0;
            end
            if (out_accept) begin
                commands = commands + 1;
                backend_active <= 1;
                backend_address <= out_address;
                backend_owner <= out_owner;
                backend_write <= out_write;
                backend_refresh <= out_refresh;
                backend_code <= out_code_fetch;
                backend_class <= out_cycle_class;
                backend_lanes <= out_byte_enable;
                backend_data <= out_data_out;
                backend_burst <= out_burst;
                backend_beat <= 0;
                response_delay <= 3;
                if (out_write) begin
                    check(memory_count < 1022, "backend sparse memory overflow");
                    if (out_byte_enable[0]) begin
                        memory_address[memory_count] = {out_address[24:1], 1'b0};
                        memory_value[memory_count] = out_data_out[7:0];
                        memory_count = memory_count + 1;
                    end
                    if (out_byte_enable[1]) begin
                        memory_address[memory_count] = {out_address[24:1], 1'b1};
                        memory_value[memory_count] = out_data_out[15:8];
                        memory_count = memory_count + 1;
                    end
                    write_commands = write_commands + 1;
                end
            end else if (backend_active) begin
                check(out_valid, "physical owner released before completion");
                check(!out_command_valid, "physical command reissued in flight");
                check({out_address, out_owner, out_write, out_refresh,
                       out_code_fetch, out_cycle_class, out_byte_enable,
                       out_data_out, out_burst} ===
                      {backend_address, backend_owner, backend_write, backend_refresh,
                       backend_code, backend_class, backend_lanes,
                       backend_data, backend_burst}, "in-flight physical metadata changed");
                if (response_delay != 0) response_delay <= response_delay - 1;
                else begin
                    if (out_read_data_valid) read_beats = read_beats + 1;
                    if (out_ready) backend_active <= 0;
                    else begin
                        backend_beat <= backend_beat + 1;
                        response_delay <= 1 + (backend_beat % 3);
                    end
                end
            end
        end
    end

    task automatic begin_request(input logic [1:0] owner, input logic wr,
                                 input logic refresh, input logic code_fetch,
                                 input logic [24:0] address,
                                 input logic [1:0] lanes, input logic [15:0] data);
        integer guard;
        @(negedge clk);
        requests = requests + 1;
        in_owner = owner;
        in_write = wr;
        in_refresh = refresh;
        in_code_fetch = code_fetch;
        in_cycle_class = 4'(requests % 16);
        in_address = address;
        in_byte_enable = lanes;
        in_data_out = data;
        in_valid = 1;
        in_command_valid = 1;
        guard = 0;
        do begin
            @(posedge clk);
            guard = guard + 1;
            check(guard < 200, "logical acceptance timed out");
        end while (!in_accept);
        accept_tick = integer'($time / 10);
        @(negedge clk);
        in_command_valid = 0;
        // Once accepted the model owns the request; late input metadata must
        // neither change the selected cache word nor the physical command.
        in_owner = in_owner ^ 2'b11;
        in_write = !in_write;
        in_refresh = !in_refresh;
        in_code_fetch = !in_code_fetch;
        in_cycle_class = in_cycle_class ^ 4'hF;
        in_address = in_address ^ 25'h0010006;
        in_byte_enable = in_byte_enable ^ 2'b11;
        in_data_out = in_data_out ^ 16'hFFFF;
    endtask

    task automatic finish_request(input logic expect_data,
                                  input logic [15:0] expected);
        integer guard;
        guard = 0;
        do begin
            @(posedge clk);
            guard = guard + 1;
            check(guard < 200, "logical completion timed out");
        end while (!in_ready);
        completion_tick = integer'($time / 10);
        check(in_read_data_valid == expect_data, "logical data-valid differs from request type");
        if (expect_data)
            check(in_read_data === expected,
                  $sformatf("logical data mismatch got=%04x expected=%04x", in_read_data, expected));
        @(negedge clk);
        in_valid = 0;
        @(posedge clk);
        @(negedge clk);
        check(!in_ready && !in_read_data_valid, "duplicate logical completion");
        check(!backend_active, "logical completion preceded physical drain");
    endtask

    task automatic fetch(input logic [24:0] address, input logic expect_hit);
        integer commands_before, beats_before;
        logic [15:0] expected;
        commands_before = commands;
        beats_before = read_beats;
        expected = expected_word(address);
        begin_request(0, 0, 0, 1, address, 3, 0);
        finish_request(1, expected);
        if (ENABLE && enable) begin
            check(commands - commands_before == (expect_hit ? 0 : 1),
                  $sformatf("fetch hit/miss mismatch at %07x expected_hit=%0d", address, expect_hit));
            check(read_beats - beats_before == (expect_hit ? 0 : 4),
                  "miss did not fill exactly four words or hit read backend");
            if (expect_hit)
                check(completion_tick - accept_tick == 1 + extra,
                      "hit latency differs from configured lookup penalty");
        end else begin
            check(commands - commands_before == 1 && read_beats - beats_before == 1,
                  "disabled cache did not bypass as one physical read");
        end
    endtask

    task automatic bypass_read(input logic [1:0] owner, input logic code_fetch,
                               input logic [24:0] address, input logic [1:0] lanes);
        integer commands_before, beats_before;
        commands_before = commands;
        beats_before = read_beats;
        begin_request(owner, 0, 0, code_fetch, address, lanes, 16'hBEEF);
        finish_request(1, expected_word(address));
        check(commands == commands_before + 1 && read_beats == beats_before + 1,
              "ineligible read was cached or burst");
    endtask

    task automatic write_bytes(input logic [1:0] owner,
                               input logic [24:0] address,
                               input logic [1:0] lanes, input logic [15:0] data);
        integer writes_before;
        writes_before = write_commands;
        if (lanes[0]) begin
            reference_address[reference_count] = {address[24:1], 1'b0};
            reference_value[reference_count] = data[7:0];
            reference_count = reference_count + 1;
        end
        if (lanes[1]) begin
            reference_address[reference_count] = {address[24:1], 1'b1};
            reference_value[reference_count] = data[15:8];
            reference_count = reference_count + 1;
        end
        begin_request(owner, 1, 0, 0, address, lanes, data);
        finish_request(0, 0);
        check(write_commands == writes_before + 1, "write was posted, lost or duplicated");
    endtask

    task automatic invalidate_all;
        @(negedge clk);
        cancel_cpu = 1;
        repeat (2) @(negedge clk);
        cancel_cpu = 0;
    endtask

    initial begin : test_sequence
        integer commands_before, beats_before;
        logic [24:0] a, b, c;
        if ($value$plusargs("CODE_LINES=%d", lines)) begin end
        if ($value$plusargs("CODE_WAYS=%d", ways)) begin end
        if ($value$plusargs("CODE_HIT_EXTRA=%d", extra)) begin end
`ifdef PCAT_PRODUCTION_CODE_BUFFER
        lines = LINE_COUNT;
        check(ways == 1 && extra == 0, "production cache is direct mapped with no extra hit clock");
`endif
        sets = lines / ways;
        repeat (3) @(negedge clk);
        reset = 0;

        // Every word in a line, then adjacent line, including RAM/BIOS limits.
        fetch(25'h1000, 0);
        fetch(25'h1002, 1);
        fetch(25'h1004, 1);
        fetch(25'h1006, 1);
        fetch(25'h1008, 0);
        fetch(25'h100A, 1);
        fetch(25'h009FFF8, 0);
        fetch(25'h009FFFE, 1);
        fetch(25'h00F0000, 0);
        fetch(25'h00F0006, 1);
        fetch(25'h00FFFF8, 0);
        fetch(25'h00FFFFE, 1);
        fetch(25'h0100000, 0);
        fetch(25'h0100006, 1);
        fetch(25'h11DFFF8, 0);
        fetch(25'h11DFFFE, 1);

        // Same-set conflicts distinguish direct mapping from true two-way LRU.
        invalidate_all();
        a = 25'h02000;
        b = a + 25'(8 * sets);
        c = b + 25'(8 * sets);
        fetch(a, 0);
        fetch(b, 0);
        if (ways == 1) begin
            fetch(a, 0);
            fetch(a + 2, 1);
        end else begin
            fetch(a, 1); // A most recently used, B must be the victim.
            fetch(c, 0);
            fetch(a + 2, 1);
            fetch(b, 0);
            fetch(a + 4, 1);
            fetch(c, 0);
        end

        // Fill every physical slot, then revisit every line. A capacity or
        // index bug cannot hide behind a few addresses in the first set.
        invalidate_all();
        for (integer slot = 0; slot < lines; slot = slot + 1)
            fetch(25'h10000 + 25'(slot * 8), 0);
        for (integer slot = 0; slot < lines; slot = slot + 1)
            fetch(25'h10002 + 25'(slot * 8), 1);
        fetch(25'h10000 + 25'(lines * 8), 0);
        if (ways == 2) fetch(25'h10000 + 25'(sets * 8), 1);
        fetch(25'h10000, 0);
        invalidate_all();
        for (integer slot = 0; slot < lines; slot = slot + 1)
            fetch(25'h10004 + 25'(slot * 8), 0);

        // Independently update low/high/both bytes via each writer. Every
        // touched line must become a miss and untargeted lines remain valid.
        for (integer owner_case = 0; owner_case < 3; owner_case = owner_case + 1) begin
            for (integer lane_case = 1; lane_case < 4; lane_case = lane_case + 1) begin
              for (integer address_case = 0; address_case < 4; address_case = address_case + 1) begin
                invalidate_all();
                fetch(25'h03000, 0);
                write_bytes(owner_case == 2 ? 2'd3 : 2'(owner_case),
                            25'h03000 + 25'(address_case < 2 ? address_case : address_case + 4),
                            2'(lane_case), 16'(32'h5A80 + owner_case * 16 + lane_case));
                fetch(25'h03000 + 25'(address_case < 2 ? 0 : 6), 0);
                fetch(25'h03004, 1);
              end
            end
        end
        invalidate_all();
        fetch(25'h04000, 0);
        if (lines > 1) fetch(25'h04008, 0);
        // An odd 286 word becomes an upper-lane transfer then a lower-lane
        // transfer; the physical owner aligns each transfer independently.
        write_bytes(3, 25'h04007, 2, 16'h3400);
        if (lines > 1) fetch(25'h04008, 1);
        write_bytes(3, 25'h04008, 1, 16'h0012);
        fetch(25'h04006, 0);
        fetch(25'h04008, 0);
        fetch(25'h0400A, 1);
        // Zero lanes cannot invalidate or change data.
        write_bytes(1, 25'h04008, 0, 16'hFFFF);
        fetch(25'h04008, 1);
        write_bytes(0, 25'h09000, 3, 16'h67AB);
        fetch(25'h04008, 1);

        // No BIOS alias reinterpretation is permitted on canonical addresses.
        invalidate_all();
        fetch(25'h00F0000, 0);
        write_bytes(1, 25'h0FF0000, 3, 16'h98DC);
        fetch(25'h00F0000, 1);
        fetch(25'h0FF0000, 0);
        fetch(25'h0FF0002, 1);

`ifdef PCAT_PRODUCTION_CODE_BUFFER
        // Explicit same-index/tag-low-bit collision across physical bit 24.
        // A tag must distinguish shifted high RAM from its lower counterpart.
        invalidate_all();
        fetch(25'h0101000, 0);
        fetch(25'h1101000, 0);
        fetch(25'h0101002, 0);
        fetch(25'h0101004, 1);
`endif

        // All non-code owners and holes bypass, even on an existing line.
        bypass_read(0, 0, 25'h0FF0000, 3);
        bypass_read(1, 1, 25'h0FF0000, 3);
        bypass_read(2, 1, 25'h0FF0000, 3);
        bypass_read(3, 1, 25'h0FF0000, 3);
        bypass_read(0, 1, 25'h0FF0000, 0);
        bypass_read(0, 1, 25'h00A0000, 3);
        bypass_read(0, 1, 25'h00EFFF8, 3);
        bypass_read(0, 1, 25'h11E0000, 3);
        bypass_read(0, 1, 25'h1FFFFF8, 3);
        commands_before = commands;
        beats_before = read_beats;
        begin_request(2, 0, 1, 0, 25'h1234, 0, 0);
        finish_request(0, 0);
        check(commands == commands_before + 1 && read_beats == beats_before,
              "refresh did not complete without read data");

        // Dynamic disable and compile-time disable must never use cache data.
        enable = 0;
        fetch(25'h06000, 0);
        fetch(25'h06002, 0);
        write_bytes(1, 25'h06002, 3, 16'hDDCC);
        fetch(25'h06002, 0);
        enable = 1;
        invalidate_all();
        fetch(25'h06002, 0);
        fetch(25'h06004, 1);

        // CPU cancellation never blocks DMA or loader ownership.
        cancel_cpu = 1;
        write_bytes(1, 25'h07000, 3, 16'hA55A);
        write_bytes(3, 25'h07002, 3, 16'hC33C);
        bypass_read(1, 0, 25'h07000, 3);
        bypass_read(3, 0, 25'h07002, 3);
        // CPU commands are refused while cancellation is already asserted.
        @(negedge clk);
        in_owner = 0;
        in_write = 0;
        in_refresh = 0;
        in_code_fetch = 1;
        in_address = 25'h07000;
        in_byte_enable = 3;
        in_valid = 1;
        in_command_valid = 1;
        repeat (4) begin
            @(negedge clk);
            check(!in_accept && !out_command_valid && !in_ready,
                  "CPU request accepted while already cancelled");
        end
        in_valid = 0;
        in_command_valid = 0;
        cancel_cpu = 0;

        // Cancel before each of the four physically accepted fill beats.
        if (ENABLE) begin
`ifdef PCAT_PRODUCTION_CODE_BUFFER
            if (SYNC_TAGS) begin
                // Cancellation after local lookup acceptance, before any
                // physical command is accepted, must never launch a fill.
                invalidate_all();
                commands_before = commands;
                beats_before = read_beats;
                begin_request(0, 0, 0, 1, 25'h0C006, 3, 0);
                cancel_cpu = 1;
                finish_request(1, 16'hFFFF);
                check(commands == commands_before && read_beats == beats_before,
                      "cancelled tag lookup launched a physical command");
                cancel_cpu = 0;
                fetch(25'h0C006, 0);
                fetch(25'h0C000, 1);
            end
`endif
            for (integer cancel_beat = 0; cancel_beat < 4; cancel_beat = cancel_beat + 1) begin
                invalidate_all();
                fetch(25'h08000, 0);
                commands_before = commands;
                beats_before = read_beats;
                begin_request(0, 0, 0, 1, 25'h0A006 + 25'(cancel_beat * 8), 3, 0);
                while (!(backend_active && backend_beat == cancel_beat && response_delay == 1))
                    @(negedge clk);
                cancel_cpu = 1;
                finish_request(1, 16'hFFFF);
                check(commands == commands_before + 1 && read_beats == beats_before + 4,
                      "cancelled burst did not fully drain its four accepted beats");
                cancel_cpu = 0;
                fetch(25'h08000, 0);
                fetch(25'h0A000 + 25'(cancel_beat * 8), 0);
                fetch(25'h0A002 + 25'(cancel_beat * 8), 1);
            end
        end

        // Reset during an accepted transaction resets both ends of the port.
        invalidate_all();
        begin_request(0, 0, 0, 1, 25'h0B000, 3, 0);
        reset = 1;
        in_valid = 0;
        repeat (3) @(negedge clk);
        reset = 0;
        fetch(25'h0B000, 0);
        fetch(25'h0B002, 1);
        $display("MULTILINE_COHERENCE_PASS lines=%0d ways=%0d extra=%0d ENABLE=%0d requests=%0d checks=%0d commands=%0d read_beats=%0d writes=%0d",
                 lines, ways, extra, ENABLE, requests, checks, commands, read_beats, write_commands);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "multiline test watchdog expired");
    end
endmodule
