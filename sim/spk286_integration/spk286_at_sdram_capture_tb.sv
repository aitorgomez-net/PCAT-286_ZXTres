`timescale 1ns/1ps
module spk286_at_sdram_capture_tb #(
    parameter real SDRAM_CLOCK_SKEW_NS = 0.0,
    parameter real COMMAND_PIN_DELAY_NS = 1.0
);
    reg clk = 1'b0;
    always #10 clk = ~clk;
    reg reset = 1'b1;
    reg valid = 1'b0;
    reg write_request = 1'b0;
    reg [23:0] request_address = 24'h000000;
    reg [1:0] lanes = 2'b11;
    reg [15:0] write_data = 16'h0000;
    wire accept, ready, data_valid, idle, protocol_error;
    wire [15:0] read_data;
    wire [12:0] a;
    wire cke, cs_n, ras_n, cas_n, we_n;
    wire [1:0] ba;
    wire [15:0] dq_out, dq_in;
    wire dq_io, ldqm, udqm;
    wire [1:0] dq_valid;
    wire model_clk;
    wire [12:0] pin_a;
    wire pin_cke, pin_cs_n, pin_ras_n, pin_cas_n, pin_we_n;
    wire [1:0] pin_ba, pin_dqm;
    wire [15:0] pin_dq_out;
    wire pin_dq_oe;
    wire [31:0] reads, writes;
    integer transactions = 0;

    assign #(SDRAM_CLOCK_SKEW_NS) model_clk = clk;
    assign #(COMMAND_PIN_DELAY_NS) pin_a = a;
    assign #(COMMAND_PIN_DELAY_NS) pin_cke = cke;
    assign #(COMMAND_PIN_DELAY_NS) pin_cs_n = cs_n;
    assign #(COMMAND_PIN_DELAY_NS) pin_ras_n = ras_n;
    assign #(COMMAND_PIN_DELAY_NS) pin_cas_n = cas_n;
    assign #(COMMAND_PIN_DELAY_NS) pin_we_n = we_n;
    assign #(COMMAND_PIN_DELAY_NS) pin_ba = ba;
    assign #(COMMAND_PIN_DELAY_NS) pin_dqm = {udqm, ldqm};
    assign #(COMMAND_PIN_DELAY_NS) pin_dq_out = dq_out;
    assign #(COMMAND_PIN_DELAY_NS) pin_dq_oe = !dq_io;

    spk286_at_mister_sdram_owner #(.SDRAM_INIT_WAIT(16'd8)) dut (
        .clk(clk), .reset(reset), .request_valid(valid),
        .request_command_valid(valid), .request_owner_refresh(1'b0),
        .request_write(write_request), .request_code_fetch(!write_request),
        .request_cycle_class(4'h0), .request_address(request_address),
        .request_byte_enable(lanes), .request_data_out(write_data),
        .request_accept(accept), .request_ready(ready),
        .request_read_data(read_data), .request_read_data_valid(data_valid),
        .physical_idle(idle), .protocol_error(protocol_error),
        .sdram_address(a), .sdram_cke(cke), .sdram_cs(cs_n),
        .sdram_ras(ras_n), .sdram_cas(cas_n), .sdram_we(we_n),
        .sdram_ba(ba), .sdram_dq_in(dq_in), .sdram_dq_out(dq_out),
        .sdram_dq_io(dq_io), .sdram_ldqm(ldqm), .sdram_udqm(udqm)
    );
    spk286_sdram_pin_model #(.MEM_WORDS(1048576)) memory (
        .clk(model_clk), .reset(reset), .address(pin_a), .cke(pin_cke),
        .cs_n(pin_cs_n), .ras_n(pin_ras_n), .cas_n(pin_cas_n),
        .we_n(pin_we_n), .ba(pin_ba), .dq_from_controller(pin_dq_out),
        .controller_dq_oe(pin_dq_oe), .dqm(pin_dqm),
        .dq_to_controller(dq_in), .dq_valid(dq_valid),
        .read_count(reads), .write_count(writes)
    );

    task automatic transaction(input bit wr, input [23:0] byte_address,
                               input [1:0] byte_lanes, input [15:0] data);
        integer guard;
        begin
            @(negedge clk);
            valid = 1'b1;
            write_request = wr;
            request_address = byte_address;
            lanes = byte_lanes;
            write_data = data;
            #1;
            guard = 0;
            while (!accept && guard < 1000) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (!accept) $fatal(1, "CAPTURE_TEST acceptance timeout");
            @(posedge clk); #1;
            valid = 1'b0;
            guard = 0;
            while (!ready && guard < 1000) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (!ready) $fatal(1, "CAPTURE_TEST ready timeout");
            if (!wr && (!data_valid || read_data !== data))
                $fatal(1, "CAPTURE_TEST read %h expected=%h actual=%h clock_skew=%0.1f", byte_address, data, read_data, SDRAM_CLOCK_SKEW_NS);
            $display("SDRAM_CAPTURE %s byte=%h word=%h lanes=%b data=%h", wr ? "WRITE" : "READ ", byte_address, dut.kf_address, byte_lanes, wr ? data : read_data);
            transactions = transactions + 1;
            @(posedge clk); #1;
        end
    endtask

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("at_sdram_capture.vcd");
            $dumpvars(0, spk286_at_sdram_capture_tb);
        end
        repeat (4) @(negedge clk);
        reset = 1'b0;
        wait(idle);
        // Actual local Sergey reset bytes: EA 5B E0 00 F0 30.
        transaction(1, 24'h0FFFF0, 2'b11, 16'h5BEA);
        transaction(1, 24'h0FFFF2, 2'b11, 16'h00E0);
        transaction(1, 24'h0FFFF4, 2'b11, 16'h30F0);
        if (memory.mem[24'h07FFF8] !== 16'h5BEA)
            $fatal(1, "CAPTURE_TEST loader address does not match exact physical word");
        transaction(0, 24'hFFFFF0, 2'b11, 16'h5BEA);
        transaction(0, 24'hFFFFF2, 2'b11, 16'h00E0);
        transaction(0, 24'h0FFFF4, 2'b11, 16'h30F0);
        transaction(1, 24'h0003FE, 2'b11, 16'hA55A);
        transaction(1, 24'h000400, 2'b11, 16'h77CC);
        transaction(0, 24'h0003FE, 2'b11, 16'hA55A);
        transaction(0, 24'h000400, 2'b11, 16'h77CC);
        transaction(1, 24'h0003FF, 2'b10, 16'h3C00);
        transaction(0, 24'h0003FE, 2'b11, 16'h3C5A);
        transaction(1, 24'h0003FE, 2'b01, 16'h0081);
        transaction(0, 24'h0003FF, 2'b10, 16'h3C81);
        if (protocol_error) $fatal(1, "CAPTURE_TEST protocol_error");
        repeat (12) @(negedge clk);
        if (dq_in !== memory.INVALID_DATA || dq_valid !== 2'b00)
            $fatal(1, "CAPTURE_TEST model did not release DQ after burst");
        $display("AT_SDRAM_CAPTURE_PASS transactions=%0d writes=%0d reads=%0d skew=%0.1f", transactions, writes, reads, SDRAM_CLOCK_SKEW_NS);
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "CAPTURE_TEST global timeout");
    end
endmodule
