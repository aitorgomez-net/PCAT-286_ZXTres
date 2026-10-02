`timescale 1ns/1ps

// Bounded physical owner check: changing upstream payload after acceptance,
// code bursts followed by masked writes, and periodic refresh under traffic.
module spk286_at_sdram_write_admission_tb;
    logic clk = 0, reset = 1;
    always #10 clk = ~clk;
    logic valid = 0, command = 0, refresh = 0, wr = 0, burst = 0;
    logic [24:0] address = 0;
    logic [1:0] lanes = 2'b11;
    logic [15:0] data = 0;
    wire accept, ready, read_valid, idle, protocol_error;
    wire [15:0] read_data, dq_in, dq_out;
    wire [12:0] pin_address;
    wire cke, cs, ras, cas, we, dq_io, ldqm, udqm;
    wire [1:0] bank;
    wire [1:0] dq_valid;
    integer reads, writes;
    integer refreshes = 0, cycles = 0, last_refresh = 0;
    integer write_accepts = 0, i, before_count;
    logic initialized = 0;

    spk286_at_mister_sdram_owner #(
        .SDRAM_INIT_WAIT(16'd8), .SDRAM_REFRESH_CYCLE(16'd24),
        .SDRAM_FORCE_REFRESH(16'd48)
    ) dut (
        .clk(clk), .reset(reset), .request_valid(valid),
        .request_command_valid(command), .request_owner_refresh(refresh),
        .request_write(wr), .request_code_fetch(burst), .request_burst(burst),
        .request_cycle_class(4'h0), .request_address(address),
        .request_byte_enable(lanes), .request_data_out(data),
        .request_accept(accept), .request_ready(ready),
        .request_read_data(read_data), .request_read_data_valid(read_valid),
        .physical_idle(idle), .debug_state(), .protocol_error(protocol_error),
        .sdram_address(pin_address), .sdram_cke(cke), .sdram_cs(cs),
        .sdram_ras(ras), .sdram_cas(cas), .sdram_we(we), .sdram_ba(bank),
        .sdram_dq_in(dq_in), .sdram_dq_out(dq_out), .sdram_dq_io(dq_io),
        .sdram_ldqm(ldqm), .sdram_udqm(udqm)
    );
    spk286_sdram_pin_model #(.MEM_WORDS(16777216)) pins (
        .clk(clk), .reset(reset), .address(pin_address), .cke(cke),
        .cs_n(cs), .ras_n(ras), .cas_n(cas), .we_n(we), .ba(bank),
        .dq_from_controller(dq_out), .controller_dq_oe(!dq_io),
        .dqm({udqm, ldqm}), .dq_to_controller(dq_in), .dq_valid(dq_valid),
        .read_count(reads), .write_count(writes)
    );

    always @(posedge clk) begin
        cycles = cycles + 1;
        if (cycles > 30000) $fatal(1, "WRITE_ADMISSION timeout");
        if (!reset && !cs && !ras && !cas && we) begin
            refreshes = refreshes + 1;
            last_refresh = cycles;
        end
        if (initialized && cycles - last_refresh > 100)
            $fatal(1, "WRITE_ADMISSION periodic refresh starved");
        if (!reset && protocol_error) $fatal(1, "WRITE_ADMISSION protocol error");
    end

    // Change all upstream fields immediately after admission. Physical
    // commands and completion must use the retained request until drained.
    task automatic poison;
        valid = 0; command = 0; refresh = 1; wr = 0; burst = 1;
        address = 25'h1ffffff; lanes = 2'b00; data = 16'hdead;
    endtask

    task automatic admit(input logic write_cycle, input logic line_read,
                          input logic [24:0] addr, input logic [1:0] bytes,
                          input logic [15:0] value);
        integer guard;
        @(negedge clk);
        valid = 1; command = 1; refresh = 0; wr = write_cycle;
        burst = line_read; address = addr; lanes = bytes; data = value;
        #1;
        guard = 0;
        while (!accept && guard < 200) begin
            @(negedge clk); #1; guard = guard + 1;
        end
        if (!accept) $fatal(1, "WRITE_ADMISSION not accepted");
        if (ready) $fatal(1, "WRITE_ADMISSION completed before acceptance");
        @(posedge clk); #1;
        poison();
    endtask

    task automatic put(input logic [24:0] addr, input logic [1:0] bytes,
                       input logic [15:0] value);
        integer guard, old_writes;
        old_writes = writes;
        admit(1, 0, addr, bytes, value);
        write_accepts = write_accepts + 1;
        guard = 0;
        while (!ready && guard < 200) begin
            if (read_valid) $fatal(1, "WRITE_ADMISSION read response on write");
            @(negedge clk); #1; guard = guard + 1;
        end
        if (!ready || !dut.kf_idle || writes != old_writes + 1)
            $fatal(1, "WRITE_ADMISSION physical write not drained");
        @(posedge clk); #1;
    endtask

    task automatic get(input logic [24:0] addr, input logic line_read,
                       input logic [15:0] first);
        integer guard, count, length;
        length = line_read ? 4 : 1;
        admit(0, line_read, addr, 2'b11, 0);
        guard = 0; count = 0;
        while (!ready && guard < 200) begin
            if (read_valid) begin
                if (read_data !== first + 16'(count))
                    $fatal(1, "WRITE_ADMISSION burst beat %0d got %h", count, read_data);
                count = count + 1;
            end
            @(negedge clk); #1; guard = guard + 1;
        end
        if (!ready || !read_valid || read_data !== first + 16'(count))
            $fatal(1, "WRITE_ADMISSION final read beat %0d got %h", count, read_data);
        count = count + 1;
        if (count != length) $fatal(1, "WRITE_ADMISSION wrong burst length");
        @(posedge clk); #1;
    endtask

    initial begin
        repeat (3) @(negedge clk);
        reset = 0;
        wait (idle);
        initialized = 1; last_refresh = cycles;
        // A retained burst must not turn the next accepted write into a burst.
        for (i = 0; i < 4; i = i + 1) put(25'h2000 + 25'(2*i), 2'b11, 16'h3100 + 16'(i));
        get(25'h2000, 1, 16'h3100);
        put(25'h1002100, 2'b11, 16'ha55a);
        put(25'h1002101, 2'b10, 16'hc300);
        get(25'h1002100, 0, 16'hc35a);
        put(25'h1002100, 2'b01, 16'h007e);
        get(25'h1002100, 0, 16'hc37e);
        // No extra idle gaps: alternate banks/rows and then verify each word.
        for (i = 0; i < 64; i = i + 1)
            put(25'h2400 + 25'(2*i) + (i[0] ? 25'h1000000 : 0),
                2'b11, 16'h5000 + 16'(i));
        for (i = 0; i < 64; i = i + 1)
            get(25'h2400 + 25'(2*i) + (i[0] ? 25'h1000000 : 0), 0, 16'h5000 + 16'(i));
        if (writes != write_accepts || refreshes < 10)
            $fatal(1, "WRITE_ADMISSION counts writes=%0d accepted=%0d refresh=%0d",
                   writes, write_accepts, refreshes);
        $display("AT_SDRAM_WRITE_ADMISSION_PASS writes=%0d reads=%0d refreshes=%0d cycles=%0d",
                 writes, reads, refreshes, cycles);
        $finish;
    end
endmodule
