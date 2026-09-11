`timescale 1ns/1ps

module spk286_at_arbiter_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    logic cpu_hlda = 1'b0;
    logic cpu_bridge_idle = 1'b1;
    logic cpu_lock = 1'b0;
    logic cpu_odd_word_active = 1'b0;
    logic cpu_inta_lock_chain = 1'b0;
    logic cpu_response_pending = 1'b0;
    logic dma_request = 1'b0;
    logic refresh_request = 1'b0;
    logic loader_request = 1'b0;
    logic loader_reset_owner = 1'b0;
    logic external_done = 1'b0;
    wire cpu_hold_request, cpu_grant, external_grant, bus_owner_valid;
    wire [2:0] bus_owner;
    wire dma_grant, refresh_grant, loader_grant, protocol_error;

    spk286_at_arbiter dut (
        .clk(clk), .reset(reset), .cpu_hlda(cpu_hlda),
        .cpu_bridge_idle(cpu_bridge_idle), .cpu_lock(cpu_lock),
        .cpu_odd_word_active(cpu_odd_word_active),
        .cpu_inta_lock_chain(cpu_inta_lock_chain),
        .cpu_response_pending(cpu_response_pending),
        .dma_request(dma_request), .refresh_request(refresh_request),
        .loader_request(loader_request),
        .loader_reset_owner(loader_reset_owner),
        .external_done(external_done),
        .cpu_hold_request(cpu_hold_request), .cpu_grant(cpu_grant),
        .external_grant(external_grant), .bus_owner_valid(bus_owner_valid),
        .bus_owner(bus_owner), .dma_grant(dma_grant),
        .refresh_grant(refresh_grant), .loader_grant(loader_grant),
        .protocol_error(protocol_error)
    );

    task automatic check(input logic condition, input string message);
        if (!condition)
            $fatal(1, "CHECK_FAIL: %s", message);
    endtask

    task automatic wait_edge;
        @(posedge clk);
        #1;
    endtask

    task automatic check_one_hot;
        check(!((cpu_grant && dma_grant) ||
                (cpu_grant && refresh_grant) ||
                (cpu_grant && loader_grant) ||
                (dma_grant && refresh_grant) ||
                (dma_grant && loader_grant) ||
                (refresh_grant && loader_grant)),
              "more than one bus owner was granted");
    endtask

    initial begin
        repeat (2) @(posedge clk);
        reset = 1'b0;

        check(cpu_grant && !external_grant && bus_owner_valid,
              "CPU did not own a free bus");
        check_one_hot();

        dma_request = 1'b1;
        #1;
        check(cpu_hold_request && !external_grant,
              "DMA was granted before HLDA");
        cpu_hlda = 1'b1;
        cpu_bridge_idle = 1'b0;
        #1;
        check(!external_grant, "DMA crossed a non-idle bridge");
        cpu_bridge_idle = 1'b1;
        cpu_odd_word_active = 1'b1;
        #1;
        check(!external_grant, "DMA split an odd word");
        cpu_odd_word_active = 1'b0;
        cpu_lock = 1'b1;
        #1;
        check(!external_grant, "DMA crossed CPU LOCK");
        cpu_lock = 1'b0;
        cpu_response_pending = 1'b1;
        #1;
        check(!external_grant, "DMA crossed a pending CPU response");
        cpu_response_pending = 1'b0;
        #1;
        check(external_grant && dma_grant && !cpu_grant && bus_owner == 3'd1,
              "DMA was not granted after all CPU constraints drained");
        wait_edge();

        // Once latched, the owner remains DMA even if its request disappears.
        dma_request = 1'b0;
        #1;
        check(external_grant && dma_grant && cpu_hold_request,
              "latched DMA ownership was not retained");
        external_done = 1'b1;
        wait_edge();
        external_done = 1'b0;
        check(!external_grant, "DMA owner did not release on completion");

        // Refresh has priority over a simultaneous DMA request.
        cpu_hlda = 1'b1;
        refresh_request = 1'b1;
        dma_request = 1'b1;
        #1;
        check(refresh_grant && !dma_grant,
              "refresh did not win the documented priority");
        check_one_hot();
        wait_edge();
        external_done = 1'b1;
        wait_edge();
        external_done = 1'b0;
        refresh_request = 1'b0;
        dma_request = 1'b0;
        cpu_hlda = 1'b0;

        // Reset-held loader ownership bypasses HLDA and does not assert HOLD.
        loader_reset_owner = 1'b1;
        loader_request = 1'b1;
        #1;
        check(loader_grant && external_grant && !cpu_hold_request &&
              !cpu_grant, "reset-held loader waited for CPU ownership");
        wait_edge();
        loader_request = 1'b0;
        external_done = 1'b1;
        wait_edge();
        external_done = 1'b0;
        loader_reset_owner = 1'b0;
        check(!external_grant, "loader ownership did not release");

        check(!protocol_error, "arbiter raised a protocol error");
        $display("A2_ARBITER_PASS");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "CHECK_FAIL: global timeout");
    end
endmodule
