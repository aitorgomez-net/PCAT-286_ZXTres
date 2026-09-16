`timescale 1ns/1ps

module spk286_at_sdram_read_buffer_tb;
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
    logic [23:0] in_address = 24'h000000;
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
    wire [23:0]  out_address;
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

    localparam integer MEM_WORDS = 1048576;
    logic [15:0] mem [0:MEM_WORDS-1];
    logic        backend_active_q = 1'b0;
    logic        backend_burst_q = 1'b0;
    logic        backend_write_q = 1'b0;
    logic [1:0]  backend_beat_q = 2'd0;
    integer backend_reads = 0;
    integer backend_writes = 0;

    assign out_accept = out_valid && out_command_valid && !backend_active_q;
    assign out_read_data = mem[out_address[20:1] + backend_beat_q];
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
                        mem[out_address[20:1]][7:0] <= out_data_out[7:0];
                    if (out_byte_enable[1])
                        mem[out_address[20:1]][15:8] <= out_data_out[15:8];
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
        .debug_invalidation_count(invalidation_count)
    );

    task automatic check(input logic condition, input string message);
        begin
            if (!condition) begin
                $display("P03_BUFFER_FAIL %s", message);
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
                                input logic [23:0] address,
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
                  "read data mismatch");
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    task automatic write_request(input logic [1:0] owner,
                                 input logic [23:0] address,
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

    initial begin
        for (integer i = 0; i < MEM_WORDS; i = i + 1)
            mem[i] = 16'h0000;

        mem['h0800] = 16'hA001;
        mem['h0801] = 16'hA002;
        mem['h0802] = 16'hA003;
        mem['h0803] = 16'hA004;
        mem['h7FFF8] = 16'hB001;
        mem['h7FFF9] = 16'hB002;
        mem['h7FFFA] = 16'hB003;
        mem['h7FFFB] = 16'hB004;
        mem['h50000] = 16'hE001;

        repeat (3) @(posedge clk);
        reset = 1'b0;

        // First code read fills four words; the next words are hits.
        read_request(OWNER_CPU, 1'b1, 24'h001000, 16'hA001);
        check(physical_read_count == 4, "miss did not fill four physical words");
        read_request(OWNER_CPU, 1'b1, 24'h001002, 16'hA002);
        read_request(OWNER_CPU, 1'b1, 24'h001006, 16'hA004);
        check(hit_count == 2, "line hits were not counted");
        check(physical_read_count == 4, "hit caused an unexpected physical read");

        // A normal write invalidates the line before it can be hit again.
        write_request(OWNER_CPU, 24'h001000, 2'b01, 16'h00CC);
        check(mem['h0800] == 16'hA0CC, "byte write did not reach backend");
        read_request(OWNER_CPU, 1'b1, 24'h001000, 16'hA0CC);
        check(physical_read_count == 8, "write did not invalidate the line");

        // Data reads bypass the line even in a cacheable RAM region.
        read_request(OWNER_CPU, 1'b0, 24'h001000, 16'hA0CC);
        check(physical_read_count == 9, "data read was incorrectly cached");

        // A DMA write also invalidates a code line.
        write_request(OWNER_DMA, 24'h001002, 2'b01, 16'h00DD);
        read_request(OWNER_CPU, 1'b1, 24'h001000, 16'hA0CC);
        check(physical_read_count == 13, "DMA write did not invalidate the line");

        // Reset-vector alias and normal BIOS address share one canonical tag.
        read_request(OWNER_CPU, 1'b1, 24'hFFFFF0, 16'hB001);
        check(physical_read_count == 17, "BIOS alias fill was incorrect");
        read_request(OWNER_CPU, 1'b1, 24'h0FFFF2, 16'hB002);
        check(physical_read_count == 17, "BIOS alias did not hit canonical line");

        // EGA aperture is never eligible for read-ahead.
        read_request(OWNER_CPU, 1'b1, 24'h0A0000, 16'hE001);
        read_request(OWNER_CPU, 1'b1, 24'h0A0000, 16'hE001);
        check(physical_read_count == 19, "EGA aperture was incorrectly cached");

        // Machine reset also covers the BIOS-loading window.  CPU traffic is
        // cancelled there, but loader writes must still reach SDRAM or the
        // video pipeline will remain held in reset waiting for main_rom_loaded.
        cancel_cpu = 1'b1;
        write_request(OWNER_LOADER, 24'h0F0000, 2'b11, 16'h5AA5);
        check(mem['h78000] == 16'h5AA5,
              "loader write was blocked by CPU cancellation");
        cancel_cpu = 1'b0;

        check(miss_count >= 4, "misses were not counted");
        check(fill_count >= 4, "fills were not counted");
        check(invalidation_count >= 2, "write invalidations were not counted");
        $display("P03_BUFFER_PASS hits=%0d misses=%0d fills=%0d physical_reads=%0d backend_reads=%0d backend_writes=%0d invalidations=%0d",
                 hit_count, miss_count, fill_count, physical_read_count,
                 backend_reads, backend_writes, invalidation_count);
        $finish;
    end
endmodule
