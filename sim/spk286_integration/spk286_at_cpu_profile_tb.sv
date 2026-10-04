`timescale 1ns/1ps
module spk286_at_cpu_profile_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    logic [2:0] requested = 3'd0;
    wire [2:0] active;
    wire pending, historical, phase_enable, phase_two, cpu_boundary;
    wire [2:0] missing_active;
    wire missing_pending, missing_historical, missing_phase, missing_two, missing_cpu;
    integer expected_profile = 0;
    integer age = 0, phases = 0, cpu_clocks = 0, last_cpu_edge = 0;
    integer checks = 0, reset_edges = 0, cases = 0, global_edge = 0;
    integer trace_fd = 0, summary_fd = 0;
    integer sampled_phase, sampled_two, sampled_cpu;
    integer window_start_age, window_start_phases, window_start_cpu;
    integer window_edges, reset_width, offset;
    integer fourstate_mode = 0, unused_plusargs;
    logic [31:0] random_q = 32'h28605004;
    string trace_path, summary_path;

    spk286_at_cpu_profile dut (.*);
    spk286_at_cpu_profile omitted_request (
        .clk(clk), .reset(reset), .requested(), .active(missing_active),
        .pending(missing_pending), .historical(missing_historical),
        .phase_enable(missing_phase), .phase_two(missing_two), .cpu_boundary(missing_cpu)
    );

    function automatic integer normalized_profile(input logic [2:0] selection);
        case (selection)
            3'd0, 3'd1, 3'd2, 3'd3, 3'd4, 3'd5, 3'd6, 3'd7:
                normalized_profile = int'(selection);
            default: normalized_profile = 0;
        endcase
    endfunction

    // This caller-owned table defines 2*CPU_Hz / 50MHz, independently of
    // the DUT lookup, accumulator, carry and parity state.
    function automatic integer phase_numerator(input integer profile);
        case (profile)
            1: phase_numerator = 12;
            2: phase_numerator = 16;
            3: phase_numerator = 20;
            4: phase_numerator = 25;
            5: phase_numerator = 32;
            6: phase_numerator = 40;
            7: phase_numerator = 50;
            default: phase_numerator = 0;
        endcase
    endfunction

    task automatic next_random;
        begin
            random_q = random_q ^ (random_q << 13);
            random_q = random_q ^ (random_q >> 17);
            random_q = random_q ^ (random_q << 5);
        end
    endtask

    task automatic step;
        integer numerator, next_phase_count, next_cpu_count;
        integer spacing, min_spacing, max_spacing;
        logic expected_phase, expected_cpu;
        begin
            #9;
            global_edge = global_edge + 1;
            sampled_phase = phase_enable ? 1 : 0;
            sampled_two = phase_two ? 1 : 0;
            sampled_cpu = cpu_boundary ? 1 : 0;
            if (reset) begin
                if ({phase_enable, phase_two, cpu_boundary} !== 3'b000)
                    $fatal(1, "profile reset enable oracle failed");
                expected_profile = normalized_profile(requested);
                age = 0; phases = 0; cpu_clocks = 0; last_cpu_edge = 0;
                reset_edges = reset_edges + 1;
            end else begin
                if (active !== 3'(expected_profile) ||
                    historical !== (expected_profile != 0) ||
                    pending !== (normalized_profile(requested) != expected_profile))
                    $fatal(1, "profile reset-only selection oracle failed");
                numerator = phase_numerator(expected_profile);
                // Independently scheduled boundaries at ceil(50*n/p) and
                // ceil(100*n/p), measured from the last reset edge.
                next_phase_count = ((age + 1) * numerator) / 50;
                next_cpu_count = expected_profile == 0 ? age + 1 :
                                 ((age + 1) * numerator) / 100;
                expected_phase = next_phase_count != (age * numerator) / 50;
                expected_cpu = expected_profile == 0 ? 1'b1 :
                               next_cpu_count != (age * numerator) / 100;
                if (phase_enable !== 1'(expected_phase) ||
                    cpu_boundary !== 1'(expected_cpu) ||
                    phase_two !== (expected_profile == 0 ? 1'b0 : expected_cpu))
                    $fatal(1, "profile rational boundary oracle failed profile=%0d age=%0d",
                           expected_profile, age);
                age = age + 1;
                if (phase_enable) begin
                    phases = phases + 1;
                    if (age * numerator - 50 * phases < 0 ||
                        age * numerator - 50 * phases >= numerator)
                        $fatal(1, "profile phase quantization oracle failed");
                end
                if (cpu_boundary) begin
                    cpu_clocks = cpu_clocks + 1;
                    spacing = age - last_cpu_edge;
                    min_spacing = expected_profile == 0 ? 1 : 100 / numerator;
                    max_spacing = expected_profile == 0 ? 1 : (100 + numerator - 1) / numerator;
                    if (spacing < min_spacing || spacing > max_spacing)
                        $fatal(1, "profile CPU spacing oracle failed");
                    if (expected_profile != 0 &&
                        (age * numerator - 100 * cpu_clocks < 0 ||
                         age * numerator - 100 * cpu_clocks >= numerator))
                        $fatal(1, "profile CPU quantization oracle failed");
                    last_cpu_edge = age;
                end
                if (phases != next_phase_count || cpu_clocks != next_cpu_count)
                    $fatal(1, "profile cumulative count oracle failed");
                checks = checks + 1;
            end
            #1; clk = 1'b1;
            #1;
            if (active !== 3'(expected_profile) ||
                historical !== (expected_profile != 0) ||
                pending !== (normalized_profile(requested) != expected_profile))
                $fatal(1, "profile reset-only selection oracle failed after edge");
            if (missing_active !== 3'd0 ||
                {missing_pending, missing_historical, missing_phase, missing_two} !== 4'b0000 ||
                missing_cpu !== !reset)
                $fatal(1, "profile omitted request normalization oracle failed");
            // Compact deterministic trace: every reset and the first hundred
            // edges of each epoch, plus each 4096th edge of long windows.
            if (trace_fd != 0 && (reset || age <= 100 || (age % 4096) == 0))
                $fdisplay(trace_fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                          global_edge, reset, requested, active, pending, historical,
                          age, sampled_phase, sampled_two, sampled_cpu, phases, cpu_clocks, random_q);
            #9; clk = 1'b0;
        end
    endtask

    task automatic apply_profile(input integer profile, input integer width);
        begin
            requested = 3'(profile); reset = 1'b1;
            repeat (width) step();
            reset = 1'b0;
        end
    endtask

    task automatic run_window(input integer kind, input integer edges);
        integer numerator, expected_phases, expected_clocks;
        begin
            window_start_age = age;
            window_start_phases = phases;
            window_start_cpu = cpu_clocks;
            repeat (edges) step();
            numerator = phase_numerator(expected_profile);
            expected_phases = (age * numerator) / 50 - (window_start_age * numerator) / 50;
            expected_clocks = expected_profile == 0 ? edges :
                (age * numerator) / 100 - (window_start_age * numerator) / 100;
            if (phases - window_start_phases != expected_phases ||
                cpu_clocks - window_start_cpu != expected_clocks)
                $fatal(1, "profile arbitrary window count oracle failed");
            cases = cases + 1;
            if (summary_fd != 0)
                $fdisplay(summary_fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                          cases, kind, expected_profile, requested, window_start_age,
                          edges, phases - window_start_phases, cpu_clocks - window_start_cpu);
        end
    endtask

    initial begin
        if ($value$plusargs("trace=%s", trace_path)) begin
            trace_fd = $fopen(trace_path, "w");
            if (trace_fd == 0) $fatal(1, "cannot open profile trace");
            $fdisplay(trace_fd, "edge,reset,requested,active,pending,historical,age,phase,two,cpu,phases,cpu_count,random");
        end
        if ($value$plusargs("summary=%s", summary_path)) begin
            summary_fd = $fopen(summary_path, "w");
            if (summary_fd == 0) $fatal(1, "cannot open profile summary");
            $fdisplay(summary_fd, "id,kind,active,requested,start_age,edges,phases,cpu_count");
        end
        // Exact long-run frequency and no-drift checks for all eight profiles.
        for (integer profile = 0; profile < 8; profile = profile + 1) begin
            apply_profile(profile, 2);
            run_window(0, 250000);
        end
        // Every old/new selector pair. Requested changes cannot modify the
        // active frequency or phase until the explicit reset is sampled.
        for (integer old_profile = 0; old_profile < 8; old_profile = old_profile + 1) begin
            for (integer new_profile = 0; new_profile < 8; new_profile = new_profile + 1) begin
                apply_profile(old_profile, 1);
                run_window(1, 53);
                requested = 3'(new_profile);
                run_window(2, 157);
                apply_profile(new_profile, 1);
                run_window(3, 211);
            end
        end
        // Reset each profile at every possible fabric offset modulo100.
        // This covers the full common rational CPU pattern including parity.
        for (integer profile = 0; profile < 8; profile = profile + 1) begin
            for (integer phase_offset = 0; phase_offset < 100; phase_offset = phase_offset + 1) begin
                apply_profile(profile, 1);
                repeat (phase_offset) step();
                apply_profile(profile, 1);
                run_window(4, 200);
            end
        end
        // Non-period-aligned windows, varying reset widths and requests while
        // reset is held. The last sampled requested value selects the profile.
        for (integer sample = 0; sample < 256; sample = sample + 1) begin
            next_random();
            apply_profile(int'(random_q[2:0]), 1);
            next_random(); reset_width = 1 + int'(random_q[2:0]);
            reset = 1'b1;
            repeat (reset_width) begin
                next_random(); requested = random_q[2:0]; step();
            end
            reset = 1'b0;
            next_random(); offset = int'(random_q[7:0]);
            repeat (offset) step();
            next_random(); window_edges = 1 + int'(random_q[10:0]);
            run_window(5, window_edges);
            next_random(); requested = random_q[2:0];
            next_random(); window_edges = 1 + int'(random_q[8:0]);
            run_window(6, window_edges);
        end
        if (cases != 1512) $fatal(1, "profile case count oracle failed");
        $display("SPK286_AT_CPU_PROFILE_PASS cases=%0d checks=%0d reset_edges=%0d", cases, checks, reset_edges);
`ifdef PROFILE_FOUR_STATE
        unused_plusargs = $value$plusargs("fourstate=%d", fourstate_mode);
        if (fourstate_mode != 0) begin
            // Only Icarus runs this separate four-state fixture. Verilator
            // cannot establish propagation of X/Z inputs in its two-state model.
            for (integer unknown_kind = 0; unknown_kind < 4; unknown_kind = unknown_kind + 1) begin
                apply_profile(7, 1);
                repeat (19) step();
                case (unknown_kind)
                    0: requested = 3'bxxx;
                    1: requested = 3'bzzz;
                    2: requested = 3'b1x0;
                    3: requested = 3'bz10;
                endcase
                run_window(7, 83);
                reset = 1'b1; step(); reset = 1'b0;
                if (active !== 3'd0 || pending !== 1'b0)
                    $fatal(1, "profile unknown request normalization oracle failed");
                run_window(8, 127);
            end
            $display("SPK286_AT_CPU_PROFILE_FOUR_STATE_PASS cases=8 unknown_encodings=4 omitted=1");
        end
`endif
        if (trace_fd != 0) $fclose(trace_fd);
        if (summary_fd != 0) $fclose(summary_fd);
        $finish;
    end
endmodule
