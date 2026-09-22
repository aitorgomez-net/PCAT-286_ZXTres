`timescale 1ns/1ps

// Positive regression for the three previously reproduced coherence failures.
// Every case must now complete successfully against production RTL.
module spk286_code_buffer_coherence_audit_tb;
    localparam logic [1:0] OWNER_CPU = 2'd0;
    localparam logic [1:0] OWNER_DMA = 2'd1;
    localparam logic [1:0] OWNER_LOADER = 2'd3;

    logic clk = 1'b0;
    logic reset = 1'b1;
    logic cancel_cpu = 1'b0;
    logic enable = 1'b1;
    always #5 clk = ~clk;

    logic        in_valid = 1'b0;
    logic        in_command_valid = 1'b0;
    logic [1:0]  in_owner = OWNER_CPU;
    logic        in_write = 1'b0;
    logic        in_refresh = 1'b0;
    logic        in_code_fetch = 1'b0;
    logic [3:0]  in_cycle_class = 4'h5;
    logic [24:0] in_address = 25'h0000000;
    logic [1:0]  in_byte_enable = 2'b11;
    logic [15:0] in_data_out = 16'h0000;
    wire         in_accept;
    wire         in_ready;
    wire [15:0]  in_read_data;
    wire         in_read_data_valid;

    wire         out_valid;
    wire         out_command_valid;
    wire [1:0]   out_owner;
    wire         out_write;
    wire         out_refresh;
    wire         out_code_fetch;
    wire         out_burst;
    wire [3:0]   out_cycle_class;
    wire [24:0]  out_address;
    wire [1:0]   out_byte_enable;
    wire [15:0]  out_data_out;
    wire         out_accept;
    wire         out_ready;
    wire [15:0]  out_read_data;
    wire         out_read_data_valid;

    wire [31:0] hit_count;
    wire [31:0] miss_count;
    wire [31:0] fill_count;
    wire [31:0] physical_read_count;
    wire [31:0] invalidation_count;

    localparam integer MEM_WORDS = 4096;
    logic [15:0] mem [0:MEM_WORDS-1];
    logic        backend_active_q = 1'b0;
    logic        backend_burst_q = 1'b0;
    logic        backend_write_q = 1'b0;
    logic [1:0]  backend_beat_q = 2'd0;
    integer backend_reads = 0;
    integer backend_writes = 0;

    assign out_accept = out_valid && out_command_valid && !backend_active_q;
    assign out_read_data = mem[out_address[24:1] + backend_beat_q];
    assign out_read_data_valid = backend_active_q && !backend_write_q;
    assign out_ready = backend_active_q &&
                       (backend_write_q || !backend_burst_q ||
                        (backend_beat_q == 2'd3));

    // Registered-command backend. It represents the physical owner
    // protocol, not a combinational array shortcut.
    always_ff @(posedge clk) begin
        if (reset) begin
            backend_active_q <= 1'b0;
            backend_burst_q  <= 1'b0;
            backend_write_q  <= 1'b0;
            backend_beat_q   <= 2'd0;
            backend_reads    <= 0;
            backend_writes   <= 0;
        end else begin
            if (out_accept) begin
                backend_active_q <= 1'b1;
                backend_burst_q  <= out_burst;
                backend_write_q  <= out_write;
                backend_beat_q   <= 2'd0;
                if (out_write) begin
                    if (out_byte_enable[0])
                        mem[out_address[24:1]][7:0] <= out_data_out[7:0];
                    if (out_byte_enable[1])
                        mem[out_address[24:1]][15:8] <= out_data_out[15:8];
                    backend_writes <= backend_writes + 1;
                end else begin
                    backend_reads <= backend_reads + 1;
                end
            end else if (backend_active_q && out_ready) begin
                backend_active_q <= 1'b0;
            end else if (backend_active_q && backend_burst_q) begin
                backend_beat_q <= backend_beat_q + 2'd1;
            end
        end
    end

    spk286_at_sdram_read_buffer dut (
        .clk(clk), .reset(reset), .cancel_cpu(cancel_cpu), .enable(enable),
        .in_valid(in_valid), .in_command_valid(in_command_valid),
        .in_owner(in_owner), .in_write(in_write), .in_refresh(in_refresh),
        .in_code_fetch(in_code_fetch), .in_cycle_class(in_cycle_class),
        .in_address(in_address), .in_byte_enable(in_byte_enable),
        .in_data_out(in_data_out), .in_accept(in_accept), .in_ready(in_ready),
        .in_read_data(in_read_data), .in_read_data_valid(in_read_data_valid),
        .out_valid(out_valid), .out_command_valid(out_command_valid),
        .out_owner(out_owner), .out_write(out_write), .out_refresh(out_refresh),
        .out_code_fetch(out_code_fetch), .out_burst(out_burst),
        .out_cycle_class(out_cycle_class),
        .out_address(out_address), .out_byte_enable(out_byte_enable),
        .out_data_out(out_data_out), .out_accept(out_accept),
        .out_ready(out_ready), .out_read_data(out_read_data),
        .out_read_data_valid(out_read_data_valid),
        .debug_hit_count(hit_count), .debug_miss_count(miss_count),
        .debug_fill_count(fill_count),
        .debug_physical_read_count(physical_read_count),
        .debug_invalidation_count(invalidation_count), .debug_state()
    );

    task automatic check(input logic condition, input string message);
        begin
            if (!condition) begin
                $display("COHERENCE_AUDIT_ASSERT %s", message);
                $fatal(1);
            end
        end
    endtask

    task automatic wait_accept;
        integer guard;
        begin
            guard = 0;
            while (!in_accept && guard < 1000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            check(in_accept, "request was not accepted");
        end
    endtask

    task automatic wait_ready;
        integer guard;
        begin
            guard = 0;
            while (!in_ready && guard < 1000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            check(in_ready, "request did not complete");
        end
    endtask

    task automatic read_request(input logic [1:0] owner,
                                input logic code_fetch,
                                input logic [24:0] address,
                                input logic [15:0] expected);
        begin
            @(negedge clk);
            in_owner = owner;
            in_write = 1'b0;
            in_refresh = 1'b0;
            in_code_fetch = code_fetch;
            in_address = address;
            in_byte_enable = 2'b11;
            in_data_out = 16'h0000;
            in_valid = 1'b1;
            in_command_valid = 1'b1;
            wait_accept();
            @(negedge clk);
            in_command_valid = 1'b0;
            wait_ready();
            check(in_read_data_valid && in_read_data == expected,
                  $sformatf("case=%0d stale_code expected=%04h actual=%04h", audit_case, expected, in_read_data));
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    task automatic write_request(input logic [1:0] owner,
                                 input logic [24:0] address,
                                 input logic [1:0] lanes,
                                 input logic [15:0] data);
        begin
            @(negedge clk);
            in_owner = owner;
            in_write = 1'b1;
            in_refresh = 1'b0;
            in_code_fetch = 1'b0;
            in_address = address;
            in_byte_enable = lanes;
            in_data_out = data;
            in_valid = 1'b1;
            in_command_valid = 1'b1;
            wait_accept();
            @(negedge clk);
            in_command_valid = 1'b0;
            wait_ready();
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    integer audit_case = 0;
    integer reads_before;
    initial begin
        if ($value$plusargs("CASE=%d", audit_case)) begin end
        check(audit_case >= 0 && audit_case <= 2, "Unknown audit CASE");
        mem['h0800] = 16'hA001;
        mem['h0801] = 16'hA002;
        mem['h0802] = 16'hA003;
        mem['h0803] = 16'hA004;
        repeat (3) @(negedge clk);
        reset = 0;
        read_request(OWNER_CPU, 1'b1, 25'h0001006, 16'hA004);
        check(physical_read_count == 4, "precondition: fill did not finish");
        if (audit_case == 0 || audit_case == 2) begin
            write_request(audit_case == 0 ? OWNER_CPU : OWNER_DMA,
                          25'h0001007, 2'b10, 16'hCC00);
            check(mem['h0803] == 16'hCC04, "backend byte write failed");
            $display("AUDIT_ODD_UPPER owner=%0d backend_word=%04h",
                     audit_case == 0 ? OWNER_CPU : OWNER_DMA,
                     mem['h0803]);
            read_request(OWNER_CPU, 1'b1, 25'h0001006, 16'hCC04);
            check(physical_read_count == 8, "odd upper byte failed to invalidate line");
        end else if (audit_case == 1) begin
            reads_before = physical_read_count;
            @(negedge clk);
            check(dut.state_q == 0, "precondition: buffer not idle");
            cancel_cpu = 1;
            repeat (2) @(negedge clk);
            cancel_cpu = 0;
            $display("AUDIT_IDLE_CANCEL valid_after_cancel=%b", dut.line_valid_q);
            read_request(OWNER_CPU, 1'b1, 25'h0001000, 16'hA001);
            $display("AUDIT_IDLE_CANCEL physical_reads_before=%0d after=%0d hits=%0d",
                     reads_before, physical_read_count, hit_count);
            check(physical_read_count == reads_before+4,
                  "CPU reset in IDLE did not invalidate the line (P03-R15)");
        end
        $display("PRODUCTION_AUDIT_PASS case=%0d", audit_case);
        $finish;
    end
endmodule
