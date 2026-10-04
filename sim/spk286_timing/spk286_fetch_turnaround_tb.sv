`timescale 1ns/1ps

// Directed transaction/queue checks for an explicitly reserved READY chain.
// No timing table, instruction semantics or historical deadline is substituted.
module spk286_fetch_turnaround_tb;
    logic clk = 0, reset = 1, ready = 0;
    logic [15:0] data_in = 0;
    logic [23:0] code_base = 0;
    logic [15:0] code_limit = 16'hffff;
    logic wrap_ip = 0, restart = 0;
    logic [15:0] restart_ip = 0;
    logic request_manual = 0, chain_manual = 0, suspend = 0;
    logic response_manual = 0, queue_mode = 0, response_stall = 0;
    logic consume_ready = 0;
    wire request, chain_request, response_ready;
    wire request_ready, response_valid, blocked, bus_valid, bus_bhe_n;
    wire [15:0] response_data, response_ip;
    wire [1:0] response_count;
    wire [16:0] cursor;
    wire [23:0] address;
    wire fill_ready, consume_valid;
    wire [7:0] consume_data;
    wire [3:0] queue_count;
    wire [4:0] queue_reserved = {1'b0, queue_count} +
        (response_valid ? {3'b0, response_count} : 5'd0) +
        (bus_valid ? 5'd2 : 5'd0);
    assign request = queue_mode ? (queue_reserved <= 4) :
        (request_manual && (!(bus_valid && ready) || chain_manual));
    // No speculative credit for a simultaneous EU consume. Both current and
    // next CODE beats may be words, so four free bytes must be reserved.
    // This trace signal is caller permission, not an additional DUT port.
    assign chain_request = queue_mode ? (queue_reserved <= 4) : chain_manual;
    assign response_ready = queue_mode ? (fill_ready && !response_stall) : response_manual;

    spk286_fetch #(.READY_CHAINING(1'b1)) dut (.*);
    spk286_prefetch_queue queue (
        .clk(clk), .reset(reset), .flush(restart),
        .fill_valid(queue_mode && response_valid && !response_stall && !restart),
        .fill_data(response_data), .fill_count(response_count), .fill_ready(fill_ready),
        .consume_valid(consume_valid), .consume_data(consume_data),
        .consume_ready(queue_mode && consume_ready && !restart), .count(queue_count)
    );

    integer checks = 0, cycles = 0, cases = 0;
    integer completed = 0, delivered = 0, stale_drained = 0;
    integer ready_chains = 0, hidden_cycles = 0, queue_consumes = 0;
    integer reference_cursor = 32'h0000fff0;
    integer active_ip = 0, active_count = 0;
    logic active_seen = 0, active_canceled = 0;
    logic [23:0] active_address = 0;
    logic active_bhe = 1;
    integer pending_count = 0, pending_ip = 0;
    logic [15:0] pending_data = 0;
    logic [7:0] model_bytes [0:4095];
    integer model_head = 0, model_tail = 0, model_count = 0;
    integer trace_fd = 0;
    string trace_path;
    integer require_chain = 1;

    task automatic check(input logic condition, input string message);
        if (condition !== 1'b1)
            $fatal(1, "%s case=%0d cycle=%0d bus=%b address=%h cursor=%h response=%b/%h/%0d queue=%0d",
                message, cases, cycles, bus_valid, address, cursor,
                response_valid, response_ip, response_count, queue_count);
        checks = checks + 1;
    endtask

    task automatic case_done(input string name);
        cases = cases + 1;
        $display("FETCH_TURNAROUND_CASE %0d %s", cases, name);
    endtask

    // This scoreboard derives bytes and metadata from accepted physical CODE
    // beats, not from fetch internal response storage. A blocked response is
    // compared every edge, and its expected payload cannot be overwritten.
    task automatic tick;
        logic complete_now, consume_response, consume_byte;
        logic [15:0] completed_data;
        integer completed_count, completed_ip;
        logic old_visible;
        logic [23:0] old_address;
        logic old_bhe;
        integer reserved_after;
        begin
            #2;
            old_visible = bus_valid;
            old_address = address;
            old_bhe = bus_bhe_n;
            complete_now = bus_valid && ready;
            consume_response = response_valid && response_ready;
            consume_byte = queue_mode && consume_valid && consume_ready;
            completed_data = 0;
            completed_count = 0;
            completed_ip = 0;
            if (!reset) begin
                if (bus_valid && !active_seen) begin
                    active_seen = 1;
                    active_address = address;
                    active_bhe = bus_bhe_n;
                    active_ip = reference_cursor & 65535;
                    active_count = (address[0] || bus_bhe_n) ? 1 : 2;
                    check(address == code_base + 24'(reference_cursor & 65535),
                          "new physical request did not use the reference cursor");
                end
                if (bus_valid && active_seen)
                    check(address == active_address && bus_bhe_n == active_bhe,
                          "active CODE address/lane changed before READY");
            end
            if (!reset && !restart) begin
                if (complete_now && !active_canceled) begin
                    completed_count = active_count;
                    completed_ip = active_ip;
                    completed_data = active_count == 2 ? data_in :
                        (address[0] ? {8'd0, data_in[15:8]} : {8'd0, data_in[7:0]});
                end
                if (response_valid) begin
                    check(pending_count != 0, "response has no accepted physical CODE predecessor");
                    check(response_ip == 16'(pending_ip) && response_count == 2'(pending_count) &&
                          response_data == pending_data,
                          "retained response byte/IP/count changed or reordered");
                end
                if (queue_mode) begin
                    check(int'(queue_count) == model_count, "queue/reference occupancy diverged");
                    if (consume_byte) begin
                        check(model_count != 0 && consume_data == model_bytes[model_head],
                              "queue byte loss, duplication or ordering error");
                        model_head = model_head + 1;
                        model_count = model_count - 1;
                        queue_consumes = queue_consumes + 1;
                    end
                end
                if (consume_response) begin
                    if (queue_mode) begin
                        check(model_count + pending_count <= 6, "six-byte reference queue overflow");
                        model_bytes[model_tail] = pending_data[7:0];
                        model_tail = model_tail + 1;
                        if (pending_count == 2) begin
                            model_bytes[model_tail] = pending_data[15:8];
                            model_tail = model_tail + 1;
                        end
                        model_count = model_count + pending_count;
                    end
                    pending_count = 0;
                    delivered = delivered + 1;
                end
                if (complete_now) begin
                    active_seen = 0;
                    if (active_canceled) begin
                        active_canceled = 0;
                        stale_drained = stale_drained + 1;
                    end else begin
                        check(pending_count == 0, "READY overwrote an unconsumed response slot");
                        pending_count = completed_count;
                        pending_ip = completed_ip;
                        pending_data = completed_data;
                        reference_cursor = completed_ip + completed_count;
                        if (wrap_ip) reference_cursor = reference_cursor & 65535;
                        completed = completed + 1;
                    end
                end
            end
            if (trace_fd != 0)
                $fdisplay(trace_fd, "%0d,%0d,%0d,%0d,%0d,%06h,%0d,%0d,%0d,%0d,%04h,%0d,%04h,%0d,%0d,%0d,%0d",
                    cycles, cases, reset, restart, bus_valid, address, bus_bhe_n,
                    ready, request, chain_request, response_ip, response_count,
                    response_data, response_valid, response_ready, queue_count, pending_count);
            #3; clk = 1;
            #2;
            if (reset) begin
                reference_cursor = 32'h0000fff0;
                active_seen = 0; active_canceled = 0; pending_count = 0;
                model_head = 0; model_tail = 0; model_count = 0;
                check(!bus_valid && !response_valid, "reset retained fetch activity");
            end else if (restart) begin
                reference_cursor = int'(restart_ip);
                pending_count = 0;
                model_head = 0; model_tail = 0; model_count = 0;
                if (old_visible && !ready) active_canceled = 1;
                else begin active_seen = 0; active_canceled = 0; end
                check(!response_valid, "restart did not invalidate retained response");
            end else begin
                if (old_visible && !ready)
                    check(bus_valid && address == old_address && bus_bhe_n == old_bhe,
                          "READY-low transfer was dropped or altered");
                if (queue_mode) begin
                    reserved_after = int'(queue_count) +
                        (response_valid ? int'(response_count) : 0) +
                        ((dut.active_q && !dut.canceled_q) ? int'(dut.request_count_q) : 0);
                    check(reserved_after <= 6, "queue+response+prepared CODE reservations exceed six bytes");
                end
                if (!bus_valid && dut.active_q && response_valid && !response_ready)
                    hidden_cycles = hidden_cycles + 1;
            end
            #3; clk = 0;
            #1; cycles = cycles + 1;
            if (cycles > 12000) $fatal(1, "bounded fetch bank timeout");
        end
    endtask

    task automatic fresh(input logic [23:0] base, input logic [15:0] ip,
                         input logic [15:0] limit_value, input logic real_wrap);
        begin
            queue_mode = 0; response_stall = 0; consume_ready = 0;
            request_manual = 0; chain_manual = 0; response_manual = 0;
            ready = 0; restart = 0; suspend = 1; reset = 1;
            code_base = base; code_limit = limit_value; wrap_ip = real_wrap;
            tick();
            reset = 0; restart = 1; restart_ip = ip;
            tick();
            restart = 0; suspend = 0;
            tick();
        end
    endtask

    task automatic expect_bus(input logic [23:0] expected_address, input logic expected_bhe);
        #1;
        check(bus_valid && address == expected_address && bus_bhe_n == expected_bhe,
              "physical fetch address/lane mismatch");
    endtask

    task automatic drain_response;
        begin
            ready = 0; request_manual = 0; chain_manual = 0;
            response_manual = 1;
            tick();
            response_manual = 0;
            check(!response_valid && pending_count == 0, "response did not retire exactly once");
        end
    endtask

    // A chained request is visible immediately after the completing edge when
    // the retained response can be consumed. The old RTL deliberately fails
    // this performance assertion under REQUIRE_CHAIN=1.
    task automatic finish_and_chain(input logic [15:0] payload,
                                    input logic [23:0] next_addr, input logic next_bhe);
        begin
            data_in = payload; ready = 1;
            request_manual = 1; chain_manual = 1; response_manual = 1;
            tick();
            ready = 0; request_manual = 0; chain_manual = 0;
            #1;
            if (require_chain != 0) begin
                expect_bus(next_addr, next_bhe);
                ready_chains = ready_chains + 1;
            end else begin
                // Functional baseline: retire old response and admit the next
                // request on its original later edge; no timing result tuned.
                request_manual = 1;
                tick();
                request_manual = 0;
                expect_bus(next_addr, next_bhe);
            end
        end
    endtask

    initial begin
        if (!$value$plusargs("REQUIRE_CHAIN=%d", require_chain)) require_chain = 1;
        if ($value$plusargs("TRACE=%s", trace_path)) begin
            trace_fd = $fopen(trace_path, "w");
            if (trace_fd == 0) $fatal(1, "cannot open fetch trace");
            $fdisplay(trace_fd, "cycle,case,reset,restart,bus_valid,address,bhe_n,ready,request,chain_request,response_ip,response_count,response_data,response_valid,response_ready,queue_count,reference_pending");
        end

        fresh(24'h020000, 16'h0080, 16'hffff, 0);
        expect_bus(24'h020080, 0);
        repeat (5) begin data_in = 16'hdead; tick(); end
        finish_and_chain(16'hbbaa, 24'h020082, 0);
        response_manual = 1; ready = 1; data_in = 16'h2211;
        tick(); ready = 0; drain_response();
        case_done("even_ready_chain_and_response_reuse");

        fresh(24'h020000, 16'h0081, 16'hffff, 0);
        expect_bus(24'h020081, 0);
        finish_and_chain(16'hc75a, 24'h020082, 0);
        response_manual = 1; ready = 1; data_in = 16'ha493;
        tick(); ready = 0; drain_response();
        case_done("odd_upper_lane_then_even_word");

        fresh(24'h020001, 16'h0080, 16'hffff, 0);
        expect_bus(24'h020081, 0);
        finish_and_chain(16'hd86b, 24'h020082, 0);
        response_manual = 1; ready = 1; data_in = 16'hb5a4;
        tick(); ready = 0; drain_response();
        case_done("odd_code_base_lane_and_ip");

        // Permission must be distinct from the ordinary request. No chain is
        // allowed with request low, permission low or suspend asserted.
        for (integer variant = 0; variant < 3; variant = variant + 1) begin
            fresh(24'h010000, 16'h0100, 16'hffff, 0);
            request_manual = variant != 0;
            chain_manual = variant != 1;
            suspend = variant == 2;
            ready = 1; data_in = 16'h3412; response_manual = 1;
            tick(); ready = 0;
            check(!bus_valid && !dut.active_q, "missing request/grant or suspend admitted a chain");
            suspend = 0; drain_response();
        end
        case_done("request_grant_suspend_gates");

        // Start a reserved next request, then withdraw consumer acceptance.
        // READY may remain high but the prepared request must be invisible.
        fresh(24'h030000, 16'h0020, 16'hffff, 0);
        finish_and_chain(16'h7654, 24'h030022, 0);
        response_manual = 0; ready = 1; data_in = 16'hdead;
        repeat (6) begin
            tick();
            check(!bus_valid && response_valid && response_data == 16'h7654,
                  "prepared request exposed or old payload overwritten under backpressure");
        end
        response_manual = 1; data_in = 16'hab89;
        tick(); ready = 0; drain_response();
        case_done("prepared_hidden_backpressure_unsolicited_ready");

        // Redirect while prepared but invisible must discard that request.
        fresh(24'h040000, 16'h0040, 16'hffff, 0);
        finish_and_chain(16'h9876, 24'h040042, 0);
        response_manual = 0; ready = 0;
        restart = 1; restart_ip = 16'h0081;
        tick(); restart = 0; code_base = 24'h050000;
        response_manual = 1;
        tick(); expect_bus(24'h050081, 0);
        ready = 1; data_in = 16'hca53; tick(); ready = 0; drain_response();
        case_done("restart_discards_invisible_prepared_request");

        // A visible outstanding transfer survives cancellation until READY.
        fresh(24'h060000, 16'h0060, 16'hffff, 0);
        request_manual = 1; chain_manual = 1;
        restart = 1; restart_ip = 16'h0100;
        tick(); restart = 0; code_base = 24'h070000;
        repeat (3) begin tick(); expect_bus(24'h060060, 0); end
        restart = 1; restart_ip = 16'h0201; tick(); restart = 0;
        code_base = 24'h080000; ready = 1; data_in = 16'hdead;
        tick(); ready = 0;
        check(!response_valid && cursor == 17'h00201, "canceled READY modified the redirected stream");
        request_manual = 0; chain_manual = 0;
        tick(); expect_bus(24'h080201, 0);
        ready = 1; data_in = 16'hdc65; tick(); ready = 0; drain_response();
        case_done("visible_cancel_drain_latest_restart");

        fresh(24'h090000, 16'h0080, 16'hffff, 0);
        restart = 1; restart_ip = 16'h0101;
        request_manual = 1; chain_manual = 1;
        ready = 1; data_in = 16'hdead;
        tick(); restart = 0; ready = 0; code_base = 24'h0a0000;
        request_manual = 0; chain_manual = 0;
        tick(); expect_bus(24'h0a0101, 0);
        ready = 1; data_in = 16'hed76; tick(); ready = 0; drain_response();
        case_done("restart_ready_chain_priority");

        for (integer odd_limit = 0; odd_limit < 2; odd_limit = odd_limit + 1) begin
            fresh(24'h000000, (odd_limit != 0) ? 16'h0101 : 16'h0100,
                  (odd_limit != 0) ? 16'h0101 : 16'h0100, 0);
            expect_bus((odd_limit != 0) ? 24'h000101 : 24'h000100, odd_limit == 0);
            ready = 1; data_in = 16'hfe87;
            request_manual = 1; chain_manual = 1; response_manual = 1;
            tick(); ready = 0;
            check(blocked && !bus_valid && !dut.active_q, "READY chain crossed code_limit");
            drain_response();
        end
        case_done("last_even_odd_byte_limit_blocks_chain");

        fresh(24'h010000, 16'hfffe, 16'hffff, 0);
        ready = 1; data_in = 16'h5432; request_manual = 1;
        chain_manual = 1; response_manual = 1;
        tick(); ready = 0;
        check(cursor == 17'h10000 && blocked && !bus_valid && !dut.active_q,
              "protected word overflow was silently wrapped by chain");
        drain_response(); case_done("protected_word_overflow");

        fresh(24'h010000, 16'hfffe, 16'hffff, 1);
        finish_and_chain(16'h6543, 24'h010000, 0);
        response_manual = 1; ready = 1; data_in = 16'h8765;
        tick(); ready = 0; drain_response();
        case_done("real_word_wrap_ready_chain");

        fresh(24'h010000, 16'hffff, 16'hffff, 1);
        finish_and_chain(16'h7654, 24'h010000, 0);
        response_manual = 1; ready = 1; data_in = 16'h9876;
        tick(); ready = 0; drain_response();
        case_done("real_odd_byte_wrap_ready_chain");

        fresh(24'h010000, 16'hffff, 16'hffff, 0);
        ready = 1; data_in = 16'h8765; request_manual = 1;
        chain_manual = 1; response_manual = 1;
        tick(); ready = 0;
        check(cursor == 17'h10000 && blocked && !bus_valid && !dut.active_q,
              "protected odd-byte overflow allowed a chained request");
        drain_response(); case_done("protected_odd_byte_overflow");

        fresh(24'h010000, 16'h0200, 16'h0201, 0);
        ready = 1; data_in = 16'h9876; request_manual = 1;
        chain_manual = 1; response_manual = 1; reset = 1;
        tick(); reset = 0; ready = 0; suspend = 1;
        request_manual = 0; chain_manual = 0; response_manual = 0;
        tick(); check(!bus_valid && !response_valid, "reset allowed a prepared chain to escape");
        case_done("reset_ready_chain_priority");

        fresh(24'h0b0000, 16'h0240, 16'hffff, 0);
        finish_and_chain(16'hba98, 24'h0b0242, 0);
        response_manual = 0; ready = 1; suspend = 1;
        repeat (3) tick();
        check(!bus_valid && response_valid && response_data == 16'hba98,
              "suspend changed a blocked retained response");
        ready = 0; response_manual = 1; tick();
        expect_bus(24'h0b0242, 0);
        ready = 1; data_in = 16'hdcba; tick(); ready = 0;
        check(!dut.active_q, "suspend admitted another early request");
        drain_response();
        case_done("suspend_retains_prepared_transfer_without_new_admission");

        // Production six-byte queue plus conservative caller. Distinct bytes
        // are derived from each physical address. Alternate stalls and pops
        // cover simultaneous consume/fill, prepared requests and pointer wrap.
        for (integer alignment = 0; alignment < 2; alignment = alignment + 1) begin
            fresh(24'h000000, (alignment != 0) ? 16'h0301 : 16'h0300, 16'hffff, 0);
            queue_mode = 1; response_manual = 0;
            for (integer step = 0; step < 320; step = step + 1) begin
                ready = bus_valid && ((step % 5) != 2);
                data_in = {8'(address[7:0] | 8'h01), 8'(address[7:0] & 8'hfe)};
                consume_ready = step >= 16 && ((step % 3) != 1);
                response_stall = (step % 13) >= 9;
                tick();
            end
            suspend = 1; response_stall = 0; consume_ready = 1; ready = 1;
            repeat (16) begin
                data_in = {8'(address[7:0] | 8'h01), 8'(address[7:0] & 8'hfe)};
                tick();
            end
            check(queue_count == 0 && model_count == 0 && !response_valid,
                  "reserved queue pipeline failed to drain");
            queue_mode = 0;
        end
        case_done("reserved_six_byte_queue_even_odd_streams");

        check(completed > 80 && delivered > 80 && queue_consumes > 200,
              "directed queue bank has insufficient accepted byte coverage");
        if (require_chain != 0) check(ready_chains >= 7 && hidden_cycles >= 6,
                                 "new READY chaining or hidden backpressure path was not exercised");
        if (trace_fd != 0) $fclose(trace_fd);
        $display("FETCH_TURNAROUND_PASS cases=%0d checks=%0d cycles=%0d completed=%0d delivered=%0d stale=%0d ready_chains=%0d hidden=%0d queue_bytes=%0d require_chain=%0d",
            cases, checks, cycles, completed, delivered, stale_drained,
            ready_chains, hidden_cycles, queue_consumes, require_chain);
        $finish;
    end
endmodule
