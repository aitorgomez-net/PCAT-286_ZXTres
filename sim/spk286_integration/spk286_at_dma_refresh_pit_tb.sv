`timescale 1ns/1ps

module spk286_at_dma_refresh_pit_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    // DMA register transaction boundary.
    logic        dma_request_valid = 1'b0;
    logic        dma_request_command_valid = 1'b0;
    logic        dma_request_write = 1'b0;
    logic        dma_request_io = 1'b0;
    logic [23:0] dma_request_address = 24'h000000;
    logic [1:0]  dma_request_byte_enable = 2'b00;
    logic [15:0] dma_request_data_out = 16'h0000;
    wire         dma_request_accept;
    wire         dma_request_ready;
    wire [15:0]  dma_request_read_data;
    wire         dma_request_read_data_valid;

    logic [7:0]  dma_request_lines = 8'h00;
    wire         dma_bus_request;
    wire         dma_transfer_valid;
    wire [2:0]   dma_active_channel;
    wire [23:0]  dma_transfer_address;
    wire [1:0]   dma_transfer_byte_enable;
    wire         dma_transfer_write_to_memory;
    wire         dma_transfer_read_from_memory;
    wire         dma_transfer_io_to_memory;
    wire         dma_transfer_memory_to_io;
    wire [15:0]  dma_transfer_data_out;
    wire         dma_transfer_complete;
    wire         dma_terminal_count;
    wire [7:0]   dma_request_state;
    wire [7:0]   dma_acknowledge;
    wire         cascade_request;
    wire         dma_protocol_error;

    // The endpoint presents one accept phase followed by one ready phase.
    logic        dma_endpoint_seen = 1'b0;
    wire         dma_transfer_accept = dma_transfer_valid && !dma_endpoint_seen;
    wire         dma_transfer_ready = dma_transfer_valid && dma_endpoint_seen;
    logic [23:0] dma_addresses [0:7];
    logic [1:0] dma_lanes [0:7];
    logic [15:0] dma_payloads [0:7];
    integer dma_beat_count = 0;
    integer dma_terminal_count_seen = 0;

    spk286_at_dma dma (
        .clk(clk), .reset(reset),
        .request_valid(dma_request_valid),
        .request_command_valid(dma_request_command_valid),
        .request_write(dma_request_write), .request_io(dma_request_io),
        .request_address(dma_request_address),
        .request_byte_enable(dma_request_byte_enable),
        .request_data_out(dma_request_data_out),
        .request_accept(dma_request_accept), .request_ready(dma_request_ready),
        .request_read_data(dma_request_read_data),
        .request_read_data_valid(dma_request_read_data_valid),
        .dma_request(dma_request_lines), .dma_grant(dma_grant),
        .transfer_accept(dma_transfer_accept),
        .transfer_ready(dma_transfer_ready),
        .transfer_data_in(16'hA55A),
        .dma_bus_request(dma_bus_request),
        .dma_transfer_valid(dma_transfer_valid),
        .dma_active_channel(dma_active_channel),
        .dma_transfer_address(dma_transfer_address),
        .dma_transfer_byte_enable(dma_transfer_byte_enable),
        .dma_transfer_write_to_memory(dma_transfer_write_to_memory),
        .dma_transfer_read_from_memory(dma_transfer_read_from_memory),
        .dma_transfer_io_to_memory(dma_transfer_io_to_memory),
        .dma_transfer_memory_to_io(dma_transfer_memory_to_io),
        .dma_transfer_data_out(dma_transfer_data_out),
        .dma_transfer_complete(dma_transfer_complete),
        .dma_terminal_count(dma_terminal_count),
        .dma_request_state(dma_request_state),
        .dma_acknowledge(dma_acknowledge),
        .cascade_request(cascade_request),
        .protocol_error(dma_protocol_error)
    );

    // Refresh requester and endpoint boundary.
    logic refresh_enable = 1'b0;
    wire refresh_request;
    wire refresh_bus_valid;
    wire [23:0] refresh_address;
    wire refresh_complete;
    wire [15:0] refresh_count;
    wire refresh_protocol_error;
    logic refresh_endpoint_seen = 1'b0;
    wire refresh_accept = refresh_bus_valid && !refresh_endpoint_seen;
    wire refresh_ready = refresh_bus_valid && refresh_endpoint_seen;
    integer refresh_beat_count = 0;

    spk286_at_refresh #(.REFRESH_INTERVAL(4)) refresh (
        .clk(clk), .reset(reset), .refresh_enable(refresh_enable),
        .refresh_grant(refresh_grant), .refresh_accept(refresh_accept),
        .refresh_ready(refresh_ready), .refresh_request(refresh_request),
        .refresh_bus_valid(refresh_bus_valid),
        .refresh_address(refresh_address),
        .refresh_complete(refresh_complete),
        .refresh_count(refresh_count),
        .protocol_error(refresh_protocol_error)
    );

    // AT ownership arbitration.  HLDA is withheld while both requests are
    // pending so the documented refresh-over-DMA priority is observable.
    logic cpu_hlda = 1'b0;
    logic cpu_bridge_idle = 1'b1;
    logic cpu_lock = 1'b0;
    logic cpu_odd_word_active = 1'b0;
    logic cpu_inta_lock_chain = 1'b0;
    logic cpu_response_pending = 1'b0;
    wire cpu_hold_request;
    wire cpu_grant;
    wire external_grant;
    wire bus_owner_valid;
    wire [2:0] bus_owner;
    wire dma_grant;
    wire refresh_grant;
    wire loader_grant;
    wire arbiter_protocol_error;
    wire external_done = dma_transfer_complete | refresh_complete;

    spk286_at_arbiter arbiter (
        .clk(clk), .reset(reset), .cpu_hlda(cpu_hlda),
        .cpu_bridge_idle(cpu_bridge_idle), .cpu_lock(cpu_lock),
        .cpu_odd_word_active(cpu_odd_word_active),
        .cpu_inta_lock_chain(cpu_inta_lock_chain),
        .cpu_response_pending(cpu_response_pending),
        .dma_request(dma_bus_request),
        .refresh_request(refresh_request),
        .loader_request(1'b0), .loader_reset_owner(1'b0),
        .external_done(external_done), .cpu_hold_request(cpu_hold_request),
        .cpu_grant(cpu_grant), .external_grant(external_grant),
        .bus_owner_valid(bus_owner_valid), .bus_owner(bus_owner),
        .dma_grant(dma_grant), .refresh_grant(refresh_grant),
        .loader_grant(loader_grant), .protocol_error(arbiter_protocol_error)
    );

    // PIT register transaction boundary.
    logic        pit_request_valid = 1'b0;
    logic        pit_request_command_valid = 1'b0;
    logic        pit_request_write = 1'b0;
    logic        pit_request_io = 1'b0;
    logic [23:0] pit_request_address = 24'h000000;
    logic [1:0]  pit_request_byte_enable = 2'b00;
    logic [15:0] pit_request_data_out = 16'h0000;
    logic        pit_counter_clock = 1'b0;
    wire         pit_request_accept;
    wire         pit_request_ready;
    wire [15:0]  pit_request_read_data;
    wire         pit_request_read_data_valid;
    wire         pit_irq0;
    wire [2:0]   pit_counter_out;
    wire         pit_protocol_error;
    integer pit_irq_count = 0;

    spk286_at_pit pit (
        .clk(clk), .reset(reset), .counter_clock(pit_counter_clock), .counter_2_gate(1'b1),
        .request_valid(pit_request_valid),
        .request_command_valid(pit_request_command_valid),
        .request_write(pit_request_write), .request_io(pit_request_io),
        .request_address(pit_request_address),
        .request_byte_enable(pit_request_byte_enable),
        .request_data_out(pit_request_data_out),
        .request_accept(pit_request_accept), .request_ready(pit_request_ready),
        .request_read_data(pit_request_read_data),
        .request_read_data_valid(pit_request_read_data_valid),
        .irq0(pit_irq0), .counter_out(pit_counter_out),
        .protocol_error(pit_protocol_error)
    );

    task automatic check(input logic condition, input string message);
        if (!condition)
            $fatal(1, "CHECK_FAIL: %s", message);
    endtask

    task automatic dma_write(
        input logic [15:0] port,
        input logic [7:0] value
    );
        begin
            @(negedge clk);
            dma_request_address = {8'h00, port};
            dma_request_byte_enable = port[0] ? 2'b10 : 2'b01;
            dma_request_data_out = port[0] ? {value, 8'h00} :
                                             {8'h00, value};
            dma_request_valid = 1'b1;
            dma_request_command_valid = 1'b1;
            dma_request_write = 1'b1;
            dma_request_io = 1'b1;
            #1;
            check(dma_request_accept, "DMA register write was not accepted");
            @(posedge clk);
            @(negedge clk);
            dma_request_valid = 1'b0;
            dma_request_command_valid = 1'b0;
            dma_request_write = 1'b0;
            dma_request_io = 1'b0;
            #1;
            check(dma_request_ready, "DMA register write did not complete");
            @(posedge clk);
        end
    endtask

    task automatic pit_write(
        input logic [15:0] port,
        input logic [7:0] value
    );
        begin
            @(negedge clk);
            pit_request_address = {8'h00, port};
            pit_request_byte_enable = port[0] ? 2'b10 : 2'b01;
            pit_request_data_out = port[0] ? {value, 8'h00} :
                                             {8'h00, value};
            pit_request_valid = 1'b1;
            pit_request_command_valid = 1'b1;
            pit_request_write = 1'b1;
            pit_request_io = 1'b1;
            #1;
            check(pit_request_accept, "PIT register write was not accepted");
            @(posedge clk);
            @(negedge clk);
            pit_request_valid = 1'b0;
            pit_request_command_valid = 1'b0;
            pit_request_write = 1'b0;
            pit_request_io = 1'b0;
            #1;
            begin : wait_pit_ready
                integer wait_cycles;
                wait_cycles=0;
                while(!pit_request_ready && wait_cycles<16) begin
                    @(negedge clk); wait_cycles=wait_cycles+1;
                end
                check(pit_request_ready, "PIT register write did not complete");
            end
            @(posedge clk);
        end
    endtask

    task automatic pit_tick;
        begin
            // One full sampled PIT clock period (KF8253 counts falling edges).
            @(negedge clk);
            pit_counter_clock = 1'b1;
            @(posedge clk);
            @(negedge clk);
            pit_counter_clock = 1'b0;
            @(posedge clk);
        end
    endtask

    always @(posedge clk) begin
        if (reset) begin
            dma_endpoint_seen <= 1'b0;
            refresh_endpoint_seen <= 1'b0;
            dma_beat_count = 0;
            dma_terminal_count_seen = 0;
            refresh_beat_count = 0;
            pit_irq_count = 0;
        end else begin
            if (dma_transfer_valid && dma_transfer_accept) begin
                if (dma_beat_count < 8)
                    dma_addresses[dma_beat_count] = dma_transfer_address;
                if (dma_beat_count < 8) begin
                    dma_lanes[dma_beat_count] = dma_transfer_byte_enable;
                    dma_payloads[dma_beat_count] = dma_transfer_data_out;
                end
                dma_beat_count = dma_beat_count + 1;
            end
            if (dma_terminal_count)
                dma_terminal_count_seen = dma_terminal_count_seen + 1;
            if (refresh_bus_valid && refresh_accept) begin
                check(refresh_address == 24'h000000,
                      "first refresh did not start at row zero");
                refresh_beat_count = refresh_beat_count + 1;
            end
            if (pit_irq0)
                pit_irq_count = pit_irq_count + 1;

            if (!dma_transfer_valid)
                dma_endpoint_seen <= 1'b0;
            else if (!dma_endpoint_seen)
                dma_endpoint_seen <= 1'b1;
            if (!refresh_bus_valid)
                refresh_endpoint_seen <= 1'b0;
            else if (!refresh_endpoint_seen)
                refresh_endpoint_seen <= 1'b1;

            check(!(dma_grant && refresh_grant),
                  "arbiter granted DMA and refresh together");
            check(!(dma_transfer_valid && refresh_bus_valid),
                  "DMA and refresh drove the bus together");
        end
    end

    initial begin : run
        integer cycles;

        repeat (3) @(negedge clk);
        reset = 1'b0;

        // DMA1 channel 1: physical address 02:1234, two byte transfers,
        // block mode, I/O-to-memory, then unmask the channel.
        dma_write(16'h000C, 8'h00);
        dma_write(16'h0002, 8'h34);
        dma_write(16'h0002, 8'h12);
        dma_write(16'h0003, 8'h01);
        dma_write(16'h0003, 8'h00);
        dma_write(16'h0083, 8'h02);
        dma_write(16'h000B, 8'h85);
        dma_write(16'h000A, 8'h01);
        check(!dma_protocol_error, "DMA raised an error during configuration");

        dma_request_lines = 8'h02;
        refresh_enable = 1'b1;
        repeat (8) @(posedge clk);
        #1;
        check(refresh_request && dma_bus_request,
              "refresh and DMA were not pending together");
        check(cpu_hold_request && !external_grant,
              "external owner crossed a missing HLDA");

        cpu_hlda = 1'b1;
        #1;
        check(refresh_grant && !dma_grant,
              "refresh did not win over simultaneous DMA request");

        cycles = 0;
        while ((refresh_count < 16'd1) && (cycles < 40)) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        #1;
        check(refresh_count == 16'd1 && refresh_beat_count == 1,
              "refresh transaction did not complete exactly once");
        refresh_enable = 1'b0;

        cycles = 0;
        while (((dma_beat_count < 2) ||
                (dma_terminal_count_seen < 1)) && (cycles < 120)) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        #1;
        check(dma_beat_count == 2, "DMA did not complete two byte beats");
        check(dma_addresses[0] == 24'h021234 &&
              dma_addresses[1] == 24'h021235,
              "DMA page/address increment was incorrect");
        check(dma_terminal_count_seen == 1,
              "DMA did not report one terminal count");
        check(dma_lanes[0] == 2'b01 && dma_lanes[1] == 2'b10 &&
              dma_payloads[0][7:0] == 8'h5A &&
              dma_payloads[1][15:8] == 8'h5A,
              "DMA1 did not align consecutive bytes to even/odd lanes");
        check(dma_transfer_io_to_memory && !dma_transfer_memory_to_io,
              "DMA transfer direction was not I/O-to-memory");
        check(dma_request_state == 8'h00 && !dma_bus_request,
              "DMA channel remained requestable after terminal count");

        // PIT channel 0, LSB/MSB, mode 2, reload value 3.
        pit_write(16'h0043, 8'h34);
        pit_write(16'h0040, 8'h03);
        pit_write(16'h0040, 8'h00);
        #1;
        check(pit_counter_out[0], "PIT channel 0 was not running after load");
        repeat (4) pit_tick();
        #1;
        check(pit_irq_count >= 1, "PIT did not produce IRQ0");
        check(pit_counter_out[0], "PIT mode 2 output did not recover high");

        check(!refresh_protocol_error && !pit_protocol_error &&
              !arbiter_protocol_error,
              "A4 subsystem raised a protocol error");
        $display("A4_DMA_REFRESH_PIT_PASS dma_beats=%0d refreshes=%0d irq0=%0d",
                 dma_beat_count, refresh_beat_count, pit_irq_count);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "CHECK_FAIL: global timeout");
    end
endmodule
