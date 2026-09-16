`timescale 1ns/1ps

module spk286_at_bus_bridge_tb;
`ifdef SPK286_P01_FAST_MEMORY_START
    localparam logic EXPECT_P01_FAST_MEMORY_START = 1'b1;
`else
    localparam logic EXPECT_P01_FAST_MEMORY_START = 1'b0;
`endif

    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    logic cpu_bus_valid = 1'b0;
    logic [23:0] cpu_address = 24'd0;
    logic [15:0] cpu_data_out = 16'd0;
    logic cpu_data_oe = 1'b0;
    logic cpu_bus_write = 1'b0;
    logic cpu_bus_bhe_n = 1'b1;
    logic [3:0] cpu_bus_status = 4'hF;
    logic cpu_bus_lock = 1'b0;
    logic cpu_memory_word_capable = 1'b0;
    logic cpu_io_word_capable = 1'b0;
    wire cpu_ready;
    wire [15:0] cpu_data_in;

    wire at_valid;
    wire at_command_valid;
    wire [2:0] at_owner;
    wire [3:0] at_cycle_class;
    wire [23:0] at_address;
    wire at_a0, at_bhe_n;
    wire [1:0] at_byte_enable;
    wire [15:0] at_data_out;
    wire at_data_oe, at_write, at_io, at_inta, at_code_fetch, at_lock;
    wire at_accepted, at_completed, at_response_valid;
    logic at_accept = 1'b0;
    logic at_ready = 1'b0;
    logic [15:0] at_read_data = 16'd0;
    logic at_read_data_valid = 1'b0;
    wire bridge_idle, protocol_error;

    integer accept_count = 0;
    integer complete_count = 0;
    integer write_effects = 0;
    logic [23:0] held_address;
    logic [3:0] held_status;
    logic [1:0] held_lanes;
    logic held_write;
    logic held_lock;
    logic monitor_hold = 1'b0;
    integer command_wait_ticks = 0;

    always @(posedge clk) begin
        if (!reset) begin
            if (at_accepted) begin
                accept_count <= accept_count + 1;
                if (at_write)
                    write_effects <= write_effects + 1;
            end
            if (at_completed)
                complete_count <= complete_count + 1;
            if (monitor_hold && at_valid && !at_completed) begin
                if (at_address !== held_address || at_cycle_class !== held_status ||
                    at_byte_enable !== held_lanes || at_write !== held_write ||
                    at_lock !== held_lock)
                    $fatal(1, "AT metadata changed during READY wait");
            end
        end
    end

    spk286_at_bus_bridge dut (
        .clk(clk), .reset(reset),
        .cpu_bus_valid(cpu_bus_valid), .cpu_address(cpu_address),
        .cpu_data_out(cpu_data_out), .cpu_data_oe(cpu_data_oe),
        .cpu_bus_write(cpu_bus_write), .cpu_bus_bhe_n(cpu_bus_bhe_n),
        .cpu_bus_status(cpu_bus_status), .cpu_bus_lock(cpu_bus_lock),
        .cpu_memory_word_capable(cpu_memory_word_capable),
        .cpu_io_word_capable(cpu_io_word_capable),
        .cpu_ready(cpu_ready), .cpu_data_in(cpu_data_in),
        .at_valid(at_valid), .at_command_valid(at_command_valid),
        .at_owner(at_owner), .at_cycle_class(at_cycle_class),
        .at_address(at_address), .at_a0(at_a0), .at_bhe_n(at_bhe_n),
        .at_byte_enable(at_byte_enable), .at_data_out(at_data_out),
        .at_data_oe(at_data_oe), .at_write(at_write), .at_io(at_io),
        .at_inta(at_inta), .at_code_fetch(at_code_fetch),
        .at_lock(at_lock), .at_accepted(at_accepted),
        .at_completed(at_completed), .at_response_valid(at_response_valid),
        .at_accept(at_accept), .at_ready(at_ready),
        .at_read_data(at_read_data),
        .at_read_data_valid(at_read_data_valid),
        .bridge_idle(bridge_idle), .protocol_error(protocol_error)
    );

    task automatic check(input logic condition, input string message);
        if (!condition)
            $fatal(1, "CHECK_FAIL: %s", message);
    endtask

    task automatic start_request(
        input logic [23:0] address_value,
        input logic [3:0] status_value,
        input logic write_value,
        input logic bhe_n_value,
        input logic [15:0] data_value,
        input logic lock_value
    );
        begin
            @(negedge clk);
            cpu_address = address_value;
            cpu_bus_status = status_value;
            cpu_bus_write = write_value;
            cpu_data_oe = write_value;
            cpu_bus_bhe_n = bhe_n_value;
            cpu_data_out = data_value;
            cpu_bus_lock = lock_value;
            cpu_bus_valid = 1'b1;
        end
    endtask

    task automatic wait_command;
        integer deadline;
        begin
            command_wait_ticks = 0;
            for (deadline = 0; deadline < 100 && !at_command_valid;
                 deadline = deadline + 1) begin
                @(negedge clk);
                command_wait_ticks = command_wait_ticks + 1;
            end
            check(at_command_valid, "AT command phase did not start");
        end
    endtask

    task automatic accept_command;
        begin
            at_accept = 1'b1;
            @(negedge clk);
            at_accept = 1'b0;
        end
    endtask

    task automatic complete_read(
        input logic [15:0] data_value,
        output logic [15:0] response
    );
        integer deadline;
        begin
            at_read_data = data_value;
            at_read_data_valid = 1'b1;
            at_ready = 1'b1;
            for (deadline = 0; deadline < 100 && !cpu_ready;
                 deadline = deadline + 1)
                @(negedge clk);
            check(cpu_ready, "CPU read completion did not arrive");
            response = cpu_data_in;
            at_ready = 1'b0;
            at_read_data_valid = 1'b0;
            cpu_bus_valid = 1'b0;
            @(negedge clk);
        end
    endtask

    task automatic complete_write;
        integer deadline;
        begin
            at_ready = 1'b1;
            for (deadline = 0; deadline < 100 && !cpu_ready;
                 deadline = deadline + 1)
                @(negedge clk);
            check(cpu_ready, "CPU write completion did not arrive");
            at_ready = 1'b0;
            cpu_bus_valid = 1'b0;
            @(negedge clk);
        end
    endtask

    initial begin : run
        logic [15:0] response;
        integer before_accept;
        integer before_effects;

        repeat (3) @(posedge clk);
        reset = 1'b0;

        // READY/data-valid high before command acceptance is not a completion.
        at_ready = 1'b1;
        at_read_data_valid = 1'b1;
        at_read_data = 16'hDEAD;
        start_request(24'hFEDCBA, 4'hD, 1'b0, 1'b1, 16'd0, 1'b0);
        repeat (3) @(negedge clk);
        check(!cpu_ready && !at_accepted,
              "idle READY completed a fetch before command acceptance");
        wait_command();
        check(at_cycle_class == 4'hD && at_address == 24'hFEDCBA &&
              at_code_fetch && !at_io && at_byte_enable == 2'b01,
              "full AT fetch metadata was not retained");
        at_accept = 1'b1;
        @(negedge clk);
        at_accept = 1'b0;
        at_ready = 1'b0;
        at_read_data_valid = 1'b0;
        repeat (3) @(negedge clk);
        check(!cpu_ready, "fetch completed without a valid READY/data edge");
        held_address = at_address;
        held_status = at_cycle_class;
        held_lanes = at_byte_enable;
        held_write = at_write;
        held_lock = at_lock;
        monitor_hold = 1'b1;
        at_read_data = 16'h00A6;
        complete_read(16'h00A6, response);
        monitor_hold = 1'b0;
        check(response == 16'h00A6, "even fetch data was not lane-positioned");
        check(at_owner == 3'd0, "CPU owner encoding changed");

        // A locked aligned word remains one retained transaction while its two
        // independently accepted byte beats are completed.
        at_ready = 1'b0;
        at_read_data_valid = 1'b0;
        start_request(24'h123450, 4'h5, 1'b0, 1'b0, 16'd0, 1'b1);
        wait_command();
        check(at_address == 24'h123450 && at_byte_enable == 2'b01 && at_lock,
              "locked word low beat metadata was wrong");
        accept_command();
        repeat (2) @(negedge clk);
        check(!cpu_ready && at_address == 24'h123450 &&
              at_byte_enable == 2'b01 && at_lock,
              "low word beat did not retain address/lane/LOCK");
        at_read_data = 16'h0034;
        at_read_data_valid = 1'b1;
        at_ready = 1'b1;
        @(negedge clk);
        at_ready = 1'b0;
        at_read_data_valid = 1'b0;
        check(!cpu_ready && at_valid, "word completed after only one beat");
        wait_command();
        check(at_address == 24'h123451 && at_byte_enable == 2'b10 &&
              at_a0 && !at_bhe_n && at_lock,
              "locked word high beat metadata was wrong");
        accept_command();
        at_read_data = 16'h5600;
        at_read_data_valid = 1'b1;
        at_ready = 1'b1;
        for (integer deadline = 0; deadline < 100 && !cpu_ready;
             deadline = deadline + 1)
            @(negedge clk);
        check(cpu_ready && cpu_data_in == 16'h5634,
              "aligned word read assembly was wrong");
        check(at_lock, "LOCK dropped before CPU observed word completion");
        at_ready = 1'b0;
        at_read_data_valid = 1'b0;
        cpu_bus_valid = 1'b0;
        @(negedge clk);

        // Native x16 fetch/read/write: both lanes in one accepted operation,
        // held stable through wait states. Width is part of the snapshot.
        cpu_memory_word_capable = 1'b1;
        before_accept = accept_count;
        start_request(24'hFFFFF0, 4'hD, 1'b0, 1'b0, 16'd0, 1'b0);
        wait_command();
        if (EXPECT_P01_FAST_MEMORY_START)
            check(command_wait_ticks == 2,
                  "P01 did not remove the two memory-start states");
        else
            check(command_wait_ticks == 4,
                  "reference bridge memory-start latency changed");
        check(at_byte_enable == 2'b11 && !at_a0 && !at_bhe_n && at_code_fetch,
              "native code fetch did not select both lanes");
        cpu_memory_word_capable = 1'b0;
        accept_command();
        repeat (3) @(negedge clk);
        check(at_byte_enable == 2'b11 && !cpu_ready,
              "native width changed while waiting");
        complete_read(16'h5BEA, response);
        check(response == 16'h5BEA && accept_count == before_accept + 1,
              "native fetch did not complete in one beat");

        cpu_memory_word_capable = 1'b1;
        before_effects = write_effects;
        start_request(24'h012340, 4'h6, 1'b1, 1'b0, 16'hA53C, 1'b1);
        wait_command();
        check(at_byte_enable == 2'b11 && at_data_out == 16'hA53C && at_lock,
              "native word write lost data or LOCK");
        accept_command();
        complete_write();
        check(write_effects == before_effects + 1,
              "native write caused duplicate side effects");
        start_request(24'h012340, 4'h5, 1'b0, 1'b0, 16'd0, 1'b1);
        wait_command();
        accept_command();
        complete_read(16'hA53C, response);
        check(response == 16'hA53C, "native data read lost a lane");

        // A 16-bit OUT still splits even if the width input is asserted.
        before_effects = write_effects;
        start_request(24'h000300, 4'hA, 1'b1, 1'b0, 16'h9C47, 1'b0);
        wait_command();
        check(at_byte_enable == 2'b01 && at_data_out == 16'h0047,
              "I/O word low lane no longer serialized");
        accept_command();
        at_ready = 1'b1;
        @(negedge clk);
        at_ready = 1'b0;
        wait_command();
        check(at_address == 24'h000301 && at_byte_enable == 2'b10 &&
              at_data_out == 16'h9C00, "I/O word high lane incorrect");
        accept_command();
        complete_write();
        check(write_effects == before_effects + 2,
              "I/O word did not retain two byte operations");

        // High-lane byte writes drive only D15:8 and commit exactly once even
        // with READY held high after acceptance.
        before_effects = write_effects;
        start_request(24'h00ABCD, 4'hA, 1'b1, 1'b0, 16'h7E00, 1'b0);
        wait_command();
        check(at_io && at_write && at_byte_enable == 2'b10 &&
              at_data_out == 16'h7E00 && at_data_oe,
              "odd I/O write lane/data metadata was wrong");
        accept_command();
        complete_write();
        check(write_effects == before_effects + 1,
              "one accepted write caused a duplicate side effect");

        // Identical consecutive requests with bus_valid continuously high are
        // two requests, not one deduplicated level.
        before_accept = accept_count;
        at_ready = 1'b1;
        start_request(24'h000080, 4'h6, 1'b1, 1'b1, 16'h005A, 1'b0);
        wait_command();
        accept_command();
        while (!cpu_ready) @(negedge clk);
        while (cpu_ready) @(negedge clk);
        wait_command();
        accept_command();
        while (!cpu_ready) @(negedge clk);
        check(accept_count == before_accept + 2,
              "identical back-to-back requests were not both accepted");
        cpu_bus_valid = 1'b0;
        at_ready = 1'b0;
        @(negedge clk);

        // INTA has no ordinary lane operation and only the supplied second
        // request's data can become the CPU vector.
        at_ready = 1'b0;
        at_read_data_valid = 1'b0;
        start_request(24'd0, 4'h0, 1'b0, 1'b1, 16'd0, 1'b1);
        wait_command();
        check(at_inta && at_byte_enable == 2'b00 && at_lock,
              "first INTA metadata was wrong");
        accept_command();
        at_read_data = 16'h00FF;
        at_read_data_valid = 1'b1;
        at_ready = 1'b1;
        while (!cpu_ready) @(negedge clk);
        check(cpu_data_in == 16'h00FF, "first INTA response was not returned");
        at_ready = 1'b0;
        at_read_data_valid = 1'b0;
        cpu_bus_valid = 1'b0;
        @(negedge clk);

        start_request(24'd0, 4'h0, 1'b0, 1'b1, 16'd0, 1'b0);
        wait_command();
        accept_command();
        at_read_data = 16'h0042;
        at_read_data_valid = 1'b1;
        at_ready = 1'b1;
        while (!cpu_ready) @(negedge clk);
        check(cpu_data_in == 16'h0042,
              "second INTA vector was not sampled from D7:0");
        at_ready = 1'b0;
        at_read_data_valid = 1'b0;
        cpu_bus_valid = 1'b0;
        @(negedge clk);

        // Invalid A0/BHE must complete as a protocol error without emitting a
        // chipset record.
        before_accept = accept_count;
        start_request(24'h000101, 4'h5, 1'b0, 1'b1, 16'd0, 1'b0);
        repeat (3) @(negedge clk);
        check(cpu_ready && !at_valid && accept_count == before_accept &&
              protocol_error, "invalid lane fabricated an AT transaction");
        cpu_bus_valid = 1'b0;
        @(negedge clk);

        // Reset during a READY wait cancels the retained request and must not
        // replay the accepted command after reset release.
        at_ready = 1'b0;
        at_read_data_valid = 1'b0;
        start_request(24'h654320, 4'h6, 1'b1, 1'b1, 16'h00C3, 1'b0);
        wait_command();
        accept_command();
        repeat (3) @(negedge clk);
        before_accept = accept_count;
        reset = 1'b1;
        @(negedge clk);
        check(bridge_idle && !at_valid && !cpu_ready,
              "reset did not cancel an active AT request");
        reset = 1'b0;
        cpu_bus_valid = 1'b0;
        at_ready = 1'b1;
        repeat (4) @(negedge clk);
        check(accept_count == before_accept && bridge_idle,
              "reset replayed an accepted AT request");

        // The final command was deliberately accepted and then canceled by
        // reset, so it is not required to produce a completion edge. Earlier
        // completed commands must still have been observed independently.
        check(complete_count > 0 && complete_count < accept_count,
              "completion accounting did not distinguish reset abort");
        $display("A1_AT_BRIDGE_PASS accepts=%0d completes=%0d writes=%0d",
                 accept_count, complete_count, write_effects);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "CHECK_FAIL: global timeout");
    end
endmodule
