`timescale 1ns/1ps
module spk286_at_sdram_data_buffer_tb #(parameter logic FULL_PIPELINE = 1'b0);
    logic clk = 0, reset = 1, cancel_cpu = 0, enable = 1;
    always #5 clk = ~clk;
    logic in_valid=0, in_command_valid=0, in_write=0, in_refresh=0, in_code_fetch=0, in_burst=0;
    logic [1:0] in_owner=0, in_byte_enable=3;
    logic [3:0] in_cycle_class=5;
    logic [24:0] in_address=0;
    logic [15:0] in_data_out=0;
    wire in_accept, in_ready, in_read_data_valid;
    wire [15:0] in_read_data;
    wire out_valid, out_command_valid, out_write, out_refresh, out_code_fetch, out_burst;
    wire [1:0] out_owner, out_byte_enable;
    wire [3:0] out_cycle_class;
    wire [24:0] out_address;
    wire [15:0] out_data_out;
    wire out_accept, out_ready, out_read_data_valid;
    wire [15:0] out_read_data;
    wire [31:0] hits, misses, fills, updates;
    wire [1:0] state;
    wire buffer_valid, buffer_command, buffer_write, buffer_refresh, buffer_code, buffer_burst;
    wire [1:0] buffer_owner, buffer_lanes;
    wire [3:0] buffer_class;
    wire [24:0] buffer_address;
    wire [15:0] buffer_data, buffer_read_data;
    wire buffer_accept, buffer_ready, buffer_read_valid;
    generate if (FULL_PIPELINE) begin : g_pipeline
        wire port_valid, port_command, port_write, port_refresh, port_code;
        wire [1:0] port_owner, port_lanes;
        wire [3:0] port_class;
        wire [24:0] port_address;
        wire [15:0] port_data, port_read_data;
        wire port_accept, port_ready, port_read_valid;
        wire cpu_accept, cpu_ready, cpu_read_valid, dma_accept, dma_ready;
        wire loader_accept, loader_ready, refresh_accept, refresh_ready;
        wire [15:0] cpu_data, dma_data, loader_data;
        wire protocol_error;
        spk286_at_mister_memory_port memory_port (
            .clk(clk), .reset(reset), .cancel_cpu(cancel_cpu),
            .cpu_valid(in_valid && in_owner==0), .cpu_command_valid(in_command_valid),
            .cpu_write(in_write), .cpu_code_fetch(in_code_fetch), .cpu_cycle_class(in_cycle_class),
            .cpu_address(in_address), .cpu_byte_enable(in_byte_enable), .cpu_data_out(in_data_out),
            .cpu_accept(cpu_accept), .cpu_ready(cpu_ready), .cpu_read_data(cpu_data),
            .cpu_read_data_valid(cpu_read_valid),
            .dma_valid(in_valid && in_owner==1), .dma_write(in_write), .dma_address(in_address),
            .dma_byte_enable(in_byte_enable), .dma_data_out(in_data_out),
            .dma_accept(dma_accept), .dma_ready(dma_ready), .dma_read_data(dma_data),
            .loader_valid(in_valid && in_owner==3), .loader_write(in_write),
            .loader_address(in_address[23:0]), .loader_byte_enable(in_byte_enable), .loader_data_out(in_data_out),
            .loader_accept(loader_accept), .loader_ready(loader_ready), .loader_read_data(loader_data),
            .refresh_valid(in_valid && in_owner==2), .refresh_address(in_address[23:0]),
            .refresh_accept(refresh_accept), .refresh_ready(refresh_ready),
            .backend_valid(port_valid), .backend_command_valid(port_command), .backend_owner(port_owner),
            .backend_write(port_write), .backend_refresh(port_refresh), .backend_code_fetch(port_code),
            .backend_cycle_class(port_class), .backend_address(port_address), .backend_byte_enable(port_lanes),
            .backend_data_out(port_data), .backend_accept(port_accept), .backend_ready(port_ready),
            .backend_read_data(port_read_data), .backend_read_data_valid(port_read_valid),
            .debug_state(), .protocol_error(protocol_error)
        );
        spk286_at_sdram_read_buffer code_buffer (
            .clk(clk), .reset(reset), .cancel_cpu(cancel_cpu), .enable(1'b1),
            .in_valid(port_valid), .in_command_valid(port_command), .in_owner(port_owner),
            .in_write(port_write), .in_refresh(port_refresh), .in_code_fetch(port_code),
            .in_cycle_class(port_class), .in_address(port_address), .in_byte_enable(port_lanes), .in_data_out(port_data),
            .in_accept(port_accept), .in_ready(port_ready), .in_read_data(port_read_data), .in_read_data_valid(port_read_valid),
            .out_valid(buffer_valid), .out_command_valid(buffer_command), .out_owner(buffer_owner),
            .out_write(buffer_write), .out_refresh(buffer_refresh), .out_code_fetch(buffer_code), .out_burst(buffer_burst),
            .out_cycle_class(buffer_class), .out_address(buffer_address), .out_byte_enable(buffer_lanes), .out_data_out(buffer_data),
            .out_accept(buffer_accept), .out_ready(buffer_ready), .out_read_data(buffer_read_data), .out_read_data_valid(buffer_read_valid),
            .debug_hit_count(), .debug_miss_count(), .debug_fill_count(), .debug_physical_read_count(),
            .debug_invalidation_count(), .debug_state()
        );
        assign in_accept=cpu_accept | dma_accept | loader_accept | refresh_accept;
        assign in_ready=cpu_ready | dma_ready | loader_ready | refresh_ready;
        assign in_read_data_valid=cpu_read_valid | ((dma_ready | loader_ready) && !port_write);
        assign in_read_data=cpu_ready ? cpu_data : dma_ready ? dma_data : loader_data;
        always @(posedge clk) if (!reset && protocol_error)
            $fatal(1, "Memory ownership protocol error");
    end else begin : g_direct
        assign buffer_valid=in_valid;
        assign buffer_command=in_command_valid;
        assign buffer_owner=in_owner;
        assign buffer_write=in_write;
        assign buffer_refresh=in_refresh;
        assign buffer_code=in_code_fetch;
        assign buffer_burst=in_burst;
        assign buffer_class=in_cycle_class;
        assign buffer_address=in_address;
        assign buffer_lanes=in_byte_enable;
        assign buffer_data=in_data_out;
        assign in_accept=buffer_accept;
        assign in_ready=buffer_ready;
        assign in_read_data=buffer_read_data;
        assign in_read_data_valid=buffer_read_valid;
    end endgenerate
    spk286_at_sdram_data_buffer dut (
        .clk(clk), .reset(reset), .cancel_cpu(cancel_cpu), .enable(enable),
        .in_valid(buffer_valid), .in_command_valid(buffer_command), .in_owner(buffer_owner),
        .in_write(buffer_write), .in_refresh(buffer_refresh), .in_code_fetch(buffer_code), .in_burst(buffer_burst),
        .in_cycle_class(buffer_class), .in_address(buffer_address), .in_byte_enable(buffer_lanes),
        .in_data_out(buffer_data), .in_accept(buffer_accept), .in_ready(buffer_ready),
        .in_read_data(buffer_read_data), .in_read_data_valid(buffer_read_valid),
        .out_valid(out_valid), .out_command_valid(out_command_valid), .out_owner(out_owner),
        .out_write(out_write), .out_refresh(out_refresh), .out_code_fetch(out_code_fetch), .out_burst(out_burst),
        .out_cycle_class(out_cycle_class), .out_address(out_address), .out_byte_enable(out_byte_enable),
        .out_data_out(out_data_out), .out_accept(out_accept), .out_ready(out_ready),
        .out_read_data(out_read_data), .out_read_data_valid(out_read_data_valid),
        .debug_hit_count(hits), .debug_miss_count(misses), .debug_fill_count(fills),
        .debug_write_update_count(updates), .debug_state(state)
    );

    // Sparse physical RAM, keyed by the complete canonical word address.
    // Never alias high RAM just to fit the test array. Reads default to a
    // deterministic address-dependent pattern; writes modify the actual word.
    logic [23:0] stored_address[0:255];
    logic [15:0] stored_data[0:255];
    integer stored_count=0;
    function automatic logic [15:0] read_word(input logic [23:0] word_address);
        logic [15:0] value;
        begin
            value = word_address[15:0] ^ {8'hA5, word_address[23:16]};
            for (integer i=0; i<stored_count; i++)
                if (stored_address[i] == word_address) value = stored_data[i];
            return value;
        end
    endfunction
    task automatic store_word(input logic [23:0] word_address,
                              input logic [1:0] lanes, input logic [15:0] data);
        integer slot;
        logic [15:0] value;
        begin
            slot = stored_count;
            for (integer i=0; i<stored_count; i++)
                if (stored_address[i] == word_address) slot=i;
            value = read_word(word_address);
            if (slot == stored_count) begin
                if (stored_count == 256) $fatal(1, "Sparse backend full");
                stored_count++;
            end
            if (lanes[0]) value[7:0] = data[7:0];
            if (lanes[1]) value[15:8] = data[15:8];
            stored_address[slot] = word_address;
            stored_data[slot] = value;
        end
    endtask

    logic backend_active=0, allow_accept=1, allow_response=1;
    logic [1:0] backend_owner, backend_lanes;
    logic backend_write, backend_refresh, backend_code, backend_burst;
    logic [3:0] backend_class;
    logic [24:0] backend_address;
    logic [15:0] backend_data;
    integer backend_delay=0, backend_beat=0;
    integer physical_reads=0, physical_writes=0, read_beats=0, write_commits=0;
    assign out_accept = out_valid && out_command_valid && !backend_active && allow_accept;
    logic [15:0] response_data;
    // Publish stable response data between sampling edges. Explicitly sample
    // the sparse model after writes as well, even when its address is unchanged.
    always @(negedge clk)
        response_data = read_word(backend_address[24:1] + 24'(backend_beat));
    assign out_read_data = response_data;
    assign out_read_data_valid = backend_active && backend_delay==0 && allow_response &&
                                 !backend_write && !backend_refresh;
    assign out_ready = backend_active && backend_delay==0 && allow_response &&
                       (!backend_burst || backend_beat==3);
    always @(posedge clk) begin
        if (reset) begin
            backend_active <= 0;
            backend_delay <= 0;
            backend_beat <= 0;
        end else if (out_accept) begin
            backend_active <= 1;
            backend_delay <= 3;
            backend_beat <= 0;
            backend_owner <= out_owner;
            backend_write <= out_write;
            backend_refresh <= out_refresh;
            backend_code <= out_code_fetch;
            backend_burst <= out_burst;
            backend_class <= out_cycle_class;
            backend_address <= out_address;
            backend_lanes <= out_byte_enable;
            backend_data <= out_data_out;
            if (out_write) physical_writes++;
            else if (!out_refresh) physical_reads++;
        end else if (backend_active) begin
            if (!out_valid || out_command_valid || out_owner != backend_owner ||
                out_write != backend_write || out_refresh != backend_refresh ||
                out_code_fetch != backend_code || out_burst != backend_burst ||
                out_cycle_class != backend_class || out_address != backend_address ||
                out_byte_enable != backend_lanes || out_data_out != backend_data)
                $fatal(1, "Physical transaction metadata changed while stalled");
            if (backend_delay != 0) backend_delay <= backend_delay-1;
            else if (allow_response) begin
                if (out_read_data_valid) read_beats++;
                if (out_ready) begin
                    backend_active <= 0;
                    if (backend_write) begin
                        store_word(backend_address[24:1], backend_lanes, backend_data);
                        write_commits++;
                    end
                end else if (backend_burst) backend_beat <= backend_beat+1;
            end
        end
    end
    task automatic check(input logic condition, input string message);
        if (!condition) $fatal(1, "RAM_BUFFER_FAIL %s", message);
    endtask
    task automatic start_request(input logic [1:0] owner, input logic wr,
        input logic code, input logic burst, input logic [24:0] address,
        input logic [1:0] lanes, input logic [15:0] data, input logic [3:0] cycle_class);
        integer guard;
        begin
            @(negedge clk);
            in_valid=1; in_command_valid=1; in_owner=owner; in_write=wr;
            in_code_fetch=code; in_burst=burst; in_refresh=cycle_class==0;
            in_cycle_class=cycle_class; in_address=address; in_byte_enable=lanes; in_data_out=data;
            guard=0;
            do begin
                @(posedge clk);
                guard++;
                if (guard>100) $fatal(1, "Acceptance timeout");
            end while (!in_accept);
            @(negedge clk);
            in_command_valid=0;
            // All active fields must now come from the captured record.
            // The raw owner's valid is its upstream ownership indication in
            // the full pipeline; keep that identity until completion.
            if (!FULL_PIPELINE) in_owner=3;
            in_write=~wr; in_code_fetch=~code; in_burst=~burst;
            in_cycle_class=15; in_address=25'h1FFFFFF; in_byte_enable=0; in_data_out=16'hDEAD;
        end
    endtask
    task automatic finish_request(input logic expect_data, input logic [15:0] expected);
        integer guard;
        begin
            guard=0;
            do begin
                @(posedge clk); guard++;
                if (guard>100) $fatal(1, "Completion timeout");
            end while (!in_ready);
            check(in_read_data_valid==expect_data, "response data-valid");
            if (expect_data && in_read_data!==expected)
                $fatal(1, "RAM_BUFFER_FAIL data address=%h owner=%0d state=%0d actual=%h expected=%h cancel=%b",
                    dut.address_q, dut.owner_q, state, in_read_data, expected, cancel_cpu);
            @(negedge clk); in_valid=0;
        end
    endtask
    task automatic read_request(input logic [1:0] owner, input logic code,
                                input logic [24:0] address, input logic [1:0] lanes);
        logic [15:0] expected;
        begin
            expected=read_word(address[24:1]);
            start_request(owner, 0, code, 0, address, lanes, 0, 5);
            finish_request(1, expected);
        end
    endtask
    task automatic write_request(input logic [1:0] owner, input logic [24:0] address,
                                 input logic [1:0] lanes, input logic [15:0] data);
        integer before_commits;
        begin
            before_commits=write_commits;
            start_request(owner, 1, 0, 0, address, lanes, data, 6);
            check(!in_ready && write_commits==before_commits, "write completed before SDRAM");
            finish_request(0, 0);
            check(write_commits==before_commits+1, "write did not commit exactly once");
        end
    endtask
    integer before_reads, before_hits, before_fills, before_beats;
    task automatic pipeline_checks;
        begin
            read_request(0, 1, 25'h6000, 3); // P03 four-word fill.
            before_reads=physical_reads;
            read_request(0, 1, 25'h6002, 3);
            check(physical_reads==before_reads, "pipeline code hit reached SDRAM");
            read_request(0, 0, 25'h6000, 3); // Allocate independent data word.
            before_reads=physical_reads;
            read_request(0, 0, 25'h6001, 2);
            check(physical_reads==before_reads, "pipeline data hit reached SDRAM");
            for(integer owner=0; owner<4; owner++) begin
                if (owner!=2) begin
                    write_request(2'(owner), 25'h6001, 2, 16'hC100+16'(owner<<8));
                    before_reads=physical_reads;
                    read_request(0, 0, 25'h6000, 3);
                    check(physical_reads==before_reads, "pipeline writer did not update data hit");
                    read_request(0, 1, 25'h6000, 3);
                    check(physical_reads==before_reads+1, "pipeline writer did not invalidate code line");
                end
            end
            start_request(2, 0, 0, 0, 25'h400, 3, 0, 0); finish_request(0, 0);
            before_reads=physical_reads;
            read_request(1, 0, 25'h6000, 3);
            check(physical_reads==before_reads+1, "pipeline DMA read was cached");
            // Cancellation while a loader write owns SDRAM must preserve that
            // writer, flush both caches, then allow an uncached CPU response.
            allow_response=0;
            start_request(3, 1, 0, 0, 25'h6000, 3, 16'hF00D, 6);
            @(negedge clk); cancel_cpu=1;
            repeat(5) @(negedge clk);
            check(!in_ready, "pipeline posted a stalled loader write");
            allow_response=1; finish_request(0, 0); cancel_cpu=0;
            before_reads=physical_reads;
            read_request(0, 0, 25'h6000, 3);
            read_request(0, 1, 25'h6000, 3);
            check(physical_reads==before_reads+2, "pipeline reset did not flush both buffers");
            check(read_word(24'h3000)==16'hF00D, "pipeline loader write lost");
            $display("RAM_BUFFER_PIPELINE_PASS CPU_DMA_LOADER_COHERENCE refresh_burst_reset");
            $finish;
        end
    endtask
    initial begin
        // Unknown/uninitialized RAM rows are never hits because valid is reset.
        repeat(3) @(negedge clk); reset=0;
        if (FULL_PIPELINE) pipeline_checks();
        read_request(0, 0, 25'h0, 1);
        write_request(1, 25'h0, 1, 16'h0012);
        read_request(0, 0, 25'h0, 3);
        check(read_word(24'h0)==16'hA512, "zero-address byte write lost high byte");
        // Flush the extra zero-address setup before the fixed counter checks.
        @(negedge clk); reset=1;
        @(negedge clk); reset=0;
        read_request(0, 0, 25'h1000, 3);
        before_reads=physical_reads;
        read_request(0, 0, 25'h1000, 3);
        read_request(0, 0, 25'h1001, 2);
        check(physical_reads==before_reads && hits==2, "word/odd-byte hits issued SDRAM reads");
        write_request(0, 25'h1000, 1, 16'h00CC);
        read_request(0, 0, 25'h1000, 3);
        write_request(1, 25'h1001, 2, 16'hDD00);
        read_request(0, 0, 25'h1000, 3);
        write_request(3, 25'h1000, 3, 16'h7788);
        read_request(0, 0, 25'h1001, 2);
        check(physical_reads==before_reads && updates==3, "CPU/DMA/loader write coherence");
        check(read_word(24'h800)==16'h7788, "physical writes/lanes");
        // A write to a different physical tag at the same index keeps the hot word.
        write_request(1, 25'h1800, 3, 16'hEEFF);
        read_request(0, 0, 25'h1000, 3);
        check(physical_reads==before_reads, "unrelated write evicted a matching-index word");
        before_reads=physical_reads;
        read_request(0, 0, 25'h1400, 3);
        read_request(0, 0, 25'h1000, 3);
        check(physical_reads==before_reads+2, "tag collision did not miss");
        read_request(0, 0, 25'h0100000, 3);
        read_request(0, 0, 25'h1100000, 3);
        before_reads=physical_reads;
        read_request(0, 0, 25'h1100001, 2);
        check(physical_reads==before_reads, "25-bit high RAM tag or odd lane");
        // Canonical FF0000 is shifted RAM, not the resolved CPU BIOS alias.
        read_request(0, 0, 25'h0FF0000, 3);
        before_reads=physical_reads;
        read_request(0, 0, 25'h0FF0000, 3);
        check(physical_reads==before_reads, "high RAM re-aliased to BIOS");
        // ROM/video/UMB, DMA reads and instruction requests never allocate.
        for (integer region=0; region<4; region++) begin
            logic [24:0] address;
            case(region)
                0: address=25'h00A0000;
                1: address=25'h00C0000;
                2: address=25'h00C8000;
                default: address=25'h00F0000;
            endcase
            before_reads=physical_reads;
            read_request(0, 0, address, 3); read_request(0, 0, address, 3);
            check(physical_reads==before_reads+2, "excluded region cached");
        end
        before_reads=physical_reads;
        read_request(1, 0, 25'h2000, 3); read_request(1, 0, 25'h2000, 3);
        read_request(0, 1, 25'h2000, 3); read_request(0, 1, 25'h2000, 3);
        check(physical_reads==before_reads+4, "DMA or code read allocated");
        before_reads=physical_reads;
        start_request(0, 0, 0, 0, 25'h300, 3, 0, 9);
        finish_request(1, read_word(24'h180));
        start_request(0, 0, 0, 0, 25'h300, 3, 0, 9);
        finish_request(1, read_word(24'h180));
        check(physical_reads==before_reads+2, "non-memory class cached");
        start_request(2, 0, 0, 0, 25'h400, 3, 0, 0); finish_request(0, 0);
        // Write misses never allocate, including while disabled.
        write_request(0, 25'h3000, 3, 16'h1234);
        before_reads=physical_reads;
        read_request(0, 0, 25'h3000, 3);
        check(physical_reads==before_reads+1, "write miss allocated");
        @(negedge clk); enable=0;
        write_request(3, 25'h3000, 3, 16'h5678);
        read_request(0, 0, 25'h3000, 3);
        before_reads=physical_reads;
        @(negedge clk); enable=1;
        read_request(0, 0, 25'h3000, 3);
        check(physical_reads==before_reads+1, "disabled/re-enabled stale hit");
        // CPU cancellation flushes IDLE as well as an already accepted hit.
        @(negedge clk); cancel_cpu=1;
        @(negedge clk); cancel_cpu=0;
        before_reads=physical_reads;
        read_request(0, 0, 25'h3000, 3);
        check(physical_reads==before_reads+1, "idle CPU reset did not flush");
        start_request(0, 0, 0, 0, 25'h3000, 3, 0, 5);
        cancel_cpu=1; finish_request(1, 16'hFFFF);
        cancel_cpu=0;
        before_reads=physical_reads;
        allow_accept=0;
        start_request(0, 0, 0, 0, 25'h3400, 3, 0, 5);
        cancel_cpu=1; finish_request(1, 16'hFFFF);
        cancel_cpu=0; allow_accept=1;
        check(physical_reads==before_reads, "cancelled unaccepted miss launched SDRAM");
        // Accepted miss drains even if response is stalled; no cache resurrection.
        allow_response=0;
        before_fills=fills;
        start_request(0, 0, 0, 0, 25'h3400, 3, 0, 5);
        wait(backend_active); @(negedge clk); cancel_cpu=1;
        repeat(5) @(negedge clk);
        check(!in_ready, "accepted cancelled read did not drain");
        allow_response=1; finish_request(1, 16'hFFFF);
        cancel_cpu=0;
        check(fills==before_fills, "cancelled fill resurrected valid");
        before_reads=physical_reads;
        read_request(0, 0, 25'h3400, 3);
        check(physical_reads==before_reads+1, "cancelled fill was cached");
        // CPU cancellation during a loader write flushes cache but preserves
        // loader ownership and its physical effect.
        allow_response=0;
        start_request(3, 1, 0, 0, 25'h3400, 3, 16'hBEEF, 6);
        @(negedge clk); cancel_cpu=1;
        repeat(5) @(negedge clk);
        allow_response=1; finish_request(0, 0);
        cancel_cpu=0;
        before_reads=physical_reads;
        read_request(0, 0, 25'h3400, 3);
        check(physical_reads==before_reads+1 && read_word(24'h1A00)==16'hBEEF,
              "loader write cancelled or resurrected cache");
        // An accepted CPU write must also reach physical completion after
        // cancellation. Its cached copy is flushed, never posted or retained.
        allow_response=0;
        start_request(0, 1, 0, 0, 25'h3400, 3, 16'hCAFE, 6);
        wait(backend_active); @(negedge clk); cancel_cpu=1;
        repeat(5) @(negedge clk);
        check(!in_ready, "cancelled CPU write did not drain");
        allow_response=1; finish_request(0, 0); cancel_cpu=0;
        before_reads=physical_reads;
        read_request(0, 0, 25'h3400, 3);
        check(physical_reads==before_reads+1 && read_word(24'h1A00)==16'hCAFE,
              "cancelled CPU write lost or resurrected cache");
        // Cancellation cannot truncate an already accepted four-word burst.
        allow_response=0;
        before_beats=read_beats;
        start_request(0, 0, 1, 1, 25'h5000, 3, 0, 13);
        wait(backend_active); @(negedge clk); cancel_cpu=1;
        repeat(5) @(negedge clk); allow_response=1;
        for(integer beat=0; beat<4; beat++) begin
            do @(posedge clk); while(!in_read_data_valid);
            check(in_read_data==16'hFFFF, "cancelled code burst leaked data");
            check(in_ready==(beat==3), "cancelled code burst prematurely completed");
        end
        @(negedge clk); in_valid=0; cancel_cpu=0;
        check(read_beats==before_beats+4, "cancelled code burst did not drain");
        // A four-word P03 fill forwards intermediate beats without READY.
        before_beats=read_beats;
        start_request(0, 0, 1, 1, 25'h5000, 3, 0, 13);
        for(integer beat=0; beat<4; beat++) begin
            do @(posedge clk); while(!in_read_data_valid);
            check(in_read_data===read_word(24'h2800+24'(beat)), "code burst beat data");
            check(in_ready==(beat==3), "code burst prematurely completed");
        end
        @(negedge clk); in_valid=0;
        check(read_beats==before_beats+4, "code burst lost an intermediate beat");
        // Identical held requests are delimited by acceptance/completion,
        // never by a change in address/payload or a dropped valid signal.
        read_request(0, 0, 25'h3400, 3);
        before_hits=hits;
        @(negedge clk);
        in_valid=1; in_command_valid=1; in_owner=0; in_write=0; in_refresh=0;
        in_code_fetch=0; in_burst=0; in_cycle_class=5; in_address=25'h3400;
        in_byte_enable=3; in_data_out=0;
        for(integer n=0; n<3; n++) begin
            do @(posedge clk); while(!in_ready);
            check(in_read_data==16'hCAFE, "held hit data");
            @(negedge clk);
        end
        in_valid=0; in_command_valid=0;
        check(hits==before_hits+3, "held requests duplicated or lost");
        $display("RAM_BUFFER_UNIT_PASS hits=%0d misses=%0d fills=%0d updates=%0d reads=%0d writes=%0d",
            hits, misses, fills, updates, physical_reads, physical_writes);
        $finish;
    end
    initial begin #100000; $fatal(1, "RAM buffer unit timeout"); end
endmodule
