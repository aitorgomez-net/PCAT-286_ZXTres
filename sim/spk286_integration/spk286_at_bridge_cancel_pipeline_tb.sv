`timescale 1ns/1ps

// Production ordering: bridge -> memory owner -> P03 -> RAM data buffer.
// A controllable, retained physical backend lets cancellation coincide with
// hits and burst completion, without depending on a particular SDRAM delay.
module spk286_at_bridge_cancel_pipeline_tb #(
    parameter integer CODE_BUFFER_LINES = 64
);
    logic clk = 0, reset = 1, cancel_cpu = 0;
    always #10 clk = ~clk;
    typedef struct packed {
        logic valid, command;
        logic [1:0] owner;
        logic write, refresh, code, burst;
        logic [3:0] cycle_class;
        logic [24:0] address;
        logic [1:0] lanes;
        logic [15:0] data;
    } request_t;
    typedef struct packed {
        logic accept, ready, data_valid;
        logic [15:0] data;
    } response_t;
    request_t p, c, b;
    response_t pr, cr, br;
    logic cpu_valid = 0, cpu_write = 0;
    logic [23:0] cpu_address = 0;
    logic [3:0] cpu_status = 4'hF;
    logic [15:0] cpu_out = 16'hCAFE;
    wire cpu_ready, at_valid, at_command, at_write, at_code;
    wire [23:0] at_address;
    wire [3:0] at_class;
    wire [1:0] at_lanes;
    wire [15:0] cpu_in, at_out;
    wire port_accept, port_ready, port_data_valid;
    wire [15:0] port_data;
    wire bridge_idle, bridge_error, port_error;
    wire [4:0] port_state, code_state;
    wire [1:0] data_state;
    wire [31:0] code_hits, data_hits;
    integer accepted_cpu = 0, samples = 0, checks = 0;
    integer physical_accepted = 0, physical_completed = 0, write_effects = 0;
    logic [15:0] expected_data = 0, sampled_data = 0;
    integer launch_samples = 0;
    logic allow_accept = 1, pending = 0;
    request_t retained;
    logic reply_ready = 0, reply_valid = 0;
    logic [15:0] reply_data = 0;

    spk286_at_bus_bridge bridge (
        .clk(clk), .reset(reset | cancel_cpu), .cpu_sample_edge(1'b1),
        .cpu_bus_valid(cpu_valid), .cpu_address(cpu_address), .cpu_data_out(cpu_out),
        .cpu_data_oe(cpu_write), .cpu_bus_write(cpu_write), .cpu_bus_bhe_n(1'b0),
        .cpu_bus_status(cpu_status), .cpu_bus_lock(1'b0),
        .cpu_memory_word_capable(1'b1), .cpu_io_word_capable(1'b0),
        .cpu_ready(cpu_ready), .cpu_data_in(cpu_in), .at_valid(at_valid),
        .at_command_valid(at_command), .at_address(at_address), .at_cycle_class(at_class),
        .at_byte_enable(at_lanes), .at_data_out(at_out), .at_write(at_write),
        .at_code_fetch(at_code), .at_accept(port_accept), .at_ready(port_ready),
        .at_read_data(port_data), .at_read_data_valid(port_data_valid),
        .bridge_idle(bridge_idle), .protocol_error(bridge_error), .debug_state(),
        .at_owner(), .at_a0(), .at_bhe_n(), .at_data_oe(), .at_io(), .at_inta(),
        .at_lock(), .at_accepted(), .at_completed(), .at_response_valid()
    );
    spk286_at_mister_memory_port port (
        .clk(clk), .reset(reset), .cancel_cpu(cancel_cpu),
        .cpu_valid(at_valid), .cpu_command_valid(at_command), .cpu_write(at_write),
        .cpu_code_fetch(at_code), .cpu_cycle_class(at_class), .cpu_address({1'b0,at_address}),
        .cpu_byte_enable(at_lanes), .cpu_data_out(at_out), .cpu_accept(port_accept),
        .cpu_ready(port_ready), .cpu_read_data(port_data), .cpu_read_data_valid(port_data_valid),
        .loader_valid(1'b0), .loader_write(1'b0), .loader_address(24'd0),
        .loader_byte_enable(2'b0), .loader_data_out(16'd0),
        .loader_accept(), .loader_ready(), .loader_read_data(),
        .dma_valid(1'b0), .dma_write(1'b0), .dma_address(25'd0),
        .dma_byte_enable(2'b0), .dma_data_out(16'd0),
        .dma_accept(), .dma_ready(), .dma_read_data(),
        .refresh_valid(1'b0), .refresh_address(24'd0), .refresh_accept(), .refresh_ready(),
        .backend_valid(p.valid), .backend_command_valid(p.command), .backend_owner(p.owner),
        .backend_write(p.write), .backend_refresh(p.refresh), .backend_code_fetch(p.code),
        .backend_cycle_class(p.cycle_class), .backend_address(p.address),
        .backend_byte_enable(p.lanes), .backend_data_out(p.data),
        .backend_accept(pr.accept), .backend_ready(pr.ready), .backend_read_data(pr.data),
        .backend_read_data_valid(pr.data_valid), .debug_state(port_state), .protocol_error(port_error)
    );
    assign p.burst = 0;
    spk286_at_sdram_read_buffer #(.LINE_COUNT(CODE_BUFFER_LINES)) code_buffer (
        .clk(clk), .reset(reset), .cancel_cpu(cancel_cpu), .enable(1'b1),
        .in_valid(p.valid), .in_command_valid(p.command), .in_owner(p.owner),
        .in_write(p.write), .in_refresh(p.refresh), .in_code_fetch(p.code),
        .in_cycle_class(p.cycle_class), .in_address(p.address), .in_byte_enable(p.lanes),
        .in_data_out(p.data), .in_accept(pr.accept), .in_ready(pr.ready),
        .in_read_data(pr.data), .in_read_data_valid(pr.data_valid),
        .out_valid(c.valid), .out_command_valid(c.command), .out_owner(c.owner),
        .out_write(c.write), .out_refresh(c.refresh), .out_code_fetch(c.code), .out_burst(c.burst),
        .out_cycle_class(c.cycle_class), .out_address(c.address), .out_byte_enable(c.lanes),
        .out_data_out(c.data), .out_accept(cr.accept), .out_ready(cr.ready),
        .out_read_data(cr.data), .out_read_data_valid(cr.data_valid), .debug_hit_count(code_hits),
        .debug_miss_count(), .debug_fill_count(), .debug_physical_read_count(),
        .debug_invalidation_count(), .debug_state(code_state)
    );
    spk286_at_sdram_data_buffer data_buffer (
        .clk(clk), .reset(reset), .cancel_cpu(cancel_cpu), .enable(1'b1),
        .in_valid(c.valid), .in_command_valid(c.command), .in_owner(c.owner),
        .in_write(c.write), .in_refresh(c.refresh), .in_code_fetch(c.code), .in_burst(c.burst),
        .in_cycle_class(c.cycle_class), .in_address(c.address), .in_byte_enable(c.lanes),
        .in_data_out(c.data), .in_accept(cr.accept), .in_ready(cr.ready),
        .in_read_data(cr.data), .in_read_data_valid(cr.data_valid),
        .out_valid(b.valid), .out_command_valid(b.command), .out_owner(b.owner),
        .out_write(b.write), .out_refresh(b.refresh), .out_code_fetch(b.code), .out_burst(b.burst),
        .out_cycle_class(b.cycle_class), .out_address(b.address), .out_byte_enable(b.lanes),
        .out_data_out(b.data), .out_accept(br.accept), .out_ready(br.ready),
        .out_read_data(br.data), .out_read_data_valid(br.data_valid), .debug_hit_count(data_hits),
        .debug_miss_count(), .debug_fill_count(), .debug_write_update_count(), .debug_state(data_state)
    );
    assign br.accept = allow_accept && !pending && b.valid && b.command;
    assign br.ready = reply_ready;
    assign br.data_valid = reply_valid;
    assign br.data = reply_data;

    function automatic logic [15:0] contents(input logic [24:0] address);
        contents = 16'h5A6D ^ {address[15:1],1'b0} ^ {7'd0,address[24:16]};
    endfunction
    always @(posedge clk) begin
        if (!reset && !cancel_cpu && cpu_ready && !cpu_valid)
            $fatal(1, "stale CPU READY without a live post-reset request");
        if (reset || cancel_cpu) cpu_valid <= 0;
        else if (cpu_valid && cpu_ready) begin
            if (!cpu_write && cpu_in !== expected_data)
                $fatal(1, "stale/wrong CPU data expected=%04h actual=%04h address=%06h",
                       expected_data, cpu_in, cpu_address);
            sampled_data <= cpu_in;
            samples <= samples + 1;
            cpu_valid <= 0;
        end
        if (!reset) begin
            if (bridge_error || port_error) $fatal(1, "pipeline protocol error");
            if (port_accept) accepted_cpu <= accepted_cpu + 1;
            if (br.accept) begin
                retained <= b;
                pending <= 1;
                physical_accepted <= physical_accepted + 1;
            end
            if (pending) begin
                if (!b.valid || b.address !== retained.address || b.write !== retained.write ||
                    b.lanes !== retained.lanes || b.data !== retained.data || b.burst !== retained.burst)
                    $fatal(1, "physical request changed while accepted/cancelled");
                if (br.ready && (retained.write || br.data_valid)) begin
                    pending <= 0;
                    physical_completed <= physical_completed + 1;
                    if (retained.write) write_effects <= write_effects + 1;
                end
            end
        end
    end

    task automatic check(input bit value, input string message);
        checks++;
        if (!value) $fatal(1, "BRIDGE_CANCEL_PIPELINE_FAIL: %s", message);
    endtask
    task automatic launch(input logic [23:0] address, input logic [3:0] status);
        check(!cpu_valid, "previous CPU request still live");
        cpu_address = address;
        cpu_status = status;
        cpu_write = status == 4'h6;
        expected_data = contents({1'b0,address});
        launch_samples = samples;
        cpu_valid = 1;
    endtask
    task automatic wait_accept;
        integer before_count, timeout_count;
        before_count = accepted_cpu;
        timeout_count = 0;
        while (accepted_cpu == before_count && timeout_count < 40) begin
            @(negedge clk); timeout_count++;
        end
        check(accepted_cpu == before_count + 1, "CPU acceptance missing or duplicated");
    endtask
    task automatic wait_physical(input logic [24:0] expected_address);
        integer timeout_count;
        timeout_count = 0;
        while (!pending && timeout_count < 40) begin @(negedge clk); timeout_count++; end
        check(pending && retained.address == expected_address, "physical address missing or stale");
    endtask
    task automatic physical_word(input integer word_index, input bit final_word);
        check(pending, "response without accepted physical request");
        reply_data = contents(retained.address + 25'(2 * word_index));
        reply_valid = !retained.write;
        reply_ready = final_word;
        @(negedge clk);
        reply_valid = 0; reply_ready = 0; reply_data = 16'hDEAD;
    endtask
    task automatic finish_physical;
        integer words;
        words = retained.burst ? 4 : 1;
        for (integer i = 0; i < words; i++) physical_word(i, i == words - 1);
    endtask
    task automatic await_sample;
        integer timeout_count;
        timeout_count = 0;
        while (samples == launch_samples && timeout_count < 40) begin
            @(negedge clk); timeout_count++;
        end
        check(samples == launch_samples + 1 && !cpu_valid, "CPU response missing or duplicated");
    endtask
    task automatic idle_check;
        integer before_samples, before_physical;
        before_samples = samples; before_physical = physical_accepted;
        repeat (4) @(negedge clk);
        check(bridge_idle && !cpu_ready && !pending && !port_state[4] &&
              code_state[4:3] == 0 && data_state == 0, "pipeline failed to drain");
        check(samples == before_samples && physical_accepted == before_physical,
              "idle replay or duplicate response");
    endtask
    task automatic complete_read(input logic [23:0] address, input bit code_fetch);
        launch(address, code_fetch ? 4'hD : 4'h5);
        wait_accept();
        wait_physical(code_fetch ? {1'b0,address[23:3],3'b0} : {1'b0,address});
        finish_physical(); await_sample(); idle_check();
    endtask
    task automatic assert_cancel;
        cancel_cpu = 1;
        #1;
        check(!cpu_ready && !port_ready, "CPU response visible during cancellation");
    endtask
    task automatic release_cancel;
        @(negedge clk);
        cancel_cpu = 0;
        check(!cpu_valid, "CPU request survived reset");
    endtask

    initial begin : exercise
        integer before_samples, before_physical, before_hits, before_writes;
        logic [23:0] address, next_address;
        repeat (4) @(negedge clk);
        reset = 0;
        // Populate each cache, then cancel exactly in its one-cycle response
        // interval. The old response must be discarded and the next fetch
        // must use a distinct physical address and payload.
        for (integer code_fetch = 0; code_fetch < 2; code_fetch++) begin
            address = 24'h010040 + 24'(code_fetch * 24'h1000);
            complete_read(address, code_fetch != 0);
            before_samples = samples; before_physical = physical_accepted;
            before_hits = code_fetch != 0 ? code_hits : data_hits;
            launch(address, code_fetch != 0 ? 4'hD : 4'h5);
            wait_accept();
            #1;
            check(port_ready, "warm cache did not present the expected hit response");
            // P03 counts on acceptance; the data buffer counts on the later
            // response edge that this case is about to cancel.
            // Synchronous tags count on completion, which this case cancels.
            // Inspect the actual retained tag result before that completion.
            check(code_fetch != 0 ?
                  (code_buffer.SYNC_TAGS ?
                   (code_buffer.request_tag_hit && code_hits == before_hits) :
                   code_hits == before_hits + 1) : data_buffer.tag_hit,
                  "cancellation case was not a cache hit");
            assert_cancel(); release_cancel(); idle_check();
            check(samples == before_samples && physical_accepted == before_physical,
                  "cancelled hit reached CPU/backend");
            complete_read(address + 24'h180, 1);
        end

        // A locally admitted RAM lookup can be cancelled before any physical
        // acceptance. This must neither leak a command nor leave it queued.
        allow_accept = 0;
        before_physical = physical_accepted; before_samples = samples;
        launch(24'h012080, 4'h5); wait_accept();
        check(!pending, "prephysical case unexpectedly accepted downstream");
        assert_cancel(); release_cancel(); allow_accept = 1; idle_check();
        check(samples == before_samples && physical_accepted == before_physical,
              "prephysical cancellation replayed");
        complete_read(24'h012180, 1);

        // Accepted data and four-word code misses: final response either
        // coincides with reset or arrives after reset has ended and a new
        // CPU fetch is already waiting behind the cancelled owner.
        for (integer code_fetch = 0; code_fetch < 2; code_fetch++) begin
            for (integer late = 0; late < 2; late++) begin
                address = 24'h020042 + 24'(code_fetch * 24'h1000 + late * 24'h200);
                next_address = address + 24'h180;
                before_samples = samples; before_physical = physical_accepted;
                launch(address, code_fetch != 0 ? 4'hD : 4'h5); wait_accept();
                wait_physical(code_fetch != 0 ? {1'b0,address[23:3],3'b0} : {1'b0,address});
                if (late == 0 && code_fetch != 0)
                    for (integer i = 0; i < 3; i++) physical_word(i, 0);
                assert_cancel();
                if (late == 0) begin
                    physical_word(code_fetch != 0 ? 3 : 0, 1);
                    cancel_cpu = 0;
                    check(!cpu_valid, "coincident reset did not clear CPU request");
                    check(samples == before_samples, "coincident cancelled miss reached CPU");
                    idle_check();
                    launch(next_address, 4'hD);
                end else begin
                    release_cancel();
                    launch(next_address, 4'hD);
                    repeat (4) @(negedge clk);
                    check(!cpu_ready && samples == before_samples,
                          "new fetch completed while old owner was pending");
                    finish_physical();
                    check(samples == before_samples, "late old response reached new fetch");
                end
                wait_physical({1'b0,next_address[23:3],3'b0});
                finish_physical(); await_sample(); idle_check();
                check(physical_accepted == before_physical + 2,
                      "cancelled miss/new fetch caused duplicate physical commands");
            end
        end

        // Already accepted writes must drain exactly once despite reset.
        before_samples = samples; before_physical = physical_accepted;
        before_writes = write_effects;
        launch(24'h030040, 4'h6); wait_accept(); wait_physical(25'h0030040);
        assert_cancel(); release_cancel();
        launch(24'h030182, 4'hD);
        finish_physical();
        check(samples == before_samples, "cancelled write completed a new CPU request");
        wait_physical(25'h0030180); finish_physical(); await_sample(); idle_check();
        check(write_effects == before_writes + 1 && physical_accepted == before_physical + 2,
              "accepted write was lost or duplicated during cancellation");
        check(physical_completed == physical_accepted, "physical completion count differs");
        $display("AT_BRIDGE_CANCEL_PIPELINE_PASS checks=%0d cpu_accept=%0d cpu_samples=%0d physical=%0d writes=%0d",
                 checks, accepted_cpu, samples, physical_completed, write_effects);
        $finish;
    end
    initial begin
        #300000;
        $fatal(1, "bridge cancellation pipeline timeout");
    end
endmodule
