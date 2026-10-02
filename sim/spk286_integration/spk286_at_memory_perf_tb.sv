`timescale 1ns/1ps

// Actual SPK286 + production bridge/memory port/KFSDRAM + pin-level SDRAM.
// +NATIVE=0 restores the previous two-byte bridge for an A/B comparison.
// Device/IRQ traffic is deliberately absent to isolate CPU/memory throughput.
module spk286_at_memory_perf_tb;
    logic clk = 0, reset = 1, cpu_reset = 1;
    always #10 clk = ~clk; // Production AT clock: 50 MHz.
    integer native_width = 1;
    wire [23:0] address;
    wire [15:0] data_out, data_in;
    wire data_oe, bus_valid, bus_write, bus_bhe_n, bus_lock, ready;
    wire [3:0] bus_status;
    wire halted, shutdown, control_error, unsupported, microcode_fault;
    wire retired;
    wire [15:0] instruction_ip, cs;
    wire [15:0] next_ip, flags;
    wire [127:0] gpr;
    wire [3:0] prefetch_count;
    wire width_capable;
    wire at_valid, at_command, at_write, at_code, at_accept, at_ready;
    wire at_read_valid, bridge_error;
    wire [23:0] at_address;
    // This reduced bench omits spk286_at_machine, which canonicalizes the
    // reset-vector BIOS alias before the 25-bit physical memory interface.
    wire [24:0] mapped_at_address = at_address[23:16] == 8'hFF
        ? {9'h00F, at_address[15:0]} : {1'b0, at_address};
    wire [1:0] at_lanes;
    wire [15:0] at_out, at_in;
    wire [3:0] at_class;
    wire backend_valid, backend_command, backend_write, backend_refresh;
    wire backend_code, backend_accept, backend_ready, backend_read_valid;
    wire [24:0] backend_address;
    wire [1:0] backend_lanes;
    wire [15:0] backend_out, backend_in;
    wire [3:0] backend_class;
    wire port_error, owner_error, physical_idle;
    wire        p03_out_valid, p03_out_command;
    wire [1:0]  p03_out_owner;
    wire        p03_out_write, p03_out_refresh, p03_out_code, p03_out_burst;
    wire [3:0]  p03_out_class;
    wire [24:0] p03_out_address;
    wire [1:0]  p03_out_lanes;
    wire [15:0] p03_out_data;
    wire        p03_in_accept, p03_in_ready, p03_in_read_valid;
    wire [15:0] p03_in_data;
    wire        p03_out_accept, p03_out_ready, p03_out_read_valid;
    wire [15:0] p03_out_read_data;
    wire [12:0] dram_address;
    wire dram_cke, dram_cs, dram_ras, dram_cas, dram_we, dram_oe;
    wire [1:0] dram_ba, dram_dqm, dq_valid;
    wire [15:0] dram_in, dram_out;
    wire integer dram_reads, dram_writes;
    integer p03_enable = 0;

    spk286_machine_cpu cpu (
        .clk(clk), .reset(cpu_reset), .execute_enable(1'b1),
        .ready(ready), .data_in(data_in), .intr(1'b0), .nmi(1'b0),
        .hold_request(1'b0), .address(address), .data_out(data_out),
        .data_oe(data_oe), .bus_valid(bus_valid), .bus_write(bus_write),
        .bus_bhe_n(bus_bhe_n), .bus_status(bus_status), .bus_lock(bus_lock),
        .halted(halted), .shutdown(shutdown), .control_error(control_error),
        .unsupported_opcode(unsupported), .microcode_fault(microcode_fault),
        .debug_instruction_retired(retired), .debug_instruction_ip(instruction_ip),
        .debug_cs(cs), .debug_gpr(gpr), .debug_prefetch_count(prefetch_count),
        .debug_ip(next_ip), .debug_flags(flags)
    );
    spk286_at_memory_decode width_decode (
        .request_valid(bus_valid), .request_write(bus_write),
        .cycle_class(bus_status), .address(address),
        .installed_ram_size(3'd0), .word_capable(width_capable)
    );
    spk286_at_bus_bridge bridge (
        .clk(clk), .reset(cpu_reset), .cpu_sample_edge(1'b1),
        .cpu_bus_valid(bus_valid),
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
        .cpu_cycle_class(at_class), .cpu_address(mapped_at_address),
        .cpu_byte_enable(at_lanes), .cpu_data_out(at_out),
        .cpu_accept(at_accept), .cpu_ready(at_ready),
        .cpu_read_data(at_in), .cpu_read_data_valid(at_read_valid),
        .loader_valid(1'b0), .loader_write(1'b0), .loader_address(24'd0),
        .loader_byte_enable(2'b00), .loader_data_out(16'd0),
        .dma_valid(1'b0), .dma_write(1'b0), .dma_address(25'd0),
        .dma_byte_enable(2'b00), .dma_data_out(16'd0),
        .refresh_valid(1'b0), .refresh_address(24'd0),
        .backend_valid(backend_valid), .backend_command_valid(backend_command),
        .backend_write(backend_write), .backend_refresh(backend_refresh),
        .backend_code_fetch(backend_code), .backend_cycle_class(backend_class),
        .backend_address(backend_address), .backend_byte_enable(backend_lanes),
        .backend_data_out(backend_out), .backend_accept(p03_in_accept),
        .backend_ready(p03_in_ready), .backend_read_data(p03_in_data),
        .backend_read_data_valid(p03_in_read_valid), .protocol_error(port_error)
    );
    assign backend_accept = p03_in_accept;
    assign backend_ready = p03_in_ready;
    assign backend_in = p03_in_data;
    assign backend_read_valid = p03_in_read_valid;

    spk286_at_sdram_read_buffer buffer (
        .clk(clk), .reset(reset), .cancel_cpu(cpu_reset),
        .enable(p03_enable != 0),
        .in_valid(backend_valid), .in_command_valid(backend_command),
        .in_owner(2'd0), .in_write(backend_write),
        .in_refresh(backend_refresh), .in_code_fetch(backend_code),
        .in_cycle_class(backend_class), .in_address(backend_address),
        .in_byte_enable(backend_lanes), .in_data_out(backend_out),
        .in_accept(p03_in_accept), .in_ready(p03_in_ready),
        .in_read_data(p03_in_data), .in_read_data_valid(p03_in_read_valid),
        .out_valid(p03_out_valid), .out_command_valid(p03_out_command),
        .out_owner(p03_out_owner), .out_write(p03_out_write),
        .out_refresh(p03_out_refresh), .out_code_fetch(p03_out_code),
        .out_burst(p03_out_burst),
        .out_cycle_class(p03_out_class), .out_address(p03_out_address),
        .out_byte_enable(p03_out_lanes), .out_data_out(p03_out_data),
        .out_accept(p03_out_accept), .out_ready(p03_out_ready),
        .out_read_data(p03_out_read_data),
        .out_read_data_valid(p03_out_read_valid),
        .debug_hit_count(), .debug_miss_count(), .debug_fill_count(),
        .debug_physical_read_count(), .debug_invalidation_count()
    );
    spk286_at_mister_sdram_owner #(.SDRAM_INIT_WAIT(16'd8)) owner (
        .clk(clk), .reset(reset), .request_valid(p03_out_valid),
        .request_command_valid(p03_out_command),
        .request_owner_refresh(p03_out_refresh), .request_write(p03_out_write),
        .request_code_fetch(p03_out_code), .request_burst(p03_out_burst),
        .request_cycle_class(p03_out_class),
        .request_address(p03_out_address), .request_byte_enable(p03_out_lanes),
        .request_data_out(p03_out_data), .request_accept(p03_out_accept),
        .request_ready(p03_out_ready), .request_read_data(p03_out_read_data),
        .request_read_data_valid(p03_out_read_valid), .physical_idle(physical_idle),
        .protocol_error(owner_error), .sdram_address(dram_address),
        .sdram_cke(dram_cke), .sdram_cs(dram_cs), .sdram_ras(dram_ras),
        .sdram_cas(dram_cas), .sdram_we(dram_we), .sdram_ba(dram_ba),
        .sdram_dq_in(dram_in), .sdram_dq_out(dram_out), .sdram_dq_io(dram_oe),
        .sdram_ldqm(dram_dqm[0]), .sdram_udqm(dram_dqm[1])
    );
    spk286_sdram_pin_model dram (
        .clk(clk), .reset(reset), .address(dram_address), .cke(dram_cke),
        .cs_n(dram_cs), .ras_n(dram_ras), .cas_n(dram_cas), .we_n(dram_we),
        .ba(dram_ba), .dq_from_controller(dram_out), .controller_dq_oe(!dram_oe),
        .dqm(dram_dqm), .dq_to_controller(dram_in), .dq_valid(dq_valid),
        .read_count(dram_reads), .write_count(dram_writes)
    );

    integer cycles = 0, instructions = 0, busy = 0, empty_queue = 0;
    integer mark_cycles = 0, mark_instructions = 0, mark_reads = 0, mark_writes = 0;
    integer mark_busy = 0, mark_empty = 0, stage = 0;
    integer request_start = 0, read_cycles = 0, read_requests = 0;
    integer write_cycles = 0, write_requests = 0;
    integer data_reads = 0, code_reads = 0, other_reads = 0;
    logic [31:0] memory_signature;
    logic bus_pending = 0;
    task automatic report_stage;
        $display("AT_PERF p03=%0d native=%0d stage=%0d cycles=%0d retired=%0d sdram_reads=%0d sdram_writes=%0d bus_busy=%0d queue_empty=%0d",
            p03_enable, native_width, stage, cycles-mark_cycles, instructions-mark_instructions,
            dram_reads-mark_reads, dram_writes-mark_writes,
            busy-mark_busy, empty_queue-mark_empty);
    endtask

    always @(posedge clk) begin
        if (!cpu_reset) begin
            cycles = cycles + 1;
            if (bus_valid) busy = busy + 1;
            if (prefetch_count == 0) empty_queue = empty_queue + 1;
            if (bus_valid && !bus_pending) begin
                request_start = cycles;
                bus_pending = 1;
            end
            if (bus_valid && ready) begin
                if (bus_write) begin
                    write_cycles = write_cycles + cycles-request_start+1;
                    write_requests = write_requests+1;
                end else begin
                    read_cycles = read_cycles + cycles-request_start+1;
                    read_requests = read_requests+1;
                    if (bus_status == 4'h5) data_reads = data_reads+1;
                    else if (bus_status == 4'hD) code_reads = code_reads+1;
                    else other_reads = other_reads+1;
                end
                bus_pending = 0;
            end
            if (bridge_error || port_error || owner_error || control_error ||
                unsupported || microcode_fault || shutdown)
                $fatal(1, "AT_PERF protocol/CPU fault cs=%h ip=%h", cs, instruction_ip);
            if (retired) begin
                instructions = instructions + 1;
                if (cs == 16'hF000 && instruction_ip >= 16'h0100 &&
                    instruction_ip <= 16'h0500 && instruction_ip[7:0] == 0) begin
                    if (stage != 0) report_stage();
                    stage = int'(instruction_ip[15:8]);
                    mark_cycles = cycles; mark_instructions = instructions;
                    mark_reads = dram_reads; mark_writes = dram_writes;
                    mark_busy = busy; mark_empty = empty_queue;
                end
            end
            if (halted) begin
                if (gpr[15:0] != 16'h600D || stage != 5)
                    $fatal(1, "AT_PERF functional result failed AX=%h stage=%0d", gpr[15:0], stage);
                for (integer i=0; i<256; i=i+1)
                    if (dram.mem['h1000+i] !== 16'(i+1))
                        $fatal(1, "AT_PERF data mismatch index=%0d", i);
                for (integer i=0; i<1024; i=i+1)
                    if (dram.mem['h2000+i] !== 16'hA55A)
                        $fatal(1, "AT_PERF string mismatch index=%0d", i);
                memory_signature = 32'h811C9DC5;
                for (integer i=0; i<$size(dram.mem); i=i+1)
                    memory_signature = (memory_signature ^ {16'b0, dram.mem[i]}) * 32'h01000193;
                $display("AT_MEMORY_PERF_PASS p03=%0d native=%0d cycles=%0d retired=%0d reads=%0d read_cycles=%0d writes=%0d write_cycles=%0d sdram_reads=%0d sdram_writes=%0d data_reads=%0d code_reads=%0d other_reads=%0d gpr=%032h flags=%04h cs=%04h ip=%04h memory=%08h",
                    p03_enable, native_width, cycles, instructions, read_requests, read_cycles,
                    write_requests, write_cycles, dram_reads, dram_writes,
                    data_reads, code_reads, other_reads, gpr, flags, cs, next_ip, memory_signature);
                $finish;
            end
            if (cycles > 2000000) $fatal(1, "AT_PERF timeout cs=%h ip=%h",cs,instruction_ip);
        end
    end
    byte unsigned rom [0:65535];
    string rom_path;
    integer fd, count;
    initial begin
        if (!$value$plusargs("ROM=%s", rom_path)) $fatal(1, "ROM path required");
        if ($value$plusargs("NATIVE=%d", native_width)) begin end
        if ($value$plusargs("P03=%d", p03_enable)) begin end
        fd = $fopen(rom_path,"rb");
        if (!fd) $fatal(1, "Cannot open ROM");
        count = $fread(rom,fd);
        $fclose(fd);
        if (count != 65536) $fatal(1, "ROM must be 64 KiB");
        for (integer i=0;i<$size(dram.mem);i=i+1) dram.mem[i] = 0;
        for (integer i=0;i<32768;i=i+1)
            dram.mem['h78000+i] = {rom[i*2+1],rom[i*2]};
        repeat (4) @(negedge clk);
        reset = 0;
        wait (physical_idle);
        @(negedge clk);
        cpu_reset = 0;
    end
endmodule
