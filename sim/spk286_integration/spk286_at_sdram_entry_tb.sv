`timescale 1ns/1ps
// SDRAM admission: early writes, retained payload, burst ordering and reset.
module spk286_at_sdram_entry_tb #(
    parameter integer CHIP_CLK_ADVANCE_NS = 0
);
    logic clk = 0, reset = 1;
    always #10 clk = ~clk;
    wire chip_clk;
    generate
        if (CHIP_CLK_ADVANCE_NS == 0) begin : same_phase
            assign chip_clk = clk;
        end else begin : advanced_phase
            logic phase_clk = 0;
            initial begin
                #(10-CHIP_CLK_ADVANCE_NS) phase_clk = 1;
                forever #10 phase_clk = ~phase_clk;
            end
            assign chip_clk = phase_clk;
        end
    endgenerate
    logic request_valid = 0, request_command_valid = 0, request_owner_refresh = 0;
    logic request_write = 0, request_code_fetch = 0, request_burst = 0;
    logic [3:0] request_cycle_class = 4'h5;
    logic [24:0] request_address = 0;
    logic [1:0] request_byte_enable = 0;
    logic [15:0] request_data_out = 0;
    wire request_accept, request_ready, request_read_data_valid, physical_idle, protocol_error;
    wire [15:0] request_read_data;
    wire [7:0] debug_state;
    wire [12:0] sdram_address;
    wire sdram_cke, sdram_cs, sdram_ras, sdram_cas, sdram_we, sdram_dq_io;
    wire sdram_ldqm, sdram_udqm;
    wire [1:0] sdram_ba, dq_valid;
    wire [15:0] sdram_dq_in, sdram_dq_out;
    integer reads, writes, checks = 0, beats = 0, refresh_cycles = 0;

    spk286_at_mister_sdram_owner #(.SDRAM_INIT_WAIT(16'd8),
        .SDRAM_REFRESH_CYCLE(16'd20), .SDRAM_FORCE_REFRESH(16'd100)) dut (.*);
    spk286_sdram_pin_model #(.MEM_WORDS(4096)) ram (
        .clk(chip_clk), .reset(reset), .address(sdram_address), .cke(sdram_cke),
        .cs_n(sdram_cs), .ras_n(sdram_ras), .cas_n(sdram_cas), .we_n(sdram_we),
        .ba(sdram_ba), .dq_from_controller(sdram_dq_out), .controller_dq_oe(!sdram_dq_io),
        .dqm({sdram_udqm,sdram_ldqm}), .dq_to_controller(sdram_dq_in),
        .dq_valid(dq_valid), .read_count(reads), .write_count(writes));
    always @(posedge clk) if (!reset && debug_state[0]) refresh_cycles = refresh_cycles + 1;

    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1) $fatal(1, "SDRAM_ENTRY %s", message);
    endtask

    task automatic idle;
        integer guard;
        guard = 0;
        while (!physical_idle && guard < 400) begin @(negedge clk); guard++; end
        check(physical_idle, "idle timeout");
    endtask

    task automatic admit(input logic wr, input logic burst, input logic refresh,
                         input logic [24:0] address, input logic [1:0] lanes,
                         input logic [15:0] data);
        integer guard;
        idle();
        @(negedge clk);
        request_valid = 1; request_command_valid = 1;
        request_owner_refresh = refresh; request_write = wr; request_burst = burst;
        request_address = address; request_byte_enable = lanes; request_data_out = data;
        #1;
        guard = 0;
        while (!request_accept && guard < 400) begin @(negedge clk); #1; guard++; end
        check(request_accept, "admission timeout");
        @(posedge clk); #1;
        check(dut.active_q && dut.issued_q == (wr && !refresh),
              "admission did not retain the expected launch state");
        if (wr && !refresh)
            check(!dut.kf_idle && !dut.launch_request,
                  "write did not enter KFSDRAM on its accepting edge");
        else
            check(dut.kf_idle, "read/refresh launched before its retained entry");
        if (!refresh) check(!request_ready && !request_read_data_valid, "premature completion");
        // Withdraw the upstream request and corrupt every live payload field
        // before KFSDRAM's registered row/column commands. Accepted physical
        // work must still drain, including a write launched on admission.
        request_valid = 0; request_command_valid = 0;
        request_owner_refresh = !refresh; request_write = !wr; request_burst = !burst;
        request_address = 25'h1FFFFFF; request_byte_enable = 0; request_data_out = 16'hDEAD;
    endtask

    task automatic finish_write;
        integer guard;
        guard = 0;
        while (!request_ready && guard < 400) begin @(negedge clk); guard++; end
        check(request_ready && !request_read_data_valid, "write/refresh completion timeout");
        @(posedge clk); #1;
        idle();
    endtask

    task automatic read_words(input logic burst, input logic [15:0] first);
        integer count, guard;
        count = 0; guard = 0;
        while (!request_ready && guard < 400) begin
            @(negedge clk); guard++;
            if (request_read_data_valid) begin
                check(request_read_data == first + 16'(count), "read data/order mismatch");
                count++; beats++;
            end
        end
        check(request_ready && request_read_data_valid, "read completion timeout");
        check(count == (burst ? 4 : 1), "wrong burst length");
        @(posedge clk); #1;
        idle();
    endtask

    initial begin
        repeat (3) @(posedge clk);
        #1; reset = 0; idle();
        for (integer n = 0; n < 4; n++) begin
            admit(1,0,0,25'h1000 + 25'(2*n),2'b11,16'h1230 + 16'(n)); finish_write();
        end
        admit(0,1,0,25'h1000,2'b11,0); read_words(1,16'h1230);
        admit(1,0,0,25'h1000,2'b01,16'h00CC); finish_write();
        admit(1,0,0,25'h1001,2'b10,16'hA500); finish_write();
        admit(0,0,0,25'h1000,2'b11,0); read_words(0,16'hA5CC);
        admit(0,0,1,0,2'b11,0); finish_write();
        check(refresh_cycles > 0, "periodic refresh was not exercised");
        check(!protocol_error, "protocol error on valid transactions");

        // Reset after early launch, before its registered ACTIVE/WRITE commands,
        // discards the transaction. SDRAM contents survive; no write may leak.
        admit(1,0,0,25'h1002,2'b11,16'hFFFF);
        @(negedge clk); reset = 1;
        repeat (3) @(posedge clk);
        #1; reset = 0; idle();
        admit(0,0,0,25'h1002,2'b11,0); read_words(0,16'h1231);
        check(!protocol_error, "protocol error after reset/drain");

        @(negedge clk);
        request_valid = 1; request_command_valid = 1; request_byte_enable = 0;
        #1; check(!request_accept, "zero-lane request accepted");
        repeat (3) @(posedge clk);
        #1; check(protocol_error, "invalid request was not reported");
        request_valid = 0; request_command_valid = 0;
        $display("SDRAM_ENTRY_PASS checks=%0d beats=%0d refresh=1 stable_payload=1 burst=1 reset=1",checks,beats);
        $finish;
    end
endmodule
