// Hot profile changes use real CPU and AT bridge; program signatures are
// independent fixture constants. No internal state is forced.
`timescale 1ns/1ps
module spk286_profile_live_integration_tb;
    // The runner copies this public-port header and removes initialization
    // only from the two inputs driven by the real AT bridge below.
    `include "spk286_signals.svh"
    logic [7:0] memory [0:65535];
    logic [2:0] requested_profile = 0;
    wire [2:0] active_profile;
    wire historical_enable, cpu_boundary, phase_enable, phase_two;
    wire profile_pending, profile_change_ready;
    logic memory_drain_pending = 0;
    wire bridge_idle;
    wire profile_apply = profile_change_ready && bridge_idle && !memory_drain_pending;
    wire at_valid, at_command_valid, at_accepted, at_completed;
    wire [23:0] at_address;
    wire [15:0] at_data_out;
    wire [1:0] at_byte_enable;
    wire at_write, at_io, at_inta, protocol_error;
    logic at_accept = 0, at_ready = 0, at_read_data_valid = 0;
    logic [15:0] at_read_data = 0;
    logic backend_pending = 0;
    logic [23:0] accepted_address;
    logic [15:0] accepted_data;
    logic [1:0] accepted_lanes;
    logic accepted_write, accepted_inta;
    integer backend_age = 0, latency = 0, cases = 0, checks = 0;
    integer old_mode = 0, new_mode = 0, kind = 0, switches = 0;
    integer store_count = 0, transfers = 0, completions = 0, events = 0;
    integer applied_replay = 0, replay_cases = 0, pending_bus_cases = 0;
    integer edge_count = 0, wait_start = 0, irq_acks = 0;
    logic live_running = 0;
    integer debug_argument = 0;

    spk286_at_cpu_profile profile_clock (
        .clk(clk), .reset(reset), .apply(profile_apply), .requested(requested_profile),
        .active(active_profile), .pending(profile_pending), .historical(historical_enable),
        .phase_enable(phase_enable), .phase_two(phase_two), .cpu_boundary(cpu_boundary));
    spk286_profiled dut (.profile_change_pending(profile_pending),
        .profile_change_ready(profile_change_ready), .timing_read_wait_event(1'b0), .*);
    spk286_at_bus_bridge bridge (
        .clk(clk), .reset(reset), .cpu_sample_edge(1'b1),
        .timing_historical(historical_enable), .timing_cpu_boundary(cpu_boundary),
        .timing_deadline_miss(), .cpu_bus_valid(bus_valid), .cpu_address(address),
        .cpu_data_out(data_out), .cpu_data_oe(data_oe), .cpu_bus_write(bus_write),
        .cpu_bus_bhe_n(bus_bhe_n), .cpu_bus_status(bus_status), .cpu_bus_lock(bus_lock),
        .memory_drain_pending(memory_drain_pending),
        .cpu_memory_word_capable(1'b1), .cpu_io_word_capable(1'b0),
        .cpu_ready(ready), .cpu_data_in(data_in),
        .at_valid(at_valid), .at_command_valid(at_command_valid), .at_owner(),
        .at_cycle_class(), .at_address(at_address), .at_a0(), .at_bhe_n(),
        .at_byte_enable(at_byte_enable), .at_data_out(at_data_out), .at_data_oe(),
        .at_write(at_write), .at_io(at_io), .at_inta(at_inta), .at_code_fetch(), .at_lock(),
        .at_accepted(at_accepted), .at_completed(at_completed), .at_response_valid(),
        .at_accept(at_accept), .at_ready(at_ready), .at_read_data(at_read_data),
        .at_read_data_valid(at_read_data_valid), .bridge_idle(bridge_idle), .debug_state(),
        .retained_io_command(), .retained_io_address(), .retained_io_write(),
        .retained_io_byte_enable(), .retained_io_data_out(), .retained_io_data_oe(),
        .protocol_error(protocol_error));

    task automatic check(input logic value, input string message);
        checks++;
        if (value !== 1'b1)
            $fatal(1, "%s case=%0d old=%0d new=%0d kind=%0d IP=%h op=%h micro=%b ctx=%b scheduler=%b target=%b queue=%0d replay=%0d bus=%b bridge=%0d backend=%b apply=%b",
                message, cases, old_mode, new_mode, kind, debug_ip, debug_opcode,
                dut.micro_active, dut.context_active, dut.profile_active,
                dut.profile_target_pending, debug_prefetch_count, dut.profile_target_replay_count,
                bus_valid, bridge.debug_state, backend_pending, profile_apply);
    endtask
    function automatic logic [15:0] word_at(input integer a);
        word_at = {memory[16'(a + 1)], memory[16'(a)]};
    endfunction
    task automatic putword(input integer a, input integer value);
        memory[16'(a)] = 8'(value); memory[16'(a + 1)] = 8'(value >> 8);
    endtask
    task automatic tick;
        logic accepted, completed, changed;
        #1;
        at_accept = !backend_pending;
        at_ready = backend_pending && backend_age >= latency;
        at_read_data_valid = at_ready;
        at_read_data = accepted_inta ? 16'h3030 : word_at(int'({accepted_address[15:1], 1'b0}));
        #1;
        accepted = at_accepted; completed = at_completed;
        if (debug_argument != 0 && (accepted || completed))
            $display("BUS,%0d,%b,%b,%h,%b,%b,%0d,%0d,%0d", edge_count, accepted, completed,
                     at_address, at_write, reset, transfers, completions, bridge.debug_state);
        changed = !reset && profile_apply && profile_pending;
        if (!reset) begin
            check(!protocol_error && !control_error && !microcode_fault && !shutdown,
                  "CPU/bridge invariants");
            check(debug_prefetch_count <= 6, "six-byte queue bound");
            if (live_running) check(!reset, "hot transition never resets CPU");
            if (profile_change_ready)
                check(!dut.micro_active && !dut.context_active && !dut.event_active &&
                      !dut.profile_active && !bus_valid && !dut.fetch_bus_valid,
                      "safe CPU boundary");
            if (changed) begin
                check(bridge_idle && !backend_pending && !memory_drain_pending,
                      "accepted references and posted writes drain before change");
                check(active_profile == 3'(old_mode), "old mode retained through boundary");
                switches++;
                check(!dut.micro_active && !dut.context_active && !dut.event_active &&
                      !dut.profile_active && !dut.raw_retired && !dut.event_completed &&
                      !dut.profile_target_pending && !bus_valid && !dut.fetch_bus_valid,
                      "changed mode requires complete CPU context boundary");
                applied_replay = int'(dut.profile_target_replay_count);
                if (applied_replay != 0) replay_cases++;
            end
            if (backend_pending) begin
                check(at_valid && at_address == accepted_address &&
                      at_data_out == accepted_data && at_byte_enable == accepted_lanes &&
                      at_write == accepted_write && at_inta == accepted_inta,
                      "accepted backend reference held exactly");
            end
            if (accepted) begin
                check(!backend_pending && !completed, "one outstanding accepted reference");
                accepted_address = at_address; accepted_data = at_data_out;
                accepted_lanes = at_byte_enable; accepted_write = at_write; accepted_inta = at_inta;
                transfers++;
                if (at_write) begin
                    if (at_byte_enable[0]) memory[{at_address[15:1], 1'b0}] = at_data_out[7:0];
                    if (at_byte_enable[1]) memory[{at_address[15:1], 1'b1}] = at_data_out[15:8];
                    if (at_address == 24'h000800) store_count++;
                end
                if (at_inta) begin intr = 0; irq_acks++; end
            end
            if (completed) begin
                check(backend_pending, "completion owns a retained reference"); completions++;
            end
        end
        #3; clk = 1; #5; clk = 0; edge_count++;
        if (reset) begin backend_pending = 0; backend_age = 0; end
        else if (accepted) begin backend_pending = 1; backend_age = 0; end
        else if (completed) begin backend_pending = 0; backend_age = 0; end
        else if (backend_pending) backend_age++;
        if (changed) check(active_profile == 3'(new_mode) && !profile_pending, "new mode applies without reset");
        if (event_completed) events++;
    endtask
    task automatic setup;
        reset = 1; execute_enable = 0; live_running = 0;
        switches = 0; applied_replay = 0; store_count = 0; events = 0;
        transfers = 0; completions = 0; irq_acks = 0;
        requested_profile = 3'(old_mode); memory_drain_pending = 0;
        intr = 0; nmi = 0; hold_request = 0;
        gpr_write_en = 0; flags_write_en = 0; segment_load_en = 0; ip_write_en = 0; redirect = 0;
        tick(); reset = 0;
        for (integer i = 0; i < 8; i++) begin
            gpr_write_en = 1; gpr_write_index = 3'(i);
            gpr_write_data = i == 1 ? 4 : i == 4 ? 16'h1000 : i == 6 ? 16'h0300 : i == 7 ? 16'h0400 : 0;
            tick();
        end
        gpr_write_en = 0; flags_write_en = 1; flags_write_mask = 16'hFFFF;
        flags_write_data = 16'h0202; tick(); flags_write_en = 0;
        for (integer i = 0; i < 4; i++) begin
            segment_load_en = 1; segment_load_index = 2'(i);
            segment_load_selector = i == 0 ? 16'h0200 : i == 3 ? 16'h0100 : 0;
            redirect = i == 1; ip_write_en = i == 1; ip_write_data = 16'h0480; tick();
        end
        segment_load_en = 0; redirect = 0; ip_write_en = 0;
        for (integer a = 'h0480; a < 'h0550; a++) memory[a] = 8'hF4;
        memory['h0480] = 8'hB8; putword('h0481, 'h1234); memory['h0483] = 8'h40;
        memory['h0484] = 8'hE9; putword('h0485, 'h0500 - 'h0487);
        memory['h0500] = 8'h2E; memory['h0501] = 8'hA3; putword('h0502, 'h0800);
        memory['h0504] = 8'hF3; memory['h0505] = 8'hA4;
        memory['h0506] = 8'h50; memory['h0507] = 8'h5B; memory['h0508] = 8'hF4;
        memory['h0509] = 8'h90; memory['h050A] = 8'hF4;
        putword('h0800, 0); putword('h1800, 'hDEAD);
        for (integer i = 0; i < 4; i++) begin memory['h1300 + i] = 8'('hA0 + i); memory['h2400 + i] = 0; end
        putword(2*4, 'h0600); putword(2*4 + 2, 0);
        putword('h30*4, 'h0600); putword('h30*4 + 2, 0);
        memory['h0600] = 8'h42; memory['h0601] = 8'hCF;
        execute_enable = 1; live_running = 1;
    endtask
    task automatic run_case;
        integer watchdog;
        logic inject;
        setup(); watchdog = 0; inject = 0;
        while (!inject && watchdog < 30000) begin
            if (kind == 0)
                inject = old_mode == 0 ? (debug_opcode == 8'hE9 && debug_micro_active) : dut.profile_target_pending;
            else if (kind == 1)
                inject = debug_opcode == 8'hA4 && debug_micro_active && backend_pending;
            else inject = halted;
            if (!inject) begin tick(); watchdog++; end
        end
        check(inject, "request injection milestone reached");
        if (kind == 1) begin
            check(backend_pending, "switch request exercises memory wait"); pending_bus_cases++;
            hold_request = 1;
        end
        if (kind == 2) memory_drain_pending = 1;
        requested_profile = 3'(new_mode); wait_start = edge_count;
        // Delay the motherboard drain barrier while injecting an external
        // event. NMI is a pulse; its pending latch must survive parking.
        if (kind == 2) begin
            if ((old_mode + new_mode) % 2 == 0) intr = 1; else nmi = 1;
        end
        repeat (20) begin
            tick();
            if (kind == 2 && old_mode != new_mode)
                check(active_profile == 3'(old_mode), "posted drain prevents premature change");
        end
        hold_request = 0; nmi = 0; memory_drain_pending = 0;
        watchdog = 0;
        while ((active_profile != 3'(new_mode) || !halted ||
                (kind == 2 && debug_gpr[47:32] != 1)) && watchdog < 50000) begin
            tick(); watchdog++;
        end
        check(watchdog < 50000 && active_profile == 3'(new_mode), "bounded live transition and program completion");
        // Drain final fetch/backend response before counting exact ownership.
        repeat (200) tick();
        check(switches == (old_mode == new_mode ? 0 : 1), "one apply per changed request");
        check(debug_gpr[15:0] == 16'h1235 && debug_gpr[63:48] == 16'h1235 &&
              debug_gpr[79:64] == 16'h1000, "register and stack signature preserved");
        check(word_at('h0800) == 16'h1235 && word_at('h1800) == 16'hDEAD && store_count == 1,
              "replayed target instruction executes once with CS override");
        check(debug_gpr[31:16] == 0 && debug_gpr[111:96] == 16'h0304 &&
              debug_gpr[127:112] == 16'h0404, "REP register signature preserved");
        for (integer i = 0; i < 4; i++) check(memory['h2400 + i] == 8'('hA0 + i), "REP copy signature");
        if (debug_argument != 0) $display("COUNTERS,%0d,%0d", transfers, completions);
        check(!backend_pending && transfers == completions, "all accepted transfers complete exactly once");
        if (kind == 0 && old_mode != 0 && old_mode != new_mode)
            check(applied_replay == 4, "four preview bytes retained at live boundary");
        if (kind == 2) begin
            check(events == 1 && debug_gpr[47:32] == 1, "IRQ/NMI delivered exactly once across live request");
            check(irq_acks == (((old_mode + new_mode) % 2 == 0) ? 2 : 0), "interrupt acknowledge ownership");
        end
        $display("LIVE_RESULT,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d", cases, old_mode, new_mode, kind,
                 switches, applied_replay, transfers, events);
    endtask
    initial begin
        if ($value$plusargs("debug=%d", debug_argument)) begin end
        for (integer i = 0; i < 65536; i++) memory[i] = 8'hF4;
        for (old_mode = 0; old_mode < 8; old_mode++)
            for (new_mode = 0; new_mode < 8; new_mode++)
                for (kind = 0; kind < 3; kind++) begin
                    cases++; latency = kind == 0 ? 0 : kind == 1 ? 7 : 20; run_case();
                end
        check(replay_cases == 49 && pending_bus_cases == 64, "all historical transition replay and bus-wait probes");
        $display("PROFILE_LIVE_CPU_BRIDGE_PASS cases=%0d replay=%0d waiting=%0d checks=%0d",
                 cases, replay_cases, pending_bus_cases, checks);
        $finish;
    end
endmodule
