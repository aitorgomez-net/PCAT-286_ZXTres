`timescale 1ns/1ps

// A synchronous CPU consumer and one-pulse backend responses exercise the
// response boundary independently of the legacy bridge test's polling driver.
module spk286_at_bus_bridge_response_case #(
    parameter bit DIV2 = 1'b0
) (output logic done = 1'b0);
`ifdef EXPECT_REGISTERED_MEMORY_RESPONSE
    localparam bit EXPECT_DIRECT = 1'b0;
`else
    localparam bit EXPECT_DIRECT = !DIV2;
`endif
    localparam bit EXPECT_ENTRY_COMMAND = !DIV2;
    logic clk = 0, reset = 1, cpu_phase = 0;
    always #10 clk = ~clk;
    always @(posedge clk) cpu_phase <= !cpu_phase;
    wire cpu_sample_edge = !cpu_phase;
    wire cpu_samples = !DIV2 || cpu_sample_edge;

    logic cpu_valid = 0, cpu_write = 0, cpu_bhe_n = 1;
    logic cpu_lock = 0, memory_width = 1, io_width = 0;
    logic [23:0] cpu_address = 0;
    logic [15:0] cpu_out = 0;
    logic [3:0] cpu_status = 4'hF;
    wire cpu_ready, at_valid, at_command, at_write, at_lock;
    wire at_accepted, at_completed, at_response, bridge_idle, protocol_error;
    wire [15:0] cpu_in, at_out;
    wire [23:0] at_address;
    wire [1:0] at_lanes;
    logic at_accept = 0, at_ready = 0, at_read_valid = 0;
    logic [15:0] at_data = 0;
    integer clocks = 0, accepted = 0, completed = 0, samples = 0;
    integer write_effects = 0, checks = 0;
    integer backend_edge = 0, cpu_edge = 0;
    logic [15:0] sampled_data = 0;
    logic [1:0] response_phases = 0;

    spk286_at_bus_bridge #(.COMPLETE_ON_CPU_SAMPLE(DIV2)) dut (
        .clk(clk), .reset(reset), .cpu_sample_edge(cpu_sample_edge),
        .cpu_bus_valid(cpu_valid), .cpu_address(cpu_address),
        .cpu_data_out(cpu_out), .cpu_data_oe(cpu_write),
        .cpu_bus_write(cpu_write), .cpu_bus_bhe_n(cpu_bhe_n),
        .cpu_bus_status(cpu_status), .cpu_bus_lock(cpu_lock),
        .cpu_memory_word_capable(memory_width), .cpu_io_word_capable(io_width),
        .cpu_ready(cpu_ready), .cpu_data_in(cpu_in),
        .at_valid(at_valid), .at_command_valid(at_command),
        .at_address(at_address), .at_byte_enable(at_lanes),
        .at_data_out(at_out), .at_write(at_write), .at_lock(at_lock),
        .at_accepted(at_accepted), .at_completed(at_completed),
        .at_response_valid(at_response), .at_accept(at_accept),
        .at_ready(at_ready), .at_read_data(at_data),
        .at_read_data_valid(at_read_valid), .bridge_idle(bridge_idle),
        .protocol_error(protocol_error), .at_owner(), .at_cycle_class(),
        .at_a0(), .at_bhe_n(), .at_data_oe(), .at_io(), .at_inta(),
        .at_code_fetch(), .debug_state()
    );

    always @(posedge clk) begin
        clocks <= clocks + 1;
        if (!reset) begin
            if (at_accepted) begin
                accepted <= accepted + 1;
                if (at_write) write_effects <= write_effects + 1;
            end
            if (at_completed) begin
                completed <= completed + 1;
                backend_edge <= clocks;
                response_phases[cpu_sample_edge] <= 1;
            end
            if (cpu_valid && cpu_ready && cpu_samples) begin
                samples <= samples + 1;
                sampled_data <= cpu_in;
                cpu_edge <= clocks;
                if (cpu_lock && !at_lock)
                    $fatal(1, "LOCK lost at CPU sample div2=%0d", DIV2);
                if (!at_response)
                    $fatal(1, "CPU READY without response marker div2=%0d", DIV2);
            end
        end
    end

    task automatic check(input bit value, input string message);
        begin
            checks = checks + 1;
            if (!value) $fatal(1, "RESPONSE_CHECK_FAIL div2=%0d: %s", DIV2, message);
        end
    endtask

    task automatic begin_request(
        input logic [23:0] address,
        input logic [3:0] status,
        input bit bhe_n,
        input logic [15:0] data,
        input bit locked,
        input bit native_memory,
        input bit native_io
    );
        begin
            // Invoked on a falling edge, after the preceding CPU sampling
            // edge. Keeping valid high is intentional for consecutive beats.
            cpu_valid = 1;
            cpu_address = address;
            cpu_status = status;
            cpu_write = status == 4'h6 || status == 4'hA;
            cpu_bhe_n = bhe_n;
            cpu_out = data;
            cpu_lock = locked;
            memory_width = native_memory;
            io_width = native_io;
        end
    endtask

    task automatic wait_command;
        integer timeout_count;
        begin
            timeout_count = 0;
            while (!at_command && timeout_count < 50) begin
                @(negedge clk);
                timeout_count = timeout_count + 1;
            end
            check(at_command, "command missing");
            check(!cpu_ready, "READY before acceptance");
        end
    endtask

    task automatic accept_request;
        integer old_count;
        begin
            wait_command();
            old_count = accepted;
            at_accept = 1;
            @(negedge clk);
            at_accept = 0;
            check(accepted == old_count + 1, "command not accepted exactly once");
        end
    endtask

    task automatic reply(
        input logic [15:0] value,
        input bit valid_data,
        input bit direct_expected,
        input logic [15:0] expected_data,
        input bit check_data
    );
        integer old_samples, old_completed, timeout_count;
        begin
            old_samples = samples;
            old_completed = completed;
            at_data = value;
            at_read_valid = valid_data;
            at_ready = 1;
            // Backend response lasts precisely one parent-clock sampling
            // edge. The CPU must retain data across its slower-clock wait.
            @(negedge clk);
            at_ready = 0;
            at_read_valid = 0;
            at_data = 16'hDEAD;
            check(completed == old_completed + 1, "backend response not consumed once");
            timeout_count = 0;
            while (samples == old_samples && timeout_count < 20) begin
                @(negedge clk);
                timeout_count = timeout_count + 1;
            end
            check(samples == old_samples + 1, "CPU did not sample exactly one response");
            if (direct_expected)
                check(cpu_edge == backend_edge, "native response inserted an extra clock");
            else
                check(cpu_edge > backend_edge, "conservative response bypassed its register");
            if (check_data)
                check(sampled_data == expected_data, "CPU sampled wrong byte lanes/data");
        end
    endtask

    task automatic retire_request;
        integer old_samples, old_accepted;
        begin
            cpu_valid = 0;
            cpu_lock = 0;
            old_samples = samples;
            old_accepted = accepted;
            repeat (4) @(negedge clk);
            check(bridge_idle && !cpu_ready, "response was not released");
            check(samples == old_samples && accepted == old_accepted,
                  "completed request was sampled or accepted twice");
        end
    endtask

    initial begin : exercise
        integer before_accept, before_samples, before_writes;
        repeat (3) @(negedge clk);
        reset = 0;

        // A high stale backend response cannot complete an unaccepted read.
        begin_request(24'hFFFFF0, 4'hD, 0, 0, 0, 1, 0);
        at_ready = 1;
        at_read_valid = 1;
        at_data = 16'hDEAD;
        wait_command();
        repeat (3) @(negedge clk);
        check(samples == 0 && !cpu_ready && !at_completed,
              "stale READY completed before acceptance");
        at_ready = 0;
        at_read_valid = 0;
        accept_request();
        // Eligibility and lane shape must not depend on a live width input.
        memory_width = 0;
        at_ready = 1;
        repeat (3) @(negedge clk);
        check(samples == 0 && !cpu_ready && !at_completed,
              "read completed without data-valid");
        at_ready = 0;
        reply(16'h5BEA, 1, EXPECT_DIRECT, 16'h5BEA, 1);
        retire_request();

        // Backend already able to accept on the initial capture edge.
        // Common-clock native memory skips COMMAND; divided clocks retain it.
        before_accept = accepted;
        before_writes = write_effects;
        begin_request(24'h012341, 4'h6, 0, 16'hAB00, 1, 1, 0);
        at_accept = 1;
        #1;
        check(at_command == EXPECT_ENTRY_COMMAND && !cpu_ready,
              "initial command eligibility or premature completion");
        wait_command();
        @(negedge clk);
        at_accept = 0;
        check(accepted == before_accept + 1 && at_out == 16'hAB00 &&
              at_lanes == 2'b10 && at_address == 24'h012341,
              "initial accepted write lost its complete record");
        reply(0, 0, EXPECT_DIRECT, 0, 0);
        retire_request();
        check(write_effects == before_writes + 1, "initial write duplicated");

        // All three native lane shapes, both reads and writes. Upper-byte
        // requests are already a single BIU beat and must not split again.
        for (integer lane = 1; lane <= 3; lane = lane + 1) begin
            begin_request(lane == 2 ? 24'h012341 : 24'h012340,
                          4'h5, lane == 1, 0, 1, 1, 0);
            accept_request();
            check(at_lanes == 2'(lane), "read lanes changed");
            reply(16'hA53C, 1, EXPECT_DIRECT,
                  lane == 1 ? 16'h003C : lane == 2 ? 16'hA500 : 16'hA53C, 1);
            retire_request();
            before_writes = write_effects;
            begin_request(lane == 2 ? 24'h012341 : 24'h012340,
                          4'h6, lane == 1, 16'hA53C, 1, 1, 0);
            accept_request();
            check(at_lanes == 2'(lane) && at_out ==
                  (lane == 1 ? 16'h003C : lane == 2 ? 16'hA500 : 16'hA53C),
                  "write lanes or payload changed");
            reply(16'hDEAD, 0, EXPECT_DIRECT, 0, 0);
            retire_request();
            check(write_effects == before_writes + 1, "write duplicated");
        end

        // Identical consecutive writes never drop valid. Follow them with
        // different address/lane metadata, updated only after CPU sampling.
        before_accept = accepted;
        before_samples = samples;
        before_writes = write_effects;
        for (integer beat = 0; beat < 3; beat = beat + 1) begin
            begin_request(beat == 2 ? 24'h100001 : 24'h100000,
                          4'h6, beat != 2, 16'h7E5A, 1, 1, 0);
            accept_request();
            check(at_address == (beat == 2 ? 24'h100001 : 24'h100000),
                  "back-to-back request inherited stale address");
            reply(0, 0, EXPECT_DIRECT, 0, 0);
        end
        retire_request();
        check(accepted == before_accept + 3 && samples == before_samples + 3 &&
              write_effects == before_writes + 3, "back-to-back accounting mismatch");

        // Even ISA16 I/O must retain the peripheral completion sequence.
        begin_request(24'h0001F0, 4'h9, 0, 0, 0, 1, 1);
        accept_request();
        reply(16'h1234, 1, 0, 16'h1234, 1);
        retire_request();
        // EGA/unmapped byte target and native-memory upper-byte fetch.
        begin_request(24'h0B8001, 4'h5, 0, 0, 0, 0, 0);
        accept_request();
        reply(16'h6700, 1, 0, 16'h6700, 1);
        retire_request();
        begin_request(24'hFFFFFF, 4'hD, 0, 0, 0, 1, 0);
        accept_request();
        reply(16'h8900, 1, EXPECT_DIRECT, 16'h8900, 1);
        retire_request();

        // INTA may complete without data-valid on its first acknowledge.
        begin_request(0, 4'h0, 1, 0, 1, 1, 1);
        accept_request();
        reply(16'h00FF, 0, 0, 16'h00FF, 1);
        begin_request(0, 4'h0, 1, 0, 1, 1, 1);
        accept_request();
        reply(16'h0042, 1, 0, 16'h0042, 1);
        retire_request();

        // Reset before acceptance and coincident with a backend response.
        before_accept = accepted;
        before_samples = samples;
        begin_request(24'h222220, 4'h5, 0, 0, 0, 1, 0);
        wait_command();
        reset = 1;
        at_ready = 1;
        at_read_valid = 1;
        @(negedge clk);
        cpu_valid = 0;
        reset = 0;
        repeat (3) @(negedge clk);
        check(accepted == before_accept && samples == before_samples && bridge_idle,
              "unaccepted reset transaction leaked");
        at_ready = 0;
        at_read_valid = 0;
        begin_request(24'h222222, 4'h5, 0, 0, 0, 1, 0);
        accept_request();
        before_samples = samples;
        reset = 1;
        at_ready = 1;
        at_read_valid = 1;
        #1;
        check(!cpu_ready, "reset did not mask direct response");
        @(negedge clk);
        cpu_valid = 0;
        reset = 0;
        repeat (3) @(negedge clk);
        check(samples == before_samples && bridge_idle,
              "accepted reset response leaked into CPU");
        at_ready = 0;
        at_read_valid = 0;
        begin_request(24'h333330, 4'h5, 0, 0, 0, 1, 0);
        accept_request();
        reply(16'hC0DE, 1, EXPECT_DIRECT, 16'hC0DE, 1);
        retire_request();

        check(!protocol_error, "bridge reported a protocol error");
        check(!DIV2 || response_phases == 2'b11,
              "divided-clock responses did not cover both parent-clock phases");
        $display("AT_BRIDGE_RESPONSE_CASE_PASS div2=%0d direct=%0d checks=%0d accepted=%0d completed=%0d samples=%0d",
                 DIV2, EXPECT_DIRECT, checks, accepted, completed, samples);
        done = 1;
    end
endmodule

module spk286_at_bus_bridge_response_tb;
    wire normal_done, divided_done;
    spk286_at_bus_bridge_response_case normal_case(.done(normal_done));
    spk286_at_bus_bridge_response_case #(.DIV2(1)) divided_case(.done(divided_done));
    initial begin
        wait (normal_done && divided_done);
        $display("AT_BRIDGE_RESPONSE_PASS");
        $finish;
    end
    initial begin
        #200000;
        $fatal(1, "AT bridge response timeout");
    end
endmodule
