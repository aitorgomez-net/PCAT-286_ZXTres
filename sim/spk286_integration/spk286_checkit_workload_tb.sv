`timescale 1ns/1ps

// Directed CheckIt-like workload bench.
//
// This is intentionally a measurement bench, not a DOS emulator.  The ROM is
// supplied by the runner and contains a deterministic integer or fixed-point
// workload with the same dominant operation classes as CheckIt's Dhrystone
// and no-NPU Whetstone pages.  The production CPU, AT bridge, memory port,
// SDRAM owner and pin model remain in the path.  P03 can be toggled for an
// A/B comparison without changing the architectural workload.
module spk286_checkit_workload_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    logic cpu_reset = 1'b1;
    always #10 clk = ~clk;

    integer native_width = 1;
    integer p03_enable = 0;
    string workload_name = "unknown";

    wire [23:0] address;
    wire [15:0] data_out, data_in;
    wire data_oe, bus_valid, bus_write, bus_bhe_n, bus_lock, ready;
    wire [3:0] bus_status;
    wire halted, shutdown, control_error, unsupported, microcode_fault;
    wire retired;
    wire [15:0] instruction_ip, cs;
    wire [127:0] gpr;
    wire [3:0] prefetch_count;
    wire width_capable;

    wire at_valid, at_command, at_write, at_code;
    wire at_accept, at_ready, at_read_valid, bridge_error;
    wire [23:0] at_address;
    wire [1:0] at_lanes;
    wire [15:0] at_out, at_in;
    wire [3:0] at_class;

    wire backend_valid, backend_command, backend_write, backend_refresh;
    wire backend_code, backend_accept, backend_ready, backend_read_valid;
    wire [1:0] backend_owner;
    wire [23:0] backend_address;
    wire [1:0] backend_lanes;
    wire [15:0] backend_out, backend_in;
    wire [3:0] backend_class;
    wire port_error, owner_error, physical_idle;

    wire p03_out_valid, p03_out_command;
    wire [1:0] p03_out_owner;
    wire p03_out_write, p03_out_refresh, p03_out_code, p03_out_burst;
    wire [3:0] p03_out_class;
    wire [23:0] p03_out_address;
    wire [1:0] p03_out_lanes;
    wire [15:0] p03_out_data;
    wire p03_in_accept, p03_in_ready, p03_in_read_valid;
    wire [15:0] p03_in_data;
    wire p03_out_accept, p03_out_ready, p03_out_read_valid;
    wire [15:0] p03_out_read_data;
    wire [31:0] p03_hits, p03_misses, p03_fills, p03_physical_reads;
    wire [31:0] p03_invalidations;

    wire [12:0] dram_address;
    wire dram_cke, dram_cs, dram_ras, dram_cas, dram_we, dram_oe;
    wire [1:0] dram_ba, dram_dqm, dq_valid;
    wire [15:0] dram_in, dram_out;
    wire integer dram_reads, dram_writes;

    spk286_machine_cpu cpu (
        .clk(clk), .reset(cpu_reset), .execute_enable(1'b1),
        .ready(ready), .data_in(data_in), .intr(1'b0), .nmi(1'b0),
        .hold_request(1'b0), .address(address), .data_out(data_out),
        .data_oe(data_oe), .bus_valid(bus_valid), .bus_write(bus_write),
        .bus_bhe_n(bus_bhe_n), .bus_status(bus_status), .bus_lock(bus_lock),
        .halted(halted), .shutdown(shutdown), .control_error(control_error),
        .unsupported_opcode(unsupported), .microcode_fault(microcode_fault),
        .debug_instruction_retired(retired), .debug_instruction_ip(instruction_ip),
        .debug_cs(cs), .debug_gpr(gpr), .debug_prefetch_count(prefetch_count)
    );

    spk286_at_memory_decode width_decode (
        .request_valid(bus_valid), .request_write(bus_write),
        .cycle_class(bus_status), .address(address), .word_capable(width_capable)
    );

    spk286_at_bus_bridge bridge (
        .clk(clk), .reset(cpu_reset), .cpu_bus_valid(bus_valid),
        .cpu_address(address), .cpu_data_out(data_out), .cpu_data_oe(data_oe),
        .cpu_bus_write(bus_write), .cpu_bus_bhe_n(bus_bhe_n),
        .cpu_bus_status(bus_status), .cpu_bus_lock(bus_lock),
        .cpu_memory_word_capable(width_capable && native_width != 0),
        .cpu_io_word_capable(1'b0),
        .cpu_ready(ready), .cpu_data_in(data_in),
        .at_valid(at_valid), .at_command_valid(at_command),
        .at_cycle_class(at_class), .at_address(at_address),
        .at_byte_enable(at_lanes), .at_data_out(at_out), .at_write(at_write),
        .at_code_fetch(at_code), .at_accept(at_accept), .at_ready(at_ready),
        .at_read_data(at_in), .at_read_data_valid(at_read_valid),
        .protocol_error(bridge_error)
    );

    spk286_at_mister_memory_port memory_port (
        .clk(clk), .reset(reset), .cancel_cpu(cpu_reset),
        .cpu_valid(at_valid), .cpu_command_valid(at_command),
        .cpu_write(at_write), .cpu_code_fetch(at_code),
        .cpu_cycle_class(at_class), .cpu_address(at_address),
        .cpu_byte_enable(at_lanes), .cpu_data_out(at_out),
        .cpu_accept(at_accept), .cpu_ready(at_ready),
        .cpu_read_data(at_in), .cpu_read_data_valid(at_read_valid),
        .loader_valid(1'b0), .loader_write(1'b0), .loader_address(24'd0),
        .loader_byte_enable(2'b00), .loader_data_out(16'd0),
        .loader_accept(), .loader_ready(), .loader_read_data(),
        .dma_valid(1'b0), .dma_write(1'b0), .dma_address(24'd0),
        .dma_byte_enable(2'b00), .dma_data_out(16'd0),
        .dma_accept(), .dma_ready(), .dma_read_data(),
        .refresh_valid(1'b0), .refresh_address(24'd0),
        .refresh_accept(), .refresh_ready(),
        .backend_valid(backend_valid), .backend_command_valid(backend_command),
        .backend_owner(backend_owner), .backend_write(backend_write),
        .backend_refresh(backend_refresh), .backend_code_fetch(backend_code),
        .backend_cycle_class(backend_class), .backend_address(backend_address),
        .backend_byte_enable(backend_lanes), .backend_data_out(backend_out),
        .backend_accept(p03_in_accept), .backend_ready(p03_in_ready),
        .backend_read_data(p03_in_data),
        .backend_read_data_valid(p03_in_read_valid),
        .protocol_error(port_error)
    );

    spk286_at_sdram_read_buffer #(.ENABLE(1'b1)) p03_buffer (
        .clk(clk), .reset(reset), .cancel_cpu(cpu_reset),
        .enable(p03_enable != 0),
        .in_valid(backend_valid), .in_command_valid(backend_command),
        .in_owner(backend_owner), .in_write(backend_write),
        .in_refresh(backend_refresh), .in_code_fetch(backend_code),
        .in_cycle_class(backend_class), .in_address(backend_address),
        .in_byte_enable(backend_lanes), .in_data_out(backend_out),
        .in_accept(p03_in_accept), .in_ready(p03_in_ready),
        .in_read_data(p03_in_data), .in_read_data_valid(p03_in_read_valid),
        .out_valid(p03_out_valid), .out_command_valid(p03_out_command),
        .out_owner(p03_out_owner), .out_write(p03_out_write),
        .out_refresh(p03_out_refresh), .out_code_fetch(p03_out_code),
        .out_burst(p03_out_burst), .out_cycle_class(p03_out_class),
        .out_address(p03_out_address), .out_byte_enable(p03_out_lanes),
        .out_data_out(p03_out_data), .out_accept(p03_out_accept),
        .out_ready(p03_out_ready), .out_read_data(p03_out_read_data),
        .out_read_data_valid(p03_out_read_valid),
        .debug_hit_count(p03_hits), .debug_miss_count(p03_misses),
        .debug_fill_count(p03_fills),
        .debug_physical_read_count(p03_physical_reads),
        .debug_invalidation_count(p03_invalidations)
    );

    spk286_at_mister_sdram_owner #(.SDRAM_INIT_WAIT(16'd8)) owner (
        .clk(clk), .reset(reset), .request_valid(p03_out_valid),
        .request_command_valid(p03_out_command),
        .request_owner_refresh(p03_out_refresh), .request_write(p03_out_write),
        .request_code_fetch(p03_out_code), .request_burst(p03_out_burst),
        .request_cycle_class(p03_out_class), .request_address(p03_out_address),
        .request_byte_enable(p03_out_lanes), .request_data_out(p03_out_data),
        .request_accept(p03_out_accept), .request_ready(p03_out_ready),
        .request_read_data(p03_out_read_data),
        .request_read_data_valid(p03_out_read_valid),
        .physical_idle(physical_idle), .protocol_error(owner_error),
        .sdram_address(dram_address), .sdram_cke(dram_cke),
        .sdram_cs(dram_cs), .sdram_ras(dram_ras), .sdram_cas(dram_cas),
        .sdram_we(dram_we), .sdram_ba(dram_ba), .sdram_dq_in(dram_in),
        .sdram_dq_out(dram_out), .sdram_dq_io(dram_oe),
        .sdram_ldqm(dram_dqm[0]), .sdram_udqm(dram_dqm[1])
    );

    spk286_sdram_pin_model dram (
        .clk(clk), .reset(reset), .address(dram_address), .cke(dram_cke),
        .cs_n(dram_cs), .ras_n(dram_ras), .cas_n(dram_cas), .we_n(dram_we),
        .ba(dram_ba), .dq_from_controller(dram_out),
        .controller_dq_oe(!dram_oe), .dqm(dram_dqm),
        .dq_to_controller(dram_in), .dq_valid(dq_valid),
        .read_count(dram_reads), .write_count(dram_writes)
    );

    integer cycles = 0;
    integer instructions = 0;
    integer reads = 0;
    integer writes = 0;
    integer code_fetches = 0;
    integer external_wait = 0;
    integer queue_empty = 0;
    integer stage = 0;
    integer stage_cycles = 0;
    integer stage_instructions = 0;
    integer stage_reads = 0;
    integer stage_writes = 0;
    integer stage_code_fetches = 0;
    integer stage_external_wait = 0;

    task automatic report_stage;
        $display("CHECKIT_STAGE workload=%s p03=%0d stage=%0d cycles=%0d retired=%0d reads=%0d writes=%0d code_fetches=%0d external_wait=%0d queue_empty=%0d",
            workload_name, p03_enable, stage, cycles-stage_cycles,
            instructions-stage_instructions, reads-stage_reads,
            writes-stage_writes, code_fetches-stage_code_fetches,
            external_wait-stage_external_wait, queue_empty);
    endtask

    always @(posedge clk) begin
        if (!cpu_reset) begin
            cycles = cycles + 1;
            if (prefetch_count == 0)
                queue_empty = queue_empty + 1;
            if (bus_valid && !ready)
                external_wait = external_wait + 1;
            if (bus_valid && ready) begin
                if (bus_write)
                    writes = writes + 1;
                else begin
                    reads = reads + 1;
                    if (at_code)
                        code_fetches = code_fetches + 1;
                end
            end
            if (at_code && bus_valid && !ready)
                code_fetches = code_fetches + 1;
            if (bridge_error || port_error || owner_error || control_error ||
                unsupported || microcode_fault || shutdown)
                $fatal(1, "CHECKIT protocol/CPU fault workload=%s cs=%h ip=%h",
                    workload_name, cs, instruction_ip);

            if (retired) begin
                instructions = instructions + 1;
                if (cs == 16'hF000 && instruction_ip >= 16'h0100 &&
                    instruction_ip <= 16'h0500 && instruction_ip[7:0] == 0) begin
                    if (stage != 0)
                        report_stage();
                    stage = int'(instruction_ip[15:8]);
                    stage_cycles = cycles;
                    stage_instructions = instructions;
                    stage_reads = reads;
                    stage_writes = writes;
                    stage_code_fetches = code_fetches;
                    stage_external_wait = external_wait;
                end
            end

            if (halted) begin
                if (stage != 5 || gpr[15:0] != 16'h600D)
                    $fatal(1, "CHECKIT result failed workload=%s AX=%h stage=%0d",
                        workload_name, gpr[15:0], stage);
                for (integer i = 0; i < 256; i = i + 1)
                    if (dram.mem['h1000+i] !== 16'(i+1))
                        $fatal(1, "CHECKIT result memory mismatch workload=%s index=%0d",
                            workload_name, i);
                for (integer i = 0; i < 1024; i = i + 1)
                    if (dram.mem['h2000+i] !== 16'hA55A)
                        $fatal(1, "CHECKIT string mismatch workload=%s index=%0d",
                            workload_name, i);
                report_stage();
                $display("CHECKIT_DIRECTED_PASS workload=%s p03=%0d cycles=%0d retired=%0d reads=%0d writes=%0d code_fetches=%0d external_wait=%0d queue_empty=%0d sdram_reads=%0d sdram_writes=%0d hits=%0d misses=%0d fills=%0d physical_reads=%0d invalidations=%0d",
                    workload_name, p03_enable, cycles, instructions, reads,
                    writes, code_fetches, external_wait, queue_empty,
                    dram_reads, dram_writes, p03_hits, p03_misses, p03_fills,
                    p03_physical_reads, p03_invalidations);
                $finish;
            end
            if (cycles > 4000000)
                $fatal(1, "CHECKIT timeout workload=%s cs=%h ip=%h",
                    workload_name, cs, instruction_ip);
        end
    end

    byte unsigned rom [0:65535];
    string rom_path;
    integer fd, count;
    initial begin
        if (!$value$plusargs("ROM=%s", rom_path))
            $fatal(1, "ROM path required");
        if ($value$plusargs("NATIVE=%d", native_width)) begin end
        if ($value$plusargs("P03=%d", p03_enable)) begin end
        if ($value$plusargs("NAME=%s", workload_name)) begin end
        fd = $fopen(rom_path, "rb");
        if (!fd)
            $fatal(1, "Cannot open ROM %s", rom_path);
        count = $fread(rom, fd);
        $fclose(fd);
        if (count != 65536)
            $fatal(1, "ROM must be 64 KiB, got %0d", count);
        for (integer i = 0; i < 32768; i = i + 1)
            dram.mem['h78000+i] = {rom[i*2+1], rom[i*2]};
        repeat (4) @(negedge clk);
        reset = 1'b0;
        wait (physical_idle);
        @(negedge clk);
        cpu_reset = 1'b0;
    end
endmodule
