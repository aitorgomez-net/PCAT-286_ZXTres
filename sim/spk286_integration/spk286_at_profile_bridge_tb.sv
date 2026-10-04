`timescale 1ns/1ps
// A level-held CPU and pulse-only backend, with independent fabric latency.
module spk286_at_profile_bridge_tb;
    logic clk = 0, reset = 1;
    always #10 clk = ~clk;
    logic [2:0] requested = 0;
    wire [2:0] active;
    wire historical, boundary;
    spk286_at_cpu_profile profile (
        .clk(clk), .reset(reset), .requested(requested), .active(active),
        .pending(), .historical(historical), .phase_enable(), .phase_two(),
        .cpu_boundary(boundary)
    );
    logic valid = 0, write_cycle = 0, bhe_n = 0, locked = 0;
    logic memory_width = 1, drain_pending = 0;
    logic [23:0] address = 24'h100;
    logic [15:0] data = 16'h9876;
    logic [3:0] status = 4'h5;
    wire ready, idle, error_flag, command, accepted, completed, response;
    wire at_write, at_lock, at_valid, at_inta, miss;
    wire [15:0] result, at_data;
    wire [23:0] at_address;
    wire [1:0] lanes;
    wire [3:0] state;
    logic backend_pending = 0;
    integer delay_count = 0, latency = 1;
    wire accept = command && !backend_pending;
    wire backend_ready = backend_pending && delay_count == 0;
    spk286_at_bus_bridge dut (
        .clk(clk), .reset(reset), .cpu_sample_edge(1'b1),
        .timing_historical(historical), .timing_cpu_boundary(boundary),
        .timing_deadline_miss(miss),
        .cpu_bus_valid(valid), .cpu_address(address), .cpu_data_out(data),
        .cpu_data_oe(write_cycle), .cpu_bus_write(write_cycle),
        .cpu_bus_bhe_n(bhe_n), .cpu_bus_status(status), .cpu_bus_lock(locked),
        .memory_drain_pending(drain_pending), .cpu_memory_word_capable(memory_width),
        .cpu_io_word_capable(1'b0), .cpu_ready(ready), .cpu_data_in(result),
        .at_valid(at_valid), .at_command_valid(command), .at_owner(),
        .at_cycle_class(), .at_address(at_address), .at_a0(), .at_bhe_n(),
        .at_byte_enable(lanes), .at_data_out(at_data), .at_data_oe(),
        .at_write(at_write), .at_io(), .at_inta(at_inta), .at_code_fetch(),
        .at_lock(at_lock), .at_accepted(accepted), .at_completed(completed),
        .at_response_valid(response), .at_accept(accept), .at_ready(backend_ready),
        .at_read_data(16'hC35A), .at_read_data_valid(backend_ready),
        .bridge_idle(idle), .debug_state(state), .retained_io_command(),
        .retained_io_address(), .retained_io_write(), .retained_io_byte_enable(),
        .retained_io_data_out(), .retained_io_data_oe(), .protocol_error(error_flag)
    );
    integer clocks = 0, ticks = 0, ts_tick = 0;
    integer commands = 0, captures = 0, publications = 0, writes = 0, misses = 0;
    integer checks = 0, cases = 0;
    logic [15:0] sampled = 0;
    always @(posedge clk) begin
        clocks = clocks + 1;
        if (reset) begin
            backend_pending <= 0;
            delay_count <= 0;
            ticks = 0;
        end else begin
            if (boundary) ticks = ticks + 1;
            if (state == 0 && valid && (!historical || boundary || dut.timing_admission_window_q) && !drain_pending)
                ts_tick = ticks;
            if (accept) begin
                backend_pending <= 1;
                delay_count <= latency;
                commands = commands + 1;
                if (at_write) writes = writes + 1;
            end else if (backend_pending && delay_count > 0)
                delay_count <= delay_count - 1;
            if (backend_ready) backend_pending <= 0;
            if (completed) captures = captures + 1;
            if (miss) misses = misses + 1;
            if (valid && ready) begin
                publications = publications + 1;
                sampled = result;
                if (historical && (!boundary || ticks - ts_tick < 2))
                    $fatal(1, "Early/nonboundary publication profile=%0d elapsed=%0d", active, ticks-ts_tick);
                if (!response || idle || (locked && !at_lock))
                    $fatal(1, "Publication lost owner/response/LOCK");
            end
            if (error_flag) $fatal(1, "Unexpected bridge protocol error");
            if (locked && state != 0 && !at_lock)
                $fatal(1, "LOCK lost during physical/logical retention");
        end
    end
    task automatic check(input bit condition, input string label_text);
        checks = checks + 1;
        if (!condition) $fatal(1, "PROFILE_BRIDGE_FAIL %s", label_text);
    endtask
    task automatic reset_retained_response;
        integer timeout_count, old_publications;
        begin
            if (historical) begin
                @(negedge clk);
                status = 4'h5; write_cycle = 0; memory_width = 1;
                address = 24'h102; bhe_n = 0; locked = 0; latency = 0;
                valid = 1; timeout_count = 0; old_publications = publications;
                while (state != 6 && timeout_count < 500) begin
                    @(negedge clk); timeout_count = timeout_count + 1;
                end
                check(state == 6 && !ready, "physical response retained before Tc");
                reset = 1; valid = 0;
                repeat (3) @(negedge clk);
                reset = 0;
                repeat (15) @(negedge clk);
                check(publications == old_publications && idle && !ready,
                      "reset cancels retained logical publication without replay");
            end
        end
    endtask
    task automatic drain_barrier_test;
        integer old_commands;
        begin
            @(negedge clk);
            status = 4'h9; write_cycle = 0; memory_width = 0;
            address = 24'h60; bhe_n = 1; locked = 0; valid = 1;
            drain_pending = 1; old_commands = commands;
            repeat (25) @(negedge clk);
            check(commands == old_commands && !ready && !idle,
                  "posted writes drain before peripheral admission");
            valid = 0; drain_pending = 0;
            repeat (3) @(negedge clk);
            check(idle && !ready, "withdraw unaccepted request after barrier");
        end
    endtask
    // The real BIU may hold valid high and replace its payload only after
    // sampling READY. Identical adjacent requests are distinct transactions.
    task automatic consecutive_reads;
        integer old_publications, old_commands, old_captures, timeout_count;
        integer terminal_tick, first_admission_tick;
        begin
            @(negedge clk);
            status = 4'h5; write_cycle = 0; memory_width = 1;
            address = 24'h100; bhe_n = 0; locked = 1; latency = 0;
            old_commands = commands; old_captures = captures;
            valid = 1;
            for (integer n = 0; n < 8; n = n + 1) begin
                old_publications = publications;
                timeout_count = 0;
                while (publications == old_publications && timeout_count < 500) begin
                    @(negedge clk); timeout_count = timeout_count + 1;
                end
                check(publications == old_publications+1, "consecutive request publication");
                check(sampled == 16'hC35A, "identical request data");
                if (historical && n > 0)
                    check(ts_tick == terminal_tick, "next Ts has no inserted idle CPU clock");
                terminal_tick = ticks;
                first_admission_tick = ts_tick;
                check(!historical || terminal_tick-first_admission_tick == 2,
                      "fast retained RAM takes exactly Ts plus Tc");
                // valid/address intentionally remain identical across READY.
            end
            valid = 0; locked = 0;
            repeat (3) @(negedge clk);
            check(commands-old_commands == 8 && captures-old_captures == 8,
                  "identical requests accepted/captured once each");
            cases = cases + 8;
        end
    endtask
    task automatic transfer(input integer delay_cycles, input logic [3:0] cycle_class,
                            input bit native_memory, input bit odd_address,
                            input bit byte_request, input bit lock_request);
        integer old_commands, old_captures, old_publications, old_writes, timeout_count;
        integer expected_beats;
        logic [15:0] expected_data;
        begin
            @(negedge clk);
            latency = delay_cycles;
            status = cycle_class;
            write_cycle = cycle_class == 4'h6 || cycle_class == 4'hA;
            memory_width = native_memory;
            address = odd_address ? 24'h101 : 24'h100;
            bhe_n = byte_request && !odd_address;
            locked = lock_request;
            expected_beats = (!native_memory && !odd_address && !byte_request && cycle_class != 0) ? 2 : 1;
            expected_data = cycle_class == 0 ? 16'h005A : odd_address ? 16'hC300 :
                            byte_request ? 16'h005A : 16'hC35A;
            old_commands = commands; old_captures = captures;
            old_publications = publications; old_writes = writes;
            valid = 1;
            timeout_count = 0;
            while (publications == old_publications && timeout_count < 1500) begin
                @(negedge clk);
                timeout_count = timeout_count + 1;
            end
            check(publications == old_publications + 1, "one publication per held request");
            check(commands - old_commands == expected_beats, "accepted beat count");
            check(captures - old_captures == expected_beats, "physical capture count");
            check(writes - old_writes == (write_cycle ? expected_beats : 0), "no duplicate write effect");
            if (!write_cycle) check(sampled == expected_data, "retained lane/read data");
            valid = 0; locked = 0;
            repeat (3) @(negedge clk);
            check(idle && !ready, "owner released after publication");
            cases = cases + 1;
        end
    endtask
    integer p, offset;
    initial begin
        for (p = 0; p < 8; p = p + 1) begin
            @(negedge clk); reset = 1; requested = 3'(p); valid = 0;
            repeat (3) @(negedge clk);
            reset = 0;
            check(active == 3'(p), "profile applied at reset");
            reset_retained_response();
            drain_barrier_test();
            consecutive_reads();
            for (offset = 0; offset < 21; offset = offset + 1) begin
                transfer(offset, 4'hD, 1, 0, 0, 0);
                transfer(offset, 4'h5, 1, 0, 0, 1);
                transfer(offset, 4'h6, 1, 0, 0, 1);
                transfer(offset, 4'h5, 1, 1, 1, 0);
                transfer(offset, 4'h5, 0, 0, 0, 0);
                transfer(offset, 4'h9, 0, 0, 0, 0);
                transfer(offset, 4'hA, 0, 0, 0, 0);
                transfer(offset, 4'h0, 0, 0, 1, 1);
                transfer(offset, 4'h0, 0, 0, 1, 1);
            end
        end
        check(misses > 0, "late backend completions exercised");
        $display("AT_PROFILE_BRIDGE_PASS cases=%0d checks=%0d commands=%0d captures=%0d publications=%0d misses=%0d", cases,checks,commands,captures,publications,misses);
        $finish;
    end
    initial begin
        #100000000;
        $fatal(1, "Profile bridge global timeout");
    end
endmodule
