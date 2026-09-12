`timescale 1ns/1ps

module spk286_at_mister_memory_port_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    logic cancel_cpu = 1'b0;

    logic        cpu_valid;
    logic        cpu_command_valid;
    logic        cpu_write;
    logic        cpu_code_fetch;
    logic [3:0]  cpu_cycle_class;
    logic [23:0] cpu_address;
    logic [1:0]  cpu_byte_enable;
    logic [15:0] cpu_data_out;
    logic        cpu_accept;
    logic        cpu_ready;
    logic [15:0] cpu_read_data;
    logic        cpu_read_data_valid;

    logic        loader_valid;
    logic        loader_write;
    logic [23:0] loader_address;
    logic [1:0]  loader_byte_enable;
    logic [15:0] loader_data_out;
    logic        loader_accept;
    logic        loader_ready;
    logic [15:0] loader_read_data;

    logic        dma_valid;
    logic        dma_write;
    logic [23:0] dma_address;
    logic [1:0]  dma_byte_enable;
    logic [15:0] dma_data_out;
    logic        dma_accept;
    logic        dma_ready;
    logic [15:0] dma_read_data;

    logic        refresh_valid;
    logic [23:0] refresh_address;
    logic        refresh_accept;
    logic        refresh_ready;

    logic        backend_valid;
    logic        backend_command_valid;
    logic [1:0]  backend_owner;
    logic        backend_write;
    logic        backend_refresh;
    logic        backend_code_fetch;
    logic [3:0]  backend_cycle_class;
    logic [23:0] backend_address;
    logic [1:0]  backend_byte_enable;
    logic [15:0] backend_data_out;
    logic        backend_accept;
    logic        backend_ready;
    logic [15:0] backend_read_data;
    logic        backend_read_data_valid;
    logic        protocol_error;

    localparam logic [1:0] OWNER_CPU      = 2'd0;
    localparam logic [1:0] OWNER_DMA      = 2'd1;
    localparam logic [1:0] OWNER_REFRESH  = 2'd2;
    localparam logic [1:0] OWNER_LOADER   = 2'd3;

    always #5 clk = ~clk;

    spk286_at_mister_memory_port dut (
        .clk(clk),
        .reset(reset),
        .cancel_cpu(cancel_cpu),
        .cpu_valid(cpu_valid),
        .cpu_command_valid(cpu_command_valid),
        .cpu_write(cpu_write),
        .cpu_code_fetch(cpu_code_fetch),
        .cpu_cycle_class(cpu_cycle_class),
        .cpu_address(cpu_address),
        .cpu_byte_enable(cpu_byte_enable),
        .cpu_data_out(cpu_data_out),
        .cpu_accept(cpu_accept),
        .cpu_ready(cpu_ready),
        .cpu_read_data(cpu_read_data),
        .cpu_read_data_valid(cpu_read_data_valid),
        .loader_valid(loader_valid), .loader_write(loader_write),
        .loader_address(loader_address),
        .loader_byte_enable(loader_byte_enable),
        .loader_data_out(loader_data_out),
        .loader_accept(loader_accept), .loader_ready(loader_ready),
        .loader_read_data(loader_read_data),
        .dma_valid(dma_valid),
        .dma_write(dma_write),
        .dma_address(dma_address),
        .dma_byte_enable(dma_byte_enable),
        .dma_data_out(dma_data_out),
        .dma_accept(dma_accept),
        .dma_ready(dma_ready),
        .dma_read_data(dma_read_data),
        .refresh_valid(refresh_valid),
        .refresh_address(refresh_address),
        .refresh_accept(refresh_accept),
        .refresh_ready(refresh_ready),
        .backend_valid(backend_valid),
        .backend_command_valid(backend_command_valid),
        .backend_owner(backend_owner),
        .backend_write(backend_write),
        .backend_refresh(backend_refresh),
        .backend_code_fetch(backend_code_fetch),
        .backend_cycle_class(backend_cycle_class),
        .backend_address(backend_address),
        .backend_byte_enable(backend_byte_enable),
        .backend_data_out(backend_data_out),
        .backend_accept(backend_accept),
        .backend_ready(backend_ready),
        .backend_read_data(backend_read_data),
        .backend_read_data_valid(backend_read_data_valid),
        .protocol_error(protocol_error)
    );

    task automatic check(input logic condition, input string message);
        begin
            if (condition !== 1'b1) begin
                $display("AT_MISTER_MEMORY_PORT_FAIL %s", message);
                $fatal(1);
            end
        end
    endtask

    initial begin
        cpu_valid              = 1'b0;
        cpu_command_valid      = 1'b0;
        cpu_write              = 1'b0;
        cpu_code_fetch         = 1'b1;
        cpu_cycle_class        = 4'b0101;
        cpu_address            = 24'h000000;
        cpu_byte_enable        = 2'b11;
        cpu_data_out           = 16'h0000;
        loader_valid           = 1'b0;
        loader_write           = 1'b0;
        loader_address         = 24'h000000;
        loader_byte_enable     = 2'b11;
        loader_data_out        = 16'h0000;
        dma_valid              = 1'b0;
        dma_write              = 1'b0;
        dma_address            = 24'h000000;
        dma_byte_enable        = 2'b11;
        dma_data_out           = 16'h0000;
        refresh_valid          = 1'b0;
        refresh_address        = 24'h000000;
        backend_accept         = 1'b0;
        backend_ready          = 1'b1;
        backend_read_data      = 16'h0000;
        backend_read_data_valid = 1'b0;

        repeat (3) @(posedge clk);
        reset = 1'b0;

        // Idle backend readiness must not create a phantom completion.
        @(negedge clk);
        check(!backend_valid && !cpu_ready && !dma_ready && !refresh_ready,
              "idle backend response leaked");

        // CPU request: address/control are latched before its command phase.
        cpu_valid = 1'b1;
        cpu_address = 24'h012340;
        cpu_byte_enable = 2'b01;
        @(posedge clk);
        @(negedge clk);
        check(backend_valid && backend_owner == OWNER_CPU,
              "CPU request was not selected");
        check(!backend_command_valid && !cpu_accept,
              "CPU command accepted before command phase");
        check(backend_address == 24'h012340 && backend_byte_enable == 2'b01,
              "CPU metadata was not latched");

        cpu_command_valid = 1'b1;
        backend_accept = 1'b1;
        #1;
        check(cpu_accept && backend_command_valid,
              "CPU command was not offered to backend");
        @(posedge clk);
        #1;
        backend_accept = 1'b0;
        cpu_address = 24'h0badc0;
        cpu_byte_enable = 2'b10;
        cpu_command_valid = 1'b0;
        backend_ready = 1'b0;
        backend_read_data = 16'h5a3c;
        backend_read_data_valid = 1'b1;
        @(negedge clk);
        check(backend_address == 24'h012340 && backend_byte_enable == 2'b01,
              "CPU metadata changed while backend stalled");
        check(!cpu_ready && !cpu_read_data_valid,
              "CPU completed while backend was stalled");

        backend_ready = 1'b1;
        #1;
        check(cpu_ready && cpu_read_data_valid && cpu_read_data == 16'h5a3c,
              "CPU read response was not returned");
        @(posedge clk);
        #1;
        cpu_valid = 1'b0;
        cpu_command_valid = 1'b0;
        backend_read_data_valid = 1'b0;

        // The boot loader is a first-class owner and wins over runtime
        // candidates while it writes the BIOS image.
        loader_valid = 1'b1;
        loader_write = 1'b1;
        loader_address = 24'h0f0000;
        loader_byte_enable = 2'b11;
        loader_data_out = 16'h2860;
        backend_accept = 1'b1;
        @(posedge clk);
        @(negedge clk);
        check(backend_owner == OWNER_LOADER && loader_accept &&
              !cpu_accept && !refresh_accept && !dma_accept,
              "loader did not own the backend exclusively");
        @(posedge clk);
        #1;
        loader_valid = 1'b0;
        backend_accept = 1'b0;
        backend_ready = 1'b0;
        @(negedge clk);
        backend_ready = 1'b1;
        #1;
        check(loader_ready && !cpu_ready && !refresh_ready && !dma_ready,
              "loader completion was not returned exclusively");
        @(posedge clk);
        #1;

        // Refresh has priority over DMA at this boundary and owns the port.
        refresh_valid = 1'b1;
        refresh_address = 24'h00abc0;
        dma_valid = 1'b1;
        dma_write = 1'b0;
        dma_address = 24'h00d000;
        backend_accept = 1'b1;
        @(posedge clk);
        @(negedge clk);
        check(backend_owner == OWNER_REFRESH && backend_refresh,
              "refresh did not win the documented priority");
        check(refresh_accept && !dma_accept,
              "refresh/DMA ownership was not exclusive");
        @(posedge clk);
        #1;
        refresh_valid = 1'b0;
        refresh_address = 24'h00ffff;
        dma_address = 24'h00eeee;
        backend_accept = 1'b0;
        backend_ready = 1'b0;
        @(negedge clk);
        check(backend_address == 24'h00abc0,
              "refresh address changed while backend stalled");
        backend_ready = 1'b1;
        #1;
        check(refresh_ready && !dma_ready,
              "refresh completion was not returned exclusively");
        @(posedge clk);
        #1;
        dma_valid = 1'b0;

        // DMA write: acceptance and completion are separate events.
        dma_valid = 1'b1;
        dma_write = 1'b1;
        dma_address = 24'h001234;
        dma_byte_enable = 2'b10;
        dma_data_out = 16'ha55a;
        backend_ready = 1'b0;
        @(posedge clk);
        @(negedge clk);
        check(backend_owner == OWNER_DMA && backend_write &&
              backend_address == 24'h001234 && backend_data_out == 16'ha55a,
              "DMA write was not presented with stable metadata");
        backend_accept = 1'b1;
        #1;
        check(dma_accept && !refresh_accept,
              "DMA write was not accepted");
        @(posedge clk);
        #1;
        backend_accept = 1'b0;
        backend_ready = 1'b1;
        #1;
        check(dma_ready && !cpu_ready && !refresh_ready,
              "DMA write completion was not returned exclusively");
        @(posedge clk);
        dma_valid = 1'b0;

        check(protocol_error, "simultaneous candidate ownership was not diagnosed");

        // Reset between CPU address selection and backend acceptance used
        // to retain the old address and execute it as the post-reset fetch.
        @(negedge clk);
        backend_ready=0;
        cpu_valid=1;
        cpu_command_valid=0;
        cpu_address=24'h012340;
        @(posedge clk); @(negedge clk);
        check(backend_valid && backend_address == 24'h012340,
              "preaccept reset setup");
        cancel_cpu=1;
        cpu_valid=0;
        #1;
        check(!cpu_accept && !cpu_ready && !backend_command_valid,
              "CPU control leaked during reset");
        @(posedge clk); @(negedge clk);
        check(!backend_valid, "CPU reset did not discard unaccepted address");
        cancel_cpu=0;
        cpu_valid=1;
        cpu_command_valid=1;
        cpu_address=24'hFFFFF0;
        @(posedge clk); @(negedge clk);
        check(backend_address == 24'hFFFFF0 && backend_command_valid,
              "reset fetch inherited pre-reset address");
        backend_accept=1;
        @(posedge clk); #1;
        backend_accept=0;
        backend_ready=1;
        backend_read_data_valid=1;
        backend_read_data=16'h00EA;
        #1;
        check(cpu_ready && cpu_read_data_valid && cpu_read_data == 16'h00EA,
              "post-reset fetch did not complete");
        @(posedge clk); #1;
        cpu_valid=0;
        cpu_command_valid=0;
        backend_ready=0;
        backend_read_data_valid=0;

        // Accepted commands must drain even after a one-clock CPU reset.
        // Their eventual response must not acknowledge a new CPU request.
        @(negedge clk);
        cpu_valid=1;
        cpu_command_valid=1;
        cpu_address=24'h056780;
        @(posedge clk); @(negedge clk);
        backend_accept=1;
        @(posedge clk); #1;
        backend_accept=0;
        cancel_cpu=1;
        cpu_valid=0;
        cpu_command_valid=0;
        @(posedge clk); @(negedge clk);
        check(backend_valid && !backend_command_valid && !cpu_ready,
              "accepted CPU command was not retained for draining");
        cancel_cpu=0;
        cpu_valid=1;
        cpu_command_valid=1;
        cpu_address=24'hFFFFF0;
        backend_ready=1;
        backend_read_data_valid=1;
        backend_read_data=16'hBAD0;
        #1;
        check(!cpu_accept && !cpu_ready && !cpu_read_data_valid &&
              backend_address == 24'h056780,
              "discarded pre-reset response leaked after reset ended");
        @(posedge clk); #1;
        backend_ready=0;
        backend_read_data_valid=0;
        @(posedge clk); @(negedge clk);
        check(backend_address == 24'hFFFFF0 && backend_command_valid,
              "new reset fetch did not follow drained access");
        backend_accept=1;
        @(posedge clk); #1;
        backend_accept=0;
        backend_ready=1;
        backend_read_data_valid=1;
        backend_read_data=16'h12EA;
        #1;
        check(cpu_ready && cpu_read_data_valid && cpu_read_data == 16'h12EA,
              "new fetch received the drained stale response");
        @(posedge clk); #1;
        cpu_valid=0;
        cpu_command_valid=0;
        backend_ready=0;
        backend_read_data_valid=0;

        // Reset the test's diagnostic latch, then keep CPU reset high while
        // a BIOS loader transfer proceeds, including a residual CPU valid.
        reset=1;
        @(posedge clk); @(negedge clk);
        reset=0;
        cancel_cpu=1;
        cpu_valid=1;
        cpu_command_valid=1;
        loader_valid=1;
        loader_write=1;
        loader_address=24'h0F1000;
        loader_data_out=16'hCAFE;
        @(posedge clk); @(negedge clk);
        check(backend_owner == OWNER_LOADER && backend_command_valid &&
              backend_address == 24'h0F1000 && !cpu_accept,
              "CPU reset blocked the ROM loader");
        backend_accept=1;
        #1;
        check(loader_accept && !cpu_accept, "loader acceptance during CPU reset");
        @(posedge clk); #1;
        backend_accept=0;
        backend_ready=1;
        #1;
        check(loader_ready && !cpu_ready, "loader response during CPU reset");
        @(posedge clk); #1;
        loader_valid=0;
        backend_ready=0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        check(!backend_valid && !cpu_accept && !cpu_ready && !protocol_error,
              "reset CPU became a candidate or produced a false collision");
        cpu_valid=0;
        cpu_command_valid=0;
        cancel_cpu=0;
        $display("AT_MISTER_MEMORY_PORT_CPU_RESET_PASS preaccept_cancel accepted_drain loader_preserved");
        $display("AT_MISTER_MEMORY_PORT_PASS");
        $finish;
    end
endmodule
