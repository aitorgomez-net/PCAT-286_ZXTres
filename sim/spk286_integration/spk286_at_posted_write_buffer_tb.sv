`timescale 1ns/1ps
module spk286_at_posted_write_buffer_tb;
    logic clk = 0, reset = 1, cancel_cpu = 0, cpu_lock = 0;
    always #5 clk = ~clk;
    logic in_valid = 0, in_command_valid = 0, in_write = 1;
    logic in_refresh = 0, in_code_fetch = 0, in_burst = 0;
    logic [1:0] in_owner = 0, in_byte_enable = 3;
    logic [3:0] in_cycle_class = 6;
    logic [24:0] in_address = 25'h1234;
    logic [15:0] in_data_out = 16'hABCD;
    wire in_accept, in_ready, in_read_data_valid;
    wire [15:0] in_read_data;
    wire out_valid, out_command_valid, out_write, out_refresh, out_code_fetch, out_burst;
    wire [1:0] out_owner, out_byte_enable;
    wire [3:0] out_cycle_class;
    wire [24:0] out_address;
    wire [15:0] out_data_out;
    logic out_accept = 0, out_ready = 0, out_read_data_valid = 0;
    logic [15:0] out_read_data = 16'hBEEF;
    wire pending_write, idle, protocol_error;
    wire [31:0] posts, drains, stalls;
    integer checks = 0;
    spk286_at_posted_write_buffer dut (
        .debug_post_count(posts), .debug_drain_count(drains), .debug_stall_count(stalls), .*
    );
    task check(input logic condition, input string message);
        checks = checks + 1;
        if (!condition) $fatal(1, "POSTED_BUFFER_FAIL %s", message);
    endtask
    task step;
        @(posedge clk); #1;
    endtask
    task request(input logic expected_accept);
        @(negedge clk); in_valid = 1; in_command_valid = 1; #1;
        check(in_accept == expected_accept, "entry acceptance");
    endtask
    task withdraw;
        @(negedge clk); in_valid = 0; in_command_valid = 0;
    endtask
    task finish_write;
        @(negedge clk); out_accept = 1; #1;
        check(out_command_valid, "retained physical command");
        step();
        @(negedge clk); out_accept = 0; out_ready = 1;
        step();
        check(idle, "physical completion releases owner");
        @(negedge clk); out_ready = 0;
    endtask
    initial begin
        repeat (2) step();
        @(negedge clk); reset = 0;
        // A posted write acknowledges once even while physical acceptance
        // is stalled. CPU-local cancellation must still drain that record.
        request(1); step();
        check(in_ready && pending_write && !idle, "single early posted ack");
        withdraw(); in_address = 25'h9999; in_data_out = 16'h5555; cancel_cpu = 1;
        step();
        check(!in_ready && !in_accept, "ack is not repeated");
        check(out_valid && out_command_valid && out_address == 25'h1234 &&
              out_data_out == 16'hABCD && out_byte_enable == 3, "retained cancelled posted payload");
        finish_write(); cancel_cpu = 0;
        check(posts == 1 && drains == 1, "one posted physical drain");
        // Same-edge physical admission leaves a retained owner until READY.
        in_address = 25'h2345; in_data_out = 16'hA500; in_byte_enable = 2;
        out_accept = 1; request(1); step();
        check(in_ready && !out_command_valid && out_address == 25'h2345 &&
              out_byte_enable == 2, "same-edge physical acceptance");
        withdraw(); out_accept = 0; step();
        check(!in_ready && pending_write, "wait for real physical completion");
        @(negedge clk); out_ready = 1; step();
        check(idle && posts == 2 && drains == 2, "second drain counted once");
        @(negedge clk); out_ready = 0;
        // LOCK and non-CPU traffic cannot post. They wait for the physical
        // acceptance and completion, while retaining their own payload.
        cpu_lock = 1; in_byte_enable = 3; request(0);
        check(out_valid && out_command_valid && !pending_write, "LOCK stalled bypass");
        @(negedge clk); out_accept = 1; #1; check(in_accept, "LOCK physical acceptance");
        step(); withdraw(); out_accept = 0;
        check(!in_ready && !pending_write && !idle, "LOCK cannot acknowledge early");
        @(negedge clk); out_ready = 1; #1; check(in_ready, "LOCK physical ready");
        step(); check(idle, "LOCK release");
        @(negedge clk); out_ready = 0; cpu_lock = 0; in_owner = 1; cancel_cpu = 1;
        out_accept = 1; request(1); step(); withdraw(); out_accept = 0;
        check(!pending_write && out_owner == 1 && !in_ready, "DMA bypass unaffected by CPU cancel");
        @(negedge clk); out_ready = 1; step(); check(idle, "DMA completion");
        @(negedge clk); out_ready = 0; cancel_cpu = 0; in_owner = 0;
        // Burst data-valid is independent of final READY.
        in_write = 0; in_code_fetch = 1; in_burst = 1; in_cycle_class = 13;
        out_accept = 1; request(1); step(); withdraw(); out_accept = 0;
        check(!pending_write && !in_ready && out_burst && out_code_fetch, "code burst bypass");
        @(negedge clk); out_read_data_valid = 1; out_read_data = 16'h1357; #1;
        check(in_read_data_valid && in_read_data == 16'h1357 && !in_ready, "intermediate burst beat");
        step(); @(negedge clk); out_read_data_valid = 0; #1;
        check(!in_read_data_valid && !in_ready, "gap is not completion");
        out_read_data_valid = 1; out_ready = 1; #1;
        check(in_ready && in_read_data_valid, "final beat and ready");
        step(); check(idle, "burst release");
        @(negedge clk); out_ready = 0; out_read_data_valid = 0;
        // An unaccepted CPU command is blocked by cancellation.
        in_write = 1; in_code_fetch = 0; in_burst = 0; in_cycle_class = 6; cancel_cpu = 1;
        request(0); check(!out_valid && !out_command_valid, "cancelled idle command blocked");
        withdraw(); cancel_cpu = 0;
        // Global reset clears this owner with its physical controller.
        request(1); step(); withdraw();
        @(negedge clk); reset = 1; step();
        check(idle && !out_valid && !pending_write && !in_ready &&
              posts == 0 && drains == 0 && stalls == 0, "global reset discards record without replay");
        @(negedge clk); reset = 0; step();
        check(!out_valid && !protocol_error, "clean reset release");
        $display("POSTED_WRITE_BUFFER_PASS checks=%0d", checks);
        $finish;
    end
    initial begin #20000; $fatal(1, "posted buffer watchdog"); end
endmodule
