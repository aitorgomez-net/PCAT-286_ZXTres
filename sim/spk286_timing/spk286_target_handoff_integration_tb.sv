// Independent full-CPU handoff probes. Stimulus uses only public CPU ports.
// Encoding lengths are explicit fixture constants, not DUT syntax outputs.
`timescale 1ns/1ps
module spk286_target_handoff_integration_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:65535];
    logic [2:0] selected_profile = 3'd1;
    wire historical_enable, cpu_boundary;
    wire [2:0] active_profile;
    wire profile_pending, phase_enable, phase_two;
    integer profile_argument = 1, trace_argument = 0, edge_count = 0;
    integer debug_argument = 0;
    integer cases = 0, checks = 0, waits = 0, wait_length = 0;
    integer retires = 0, events = 0, cpu_ticks = 0, source_tick = -1;
    integer source_clocks = -1, source_budget = -1, target_length = 0;
    integer transfer_kind = 0, target_address = 0, expected_ax = 0;
    integer expected_sp = 0, expected_target_write = 0;
    integer target_retire_seen = 0, source_retire_seen = 0;
    integer event_probe = 0, injected = 0, expected_vector = 0;
    logic waiting = 0;
    logic [23:0] held_address;
    logic [15:0] held_data;
    logic [3:0] held_status;
    logic held_bhe, held_write, held_lock;

    spk286_at_cpu_profile profile_clock (
        .clk(clk), .reset(reset), .apply(1'b0), .requested(selected_profile),
        .active(active_profile), .pending(profile_pending),
        .historical(historical_enable), .phase_enable(phase_enable),
        .phase_two(phase_two), .cpu_boundary(cpu_boundary)
    );
`ifdef HANDOFF_GOLDEN_FUNCTIONAL
    spk286 dut (.*);
`else
    spk286_profiled dut (.timing_read_wait_event(1'b0),
        .profile_change_pending(1'b0), .profile_change_ready(), .*);
`endif

    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1)
            $fatal(1, "%s case=%0d profile=%0d kind=%0d len=%0d target=%h IP=%h instIP=%h AX=%h DX=%h SP=%h retire=%0d event=%0d clocks=%0d budget=%0d",
                message, cases, profile_argument, transfer_kind, target_length,
                16'(target_address), debug_ip, debug_instruction_ip,
                debug_gpr[15:0], debug_gpr[47:32], debug_gpr[79:64],
                retires, events, source_clocks, source_budget);
    endtask

    function automatic logic [15:0] word_at(input integer offset);
        word_at = {memory[16'(offset + 1)], memory[16'(offset)]};
    endfunction

    task automatic putword(input integer offset, input integer value);
        memory[16'(offset)] = 8'(value);
        memory[16'(offset + 1)] = 8'(value >> 8);
    endtask

    task automatic tick;
        logic source_admit, source_finish;
        integer observed_budget;
        begin
            #1;
            data_in = 16'h0F0F;
            if (bus_valid && address < 24'd65536)
                data_in = {memory[{address[15:1], 1'b1}], memory[{address[15:1], 1'b0}]};
            if (bus_valid && bus_status == 4'd0) data_in = 16'h2323;
            #4;
            if (debug_argument != 0 && !reset && dut.instruction_bytes >= 4'd9)
                $display("CONTEXT,%0d,%h,%0d,%b,%b,%b,%b,%b,%b,%b,%h,%h,%h",
                         edge_count, debug_ip, dut.instruction_bytes, dut.micro_active,
                         dut.raw_retired, dut.decode_ready, dut.executor_byte_ready,
                         dut.length_fault, dut.operation_done, dut.queue_consume_ready,
                         dut.micro_word, debug_micro_pc, debug_gpr[15:0]);
            source_admit = dut.opcode_start && debug_ip == 16'h0480;
`ifdef HANDOFF_GOLDEN_FUNCTIONAL
            source_finish = dut.raw_retired && !dut.event_active && debug_instruction_ip == 16'h0480;
            observed_budget = 0;
`else
            source_finish = dut.profile_retire_fire && !dut.event_active && debug_instruction_ip == 16'h0480;
            observed_budget = int'(dut.profile_scheduled);
`endif
            if (!reset) begin
                // Admission opens elapsed0; a coincident boundary belongs to
                // admission itself, not the following productive interval.
                if (source_admit) source_tick = cpu_ticks + int'(cpu_boundary);
                if (cpu_boundary) cpu_ticks = cpu_ticks + 1;
                if (source_finish) begin
                    source_clocks = cpu_ticks - source_tick;
                    source_budget = observed_budget;
                    source_retire_seen = source_retire_seen + 1;
                    check(debug_ip == 16'(target_address), "source retirement preserves unconsumed successor IP");
                    check(debug_gpr[15:0] == 16'h1000 && debug_gpr[47:32] == 16'h2222,
                          "successor architectural effects cannot precede source retirement");
                    check(word_at('h0720) == 16'h0000,
                          "successor memory side effect cannot precede source retirement");
                end
                if (event_probe > 0 && event_probe < 6 && dut.event_request && !dut.event_active) begin
                    check(source_retire_seen == 1,
                          "successor fault or external event follows completed source boundary");
                    check(debug_gpr[15:0] == 16'h1000 && debug_gpr[47:32] == 16'h2222 &&
                          word_at('h0720) == 0,
                          "unexecuted successor has no architectural effect before winning event");
                end
                if (bus_valid && ready && bus_write && address < 24'd65536) begin
                    if (address[0]) memory[address[15:0]] = data_out[15:8];
                    else begin
                        memory[address[15:0]] = data_out[7:0];
                        if (!bus_bhe_n) memory[16'(address + 24'd1)] = data_out[15:8];
                    end
                end
            end
            clk = 1'b1; #5; clk = 1'b0; #1; edge_count = edge_count + 1;
            if (instruction_retired) begin
                retires = retires + 1;
                if (debug_instruction_ip == 16'(target_address)) target_retire_seen = target_retire_seen + 1;
            end
            if (event_completed) events = events + 1;
            check(!microcode_fault && !control_error && debug_prefetch_count <= 4'd6,
                  "CPU and six-byte queue invariants");
            if (trace_argument != 0)
                $display("TRACE,%0d,%b,%b,%b,%b,%b,%b,%06h,%h,%b,%b,%04h,%04h,%b,%b,%032h,%04h,%04h,%04h,%b,%b,%b,%b,%0d,%0d,%h,%b,%b",
                    edge_count, reset, execute_enable, ready, intr, nmi, bus_valid,
                    address, bus_status, bus_write, bus_bhe_n, data_out, data_in,
                    bus_lock, hlda, debug_gpr, debug_flags, debug_cs, debug_ip,
                    halted, shutdown, instruction_retired, event_completed,
                    debug_event_kind, debug_event_vector, debug_micro_pc,
                    debug_micro_active, unsupported_opcode);
        end
    endtask

    task automatic run_protected_case(input integer variant);
        integer watchdog, cs_limit;
        begin
            cases = cases + 1;
            setup(1, 3, 1, 2);
            event_probe = 6;
            cs_limit = variant == 0 ? 'hFFFF : target_address + variant - 1;
            // Enter PE through the implemented LOADALL instruction and bus.
            // All cache records/selectors, gates and descriptors are real
            // program memory; no internal CPU state is forced.
            for (integer i = 'h0800; i < 'h0868; i = i + 1) memory[i] = 0;
            putword('h0806, 1); putword('h0818, 'h0042); putword('h081A, 'h0480);
            putword('h081E, 'h0010); putword('h0820, 'h0010); putword('h0822, 'h0008);
            putword('h0824, 'h0010); putword('h082C, 'h0800); putword('h082E, 'h1234);
            putword('h0830, 'h2222); putword('h0834, 'h1000);
            putword('h0838, 'h9300); putword('h083A, 'hFFFF);
            putword('h083E, 'h9A00); putword('h0840, cs_limit);
            putword('h0844, 'h9300); putword('h0846, 'hFFFF);
            putword('h084A, 'h9300); putword('h084C, 'hFFFF);
            putword('h084E, 'h0900); putword('h0852, 'h0017);
            putword('h0856, 'h8200); putword('h085E, 'h07FF);
            putword('h0862, 'h8900); putword('h0864, 'hFFFF);
            for (integer i = 'h0900; i < 'h0918; i = i + 1) memory[i] = 0;
            putword('h0908, 'hFFFF); putword('h090C, 'h9A00);
            putword('h0910, 'hFFFF); putword('h0914, 'h9200);
            putword(13 * 8, 'h0600); putword(13 * 8 + 2, 8);
            putword(13 * 8 + 4, 'h8600); putword(13 * 8 + 6, 0);
            memory['h0600] = 8'hF4;
            memory['h0450] = 8'h0F; memory['h0451] = 8'h05;
            if (variant == 0) begin
                // Invalid far source selector: fault belongs to source EA.
                memory['h0480] = 8'hEA; putword('h0481, target_address);
                putword('h0483, 'h0018);
            end
            execute_enable = 0; ip_write_en = 1; ip_write_data = 16'h0450; redirect = 1;
            tick(); ip_write_en = 0; redirect = 0; execute_enable = 1;
            watchdog = 0;
            while (events == 0 && !shutdown && watchdog < 30000) begin
                service(); watchdog = watchdog + 1;
            end
            check(events == 1 && !shutdown && debug_event_vector == 8'd13 &&
                  debug_protected_msw[0], "protected source or truncated target raises bounded #GP");
            check(debug_gpr[15:0] == 16'h1000 && debug_gpr[47:32] == 16'h2222 &&
                  word_at('h0720) == 0, "protected fault preserves unexecuted target state");
            check(debug_gpr[79:64] == 16'h07F8 && word_at('h07FC) == 16'h0008,
                  "protected #GP frame includes source CS and error word");
            check(word_at('h07FA) == (variant == 0 ? 16'h0480 : 16'(target_address)),
                  "source validation fault and successor fetch fault retain distinct IPs");
            check(source_retire_seen == (variant == 0 ? 0 : 1),
                  "failed source never retires; successful source precedes target fetch fault");
            check(word_at('h07F8) == (variant == 0 ? 16'h0018 : 16'h0000),
                  "protected source selector error versus target fetch error0");
            $display("PROTECTED_RESULT,%0d,%0d,%0d,%0d,%04h,%04h",
                     cases, profile_argument, variant, source_retire_seen,
                     word_at('h07FA), word_at('h07F8));
            event_probe = 0;
        end
    endtask

`ifndef HANDOFF_GOLDEN_FUNCTIONAL
    task automatic run_cancel_case(input integer reset_variant);
        integer watchdog;
        logic [23:0] stale_address;
        begin
            cases = cases + 1;
            setup(1, 10, 0, 8);
            watchdog = 0;
            while (!(dut.profile_target_preview_active &&
                     dut.profile_target_replay_count >= 4'd1 &&
                     bus_valid && bus_status == 4'hD && !ready) && watchdog < 20000) begin
                service(); watchdog = watchdog + 1;
            end
            check(watchdog < 20000 && source_retire_seen == 0,
                  "reach partial preview with offered READY-low CODE owner");
            stale_address = address;
            memory['h0700] = 8'hB8; putword('h0701, 'hBEEF);
            memory['h0703] = 8'hBA; putword('h0704, 'hCAFE); memory['h0706] = 8'hF4;
            if (reset_variant != 0) begin
                reset = 1; execute_enable = 0; ready = 0; waiting = 0; waits = 0;
                tick();
                check(!bus_valid && !hlda && debug_ip == 16'hFFF0 &&
                      dut.profile_target_replay_count == 0 && !dut.profile_target_pending,
                      "reset cancels preview and restores architectural reset boundary");
                reset = 0; segment_load_en = 1; segment_load_index = 1; segment_load_selector = 0;
            end
            ip_write_en = 1; ip_write_data = 16'h0700; redirect = 1;
            ready = 0; tick();
            if (reset_variant == 0)
                check(bus_valid && address == stale_address,
                      "external redirect retains offered stale CODE owner until READY");
            redirect = 0; ip_write_en = 0; segment_load_en = 0; execute_enable = 1;
            watchdog = 0;
            while (!halted && events == 0 && watchdog < 20000) begin
                service(); watchdog = watchdog + 1;
            end
            check(halted && events == 0 && !shutdown && debug_gpr[15:0] == 16'hBEEF &&
                  debug_gpr[47:32] == 16'hCAFE && word_at('h0720) == 0,
                  "cancelled bytes never execute and replacement stream decodes once");
            check(source_retire_seen == 0 && dut.profile_target_replay_count == 0 &&
                  !dut.profile_target_pending, "cancel releases all source/staging tokens");
            $display("CANCEL_RESULT,%0d,%0d,%0d,%0d,%04h,%04h",
                     cases, profile_argument, reset_variant, source_retire_seen,
                     debug_gpr[15:0], debug_gpr[47:32]);
        end
    endtask

    task automatic run_hold_case;
        integer watchdog;
        begin
            cases = cases + 1;
            setup(1, 10, 1, 8);
            watchdog = 0;
            while (!dut.profile_target_pending && watchdog < 20000) begin
                service(); watchdog = watchdog + 1;
            end
            check(watchdog < 20000 && source_retire_seen == 0,
                  "reach successful source redirect before preview is complete");
            hold_request = 1;
            watchdog = 0;
            while (!hlda && watchdog < 20000) begin service(); watchdog = watchdog + 1; end
            check(hlda && !bus_valid, "HOLD grants only a native free bus boundary");
            for (integer pause = 0; pause < 20; pause = pause + 1) begin
                service();
                check(hlda && !bus_valid && source_retire_seen == 0 &&
                      debug_gpr[15:0] == 16'h1000 && word_at('h0720) == 0,
                      "HOLD cannot bypass missing target bytes or execute staged successor");
            end
            hold_request = 0;
            watchdog = 0;
            while (!halted && events == 0 && watchdog < 20000) begin
                service(); watchdog = watchdog + 1;
            end
            check(halted && events == 0 && source_retire_seen == 1 &&
                  target_retire_seen == 1 && debug_gpr[47:32] == 16'hBEEF &&
                  word_at('h0720) == 16'h1234,
                  "HOLD release completes retained source and successor exactly once");
            $display("HOLD_RESULT,%0d,%0d,%0d,%0d", cases, profile_argument,
                     source_retire_seen, target_retire_seen);
        end
    endtask
`endif

    task automatic run_event_case(input integer probe_value, input integer phase_value);
        integer watchdog;
        logic milestone;
        begin
            cases = cases + 1;
            setup(1, 10, 1, 3);
            event_probe = probe_value; injected = 0;
            expected_vector = probe_value == 1 ? 13 : probe_value == 2 ? 6 :
                              probe_value == 3 ? 1 : probe_value == 4 ? 2 : 35;
            putword(expected_vector * 4, 'h0600);
            putword(expected_vector * 4 + 2, 0);
            memory['h0600] = 8'hF4;
            if (probe_value == 1) begin
                // Eleven-byte prefix/opcode sequence must fault at target IP.
                for (integer p = 0; p < 10; p = p + 1)
                    memory[target_address + p] = 8'h3E;
                memory[target_address + 10] = 8'h40;
            end else if (probe_value == 2 || probe_value == 3) begin
                memory[target_address] = 8'h0F; memory[target_address + 1] = 8'hFF;
            end
            if (probe_value == 3 || probe_value == 5) begin
                // Setup ports remain ordinary public state controls while
                // execute_enable is paused before the tested source starts.
                execute_enable = 0; flags_write_en = 1; flags_write_mask = 16'hFFFF;
                flags_write_data = probe_value == 3 ? 16'h0142 : 16'h0242;
                tick(); flags_write_en = 0; execute_enable = 1;
            end
            watchdog = 0;
            while (events == 0 && watchdog < 20000) begin
                milestone = 0;
                if (probe_value == 4 || probe_value == 5) begin
`ifdef HANDOFF_GOLDEN_FUNCTIONAL
                    milestone = dut.micro_active && debug_instruction_ip == 16'h0480 &&
                                debug_ip == 16'h0481;
`else
                    case (phase_value)
                        0: milestone = dut.micro_active && debug_instruction_ip == 16'h0480 &&
                                       debug_ip == 16'h0481;
                        1: milestone = dut.internal_redirect;
                        2: milestone = dut.raw_retired;
                        3: milestone = dut.profile_target_preview_start;
                        4: milestone = dut.profile_target_replay_count >= 4'd1 &&
                                       !dut.profile_target_complete;
                        5: milestone = dut.profile_target_complete && dut.profile_target_pending;
                        6: milestone = dut.profile_retire_fire;
                        default: $fatal(1, "invalid event milestone");
                    endcase
`endif
                    if (injected == 0 && milestone) begin
                        injected = 1;
                        if (probe_value == 4) nmi = 1;
                        else intr = 1;
                    end
                end
                service(); watchdog = watchdog + 1;
                if (probe_value == 4 && injected != 0) nmi = 0;
            end
            check(events == 1 && !shutdown && debug_event_vector == 8'(expected_vector),
                  "first event has original trap/external/successor provenance");
            check(source_retire_seen == 1 && target_retire_seen == 0,
                  "source retires once before unexecuted target event");
            check(debug_gpr[15:0] == 16'h1000 && debug_gpr[47:32] == 16'h2222 &&
                  word_at('h0720) == 0, "event discards successor without side effects");
            check(word_at('h07FA) == 16'(target_address) && word_at('h07FC) == 0,
                  "saved event IP/CS belongs to target boundary");
            check(debug_instruction_ip == 16'h0480 || debug_instruction_ip == 16'(target_address),
                  "source/target context lifetime remains defined before handler opcode");
            if (probe_value == 4 || probe_value == 5)
                check(injected == 1, "requested asynchronous milestone was actually reached");
            $display("EVENT_RESULT,%0d,%0d,%0d,%0d,%0d,%0d,%04h",
                     cases, profile_argument, probe_value, phase_value, expected_vector,
                     source_clocks, word_at('h07FA));
            event_probe = 0; intr = 0; nmi = 0;
        end
    endtask

    task automatic service;
        begin
            #1;
            if (waiting)
                check(bus_valid && address == held_address && data_out == held_data &&
                      bus_status == held_status && bus_bhe_n == held_bhe &&
                      bus_write == held_write && bus_lock == held_lock,
                      "READY-low retains exact native transaction");
            ready = bus_valid && waits >= wait_length;
            waiting = bus_valid && !ready;
            if (waiting) begin
                waits = waits + 1;
                held_address = address; held_data = data_out;
                held_status = bus_status; held_bhe = bus_bhe_n;
                held_write = bus_write; held_lock = bus_lock;
            end else waits = 0;
            tick();
        end
    endtask

    task automatic setup(input integer kind_value, input integer length_value,
                         input integer odd_value, input integer stall_value);
        integer opcode_at, successor_at, prefix_count;
        begin
            transfer_kind = kind_value; target_length = length_value;
            target_address = kind_value == 4 ? 'h0482 : 'h0500 + odd_value;
            expected_ax = length_value == 1 ? 'h1001 : 'h1234;
            expected_target_write = length_value >= 6 ? 1 : 0;
            if (expected_target_write != 0) expected_ax = 'h1000;
            expected_sp = kind_value == 5 || kind_value == 8 ? 'h07FE :
                          kind_value == 11 ? 'h07FC :
                          kind_value == 7 ? 'h0802 :
                          kind_value == 12 || kind_value == 13 ? 'h0804 :
                          kind_value == 14 ? 'h0806 : 'h0800;
            wait_length = stall_value; execute_enable = 0; reset = 1; ready = 0;
            intr = 0; nmi = 0; hold_request = 0; waiting = 0; waits = 0;
            gpr_write_en = 0; flags_write_en = 0; segment_load_en = 0;
            redirect = 0; ip_write_en = 0;
            source_tick = -1; source_clocks = -1; source_budget = -1;
            source_retire_seen = 0; target_retire_seen = 0;
            tick(); reset = 0;
            for (integer r = 0; r < 8; r = r + 1) begin
                gpr_write_en = 1; gpr_write_index = 3'(r);
                gpr_write_data = r == 0 ? 16'h1000 : r == 1 ? (kind_value == 3 ? 16'd2 : 16'd0) :
                                 r == 2 ? 16'h2222 : r == 3 ? 16'h1234 :
                                 r == 4 ? 16'h0800 : 16'd0;
                tick();
            end
            gpr_write_en = 0; flags_write_en = 1; flags_write_mask = 16'hFFFF;
            flags_write_data = 16'h0042; tick(); flags_write_en = 0;
            for (integer s = 0; s < 4; s = s + 1) begin
                segment_load_en = 1; segment_load_index = 2'(s); segment_load_selector = 0;
                redirect = s == 1; ip_write_en = s == 1; ip_write_data = 16'h0480;
                tick();
            end
            segment_load_en = 0; redirect = 0; ip_write_en = 0;
            for (integer i = 'h0480; i < 'h0560; i = i + 1) memory[i] = 8'hF4;
            putword('h0700, target_address); putword('h0720, 0);
            putword('h0800, target_address); putword('h0802, 0);
            case (kind_value)
                0,1,2,3,4: begin
                    memory['h0480] = kind_value == 0 ? 8'h74 : kind_value == 1 ? 8'hEB :
                                     kind_value == 2 ? 8'hE3 : kind_value == 3 ? 8'hE2 : 8'h75;
                    memory['h0481] = 8'(target_address - 'h0482);
                end
                5,6: begin
                    memory['h0480] = kind_value == 5 ? 8'hE8 : 8'hE9;
                    putword('h0481, target_address - 'h0483);
                end
                7: memory['h0480] = 8'hC3;
                8,9: begin
                    memory['h0480] = 8'hFF; memory['h0481] = kind_value == 8 ? 8'h16 : 8'h26;
                    putword('h0482, 'h0700);
                end
                10,11: begin
                    memory['h0480] = kind_value == 10 ? 8'hEA : 8'h9A;
                    putword('h0481, target_address); putword('h0483, 0);
                end
                12: memory['h0480] = 8'hCB;
                13,14: begin
                    memory['h0480] = kind_value == 13 ? 8'hC2 : 8'hCA;
                    putword('h0481, 2);
                end
                default: $fatal(1, "invalid transfer fixture");
            endcase
            prefix_count = length_value >= 6 ? length_value - 6 : length_value > 3 ? length_value - 3 : 0;
            for (integer p = 0; p < prefix_count; p = p + 1)
                memory[target_address + p] = 8'h3E;
            opcode_at = target_address + prefix_count;
            if (length_value == 1) memory[opcode_at] = 8'h40;
            else if (length_value == 2) begin
                memory[opcode_at] = 8'h8B; memory[opcode_at + 1] = 8'hC3;
            end else if (length_value < 6) begin
                memory[opcode_at] = 8'hB8; putword(opcode_at + 1, 'h1234);
            end else begin
                memory[opcode_at] = 8'hC7; memory[opcode_at + 1] = 8'h06;
                putword(opcode_at + 2, 'h0720); putword(opcode_at + 4, 'h1234);
            end
            successor_at = target_address + length_value;
            memory[successor_at] = 8'hBA; putword(successor_at + 1, 'hBEEF);
            memory[successor_at + 3] = 8'hF4;
            retires = 0; events = 0; execute_enable = 1;
        end
    endtask

    task automatic run_case(input integer kind_value, input integer length_value,
                            input integer odd_value, input integer stall_value);
        integer watchdog, base_clocks, allowance;
        begin
            cases = cases + 1;
            setup(kind_value, length_value, odd_value, stall_value);
            watchdog = 0;
            while (!halted && events == 0 && watchdog < 20000) begin
                service(); watchdog = watchdog + 1;
            end
            check(halted && events == 0 && !shutdown && !unsupported_opcode && !operand_blocked,
                  "bounded valid target execution without spurious fault");
            check(source_retire_seen == 1 && target_retire_seen == 1,
                  "one source and one target retirement");
            check(debug_gpr[15:0] == 16'(expected_ax) && debug_gpr[47:32] == 16'hBEEF,
                  "target and following sentinel decode exactly once");
            check(debug_gpr[79:64] == 16'(expected_sp), "source stack effect remains exact");
            check(word_at('h0720) == (expected_target_write != 0 ? 16'h1234 : 16'h0000),
                  "staged ModRM displacement/immediate produces exact target write");
            if (kind_value == 5) check(word_at('h07FE) == 16'h0483, "CALL pushes original return IP");
            if (kind_value == 8) check(word_at('h07FE) == 16'h0484, "indirect CALL return IP");
            if (kind_value == 11)
                check(word_at('h07FC) == 16'h0485 && word_at('h07FE) == 16'h0000,
                      "far CALL source frame untouched by preview IP");
            base_clocks = kind_value == 3 ? 8 : kind_value == 4 ? 3 :
                          kind_value == 7 || kind_value == 9 || kind_value == 10 || kind_value == 13 ? 11 :
                          kind_value == 8 || kind_value == 11 ? 13 :
                          kind_value == 12 || kind_value == 14 ? 15 : 7;
            // FF /2 memory CALL is 11; immediate far CALL is 13.
            if (kind_value == 8) base_clocks = 11;
            allowance = kind_value == 3 || kind_value == 4 ? 0 : length_value;
`ifndef HANDOFF_GOLDEN_FUNCTIONAL
            if (historical_enable) begin
                check(source_budget == base_clocks + allowance,
                      "documented source budget charges only qualified target length");
                check(source_clocks >= base_clocks + allowance,
                      "source retirement observes complete minimum budget");
            end
`endif
            $display("RESULT,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                     cases, profile_argument, kind_value, length_value, odd_value,
                     stall_value, source_clocks, source_budget);
        end
    endtask

    initial begin
        if (!$value$plusargs("profile=%d", profile_argument)) profile_argument = 1;
        if (!$value$plusargs("trace=%d", trace_argument)) trace_argument = 0;
        if (!$value$plusargs("debug=%d", debug_argument)) debug_argument = 0;
        if (profile_argument < 0 || profile_argument > 7) $fatal(1, "invalid profile");
        selected_profile = 3'(profile_argument);
        for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'hF4;
        for (integer length_value = 1; length_value <= 10; length_value = length_value + 1)
            for (integer odd_value = 0; odd_value < 2; odd_value = odd_value + 1) begin
                run_case(0, length_value, odd_value, 0);
                run_case(1, length_value, odd_value, 0);
            end
        for (integer kind_value = 2; kind_value < 15; kind_value = kind_value + 1)
            for (integer odd_value = 0; odd_value < 2; odd_value = odd_value + 1)
                run_case(kind_value, 3, odd_value, 0);
        for (integer length_value = 1; length_value <= 10; length_value = length_value + 1)
            run_case(1, length_value, length_value % 2, 7);
        run_event_case(1, 0);
        run_event_case(2, 0);
        run_event_case(3, 0);
        if (historical_enable) begin
            for (integer phase_value = 0; phase_value < 7; phase_value = phase_value + 1) begin
                run_event_case(4, phase_value);
                run_event_case(5, phase_value);
            end
        end else begin
            run_event_case(4, 0);
            run_event_case(5, 0);
        end
        for (integer variant = 0; variant < 3; variant = variant + 1)
            run_protected_case(variant);
`ifndef HANDOFF_GOLDEN_FUNCTIONAL
        if (historical_enable) begin
            run_cancel_case(0); run_cancel_case(1); run_hold_case();
        end
`endif
        $display("P06_TARGET_HANDOFF_INTEGRATION_PASS profile=%0d cases=%0d checks=%0d",
                 profile_argument, cases, checks);
        $finish;
    end
endmodule
