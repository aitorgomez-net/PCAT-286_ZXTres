`timescale 1ns/1ps

module spk286_at_mister_sdram_owner_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    logic        request_valid;
    logic        request_command_valid;
    logic        request_owner_refresh;
    logic        request_write;
    logic        request_code_fetch;
    logic [3:0]  request_cycle_class;
    logic [24:0] request_address;
    logic [1:0]  request_byte_enable;
    logic [15:0] request_data_out;
    wire         request_accept;
    wire         request_ready;
    wire [15:0]  request_read_data;
    wire         request_read_data_valid;
    wire         physical_idle;
    wire         protocol_error;

    wire [12:0] sdram_address;
    wire        sdram_cke;
    wire        sdram_cs;
    wire        sdram_ras;
    wire        sdram_cas;
    wire        sdram_we;
    wire [1:0]  sdram_ba;
    logic [15:0] sdram_dq_in;
    wire [15:0] sdram_dq_out;
    wire        sdram_dq_io;
    wire        sdram_ldqm;
    wire        sdram_udqm;

    localparam integer MEM_WORDS = 16777216;
    logic [15:0] mem [0:MEM_WORDS-1];
    logic [12:0] active_row = 13'd0;
    logic [1:0]  active_bank = 2'd0;
    logic [15:0] read_data_d1 = 16'h0000;
    logic [15:0] read_data_d2 = 16'h0000;
    integer sdram_reads = 0;
    integer sdram_writes = 0;
    integer i;

    wire command_active = !sdram_cs && !sdram_ras && sdram_cas && sdram_we;
    wire command_read   = !sdram_cs && sdram_ras && !sdram_cas && sdram_we;
    wire command_write  = !sdram_cs && sdram_ras && !sdram_cas && !sdram_we;
    wire [23:0] command_address = {active_bank, active_row, sdram_address[8:0]};
    wire [23:0] memory_index = command_address;

    always_ff @(posedge clk) begin
        if (reset) begin
            active_row  <= 13'd0;
            active_bank <= 2'd0;
            read_data_d1 <= 16'h0000;
            read_data_d2 <= 16'h0000;
            sdram_reads <= 0;
            sdram_writes <= 0;
        end else begin
            if (command_active) begin
                active_row  <= sdram_address;
                active_bank <= sdram_ba;
            end
            if (command_read) begin
                read_data_d1 <= mem[memory_index];
                sdram_reads <= sdram_reads + 1;
            end
            read_data_d2 <= read_data_d1;
            if (command_write) begin
                if (!sdram_ldqm)
                    mem[memory_index][7:0] <= sdram_dq_out[7:0];
                if (!sdram_udqm)
                    mem[memory_index][15:8] <= sdram_dq_out[15:8];
                sdram_writes <= sdram_writes + 1;
            end
        end
    end

    assign sdram_dq_in = read_data_d2;

    spk286_at_mister_sdram_owner #(
        .SDRAM_NO_REFRESH(1'b1),
        .SDRAM_INIT_WAIT(16'd8)
    ) dut (
        .clk(clk), .reset(reset),
        .request_valid(request_valid),
        .request_command_valid(request_command_valid),
        .request_owner_refresh(request_owner_refresh),
        .request_write(request_write),
        .request_code_fetch(request_code_fetch),
        .request_burst(1'b0),
        .request_cycle_class(request_cycle_class),
        .request_address(request_address),
        .request_byte_enable(request_byte_enable),
        .request_data_out(request_data_out),
        .request_accept(request_accept),
        .request_ready(request_ready),
        .request_read_data(request_read_data),
        .request_read_data_valid(request_read_data_valid),
        .physical_idle(physical_idle), .debug_state(),
        .protocol_error(protocol_error),
        .sdram_address(sdram_address), .sdram_cke(sdram_cke),
        .sdram_cs(sdram_cs), .sdram_ras(sdram_ras),
        .sdram_cas(sdram_cas), .sdram_we(sdram_we),
        .sdram_ba(sdram_ba), .sdram_dq_in(sdram_dq_in),
        .sdram_dq_out(sdram_dq_out), .sdram_dq_io(sdram_dq_io),
        .sdram_ldqm(sdram_ldqm), .sdram_udqm(sdram_udqm)
    );

    task automatic check(input logic condition, input string message);
        begin
            if (!condition) begin
                $display("AT_MISTER_SDRAM_OWNER_FAIL %s", message);
                $fatal(1);
            end
        end
    endtask

    task automatic wait_for_idle;
        integer guard;
        begin
            guard = 0;
            while (!physical_idle && guard < 200) begin
                @(posedge clk);
                guard = guard + 1;
            end
            check(physical_idle, "KFSDRAM did not reach idle after initialization");
        end
    endtask

    task automatic write_word(input logic [24:0] address,
                              input logic [1:0] lanes,
                              input logic [15:0] data);
        integer guard;
        begin
            @(negedge clk);
            request_valid = 1'b1;
            request_command_valid = 1'b1;
            request_owner_refresh = 1'b0;
            request_write = 1'b1;
            request_address = address;
            request_byte_enable = lanes;
            request_data_out = data;
            guard = 0;
            while (!request_accept && guard < 200) begin
                @(negedge clk);
                guard = guard + 1;
            end
            check(request_accept, "write command was not accepted");
            @(posedge clk);
            #1;
            request_valid = 1'b0;
            request_command_valid = 1'b0;
            guard = 0;
            while (!request_ready && guard < 200) begin
                @(negedge clk);
                guard = guard + 1;
            end
            check(request_ready, "write did not complete");
            @(posedge clk);
            #1;
        end
    endtask

    task automatic read_word(input logic [24:0] address,
                             input logic [1:0] lanes,
                             input logic [15:0] expected);
        integer guard;
        begin
            @(negedge clk);
            request_valid = 1'b1;
            request_command_valid = 1'b1;
            request_owner_refresh = 1'b0;
            request_write = 1'b0;
            request_address = address;
            request_byte_enable = lanes;
            request_data_out = 16'h0000;
            guard = 0;
            while (!request_accept && guard < 200) begin
                @(negedge clk);
                guard = guard + 1;
            end
            check(request_accept, "read command was not accepted");
            @(posedge clk);
            #1;
            request_valid = 1'b0;
            request_command_valid = 1'b0;
            guard = 0;
            while (!request_ready && guard < 200) begin
                @(negedge clk);
                guard = guard + 1;
            end
            check(request_ready && request_read_data_valid &&
                  request_read_data == expected,
                  $sformatf("read address=%h expected=%h actual=%h ready=%b valid=%b",
                            address, expected, request_read_data,
                            request_ready, request_read_data_valid));
            @(posedge clk);
            #1;
        end
    endtask

    task automatic refresh_beat;
        integer guard;
        begin
            @(negedge clk);
            request_valid = 1'b1;
            request_command_valid = 1'b1;
            request_owner_refresh = 1'b1;
            request_write = 1'b0;
            request_address = 24'h000000;
            request_byte_enable = 2'b11;
            request_data_out = 16'h0000;
            guard = 0;
            while (!request_accept && guard < 200) begin
                @(negedge clk);
                guard = guard + 1;
            end
            check(request_accept, "refresh command was not accepted");
            @(posedge clk);
            #1;
            request_valid = 1'b0;
            request_command_valid = 1'b0;
            guard = 0;
            while (!request_ready && guard < 20) begin
                @(negedge clk);
                guard = guard + 1;
            end
            check(request_ready, "refresh ownership did not complete");
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        request_valid = 1'b0;
        request_command_valid = 1'b0;
        request_owner_refresh = 1'b0;
        request_write = 1'b0;
        request_code_fetch = 1'b0;
        request_cycle_class = 4'h0;
        request_address = 24'h000000;
        request_byte_enable = 2'b00;
        request_data_out = 16'h0000;
        for (i = 0; i < MEM_WORDS; i = i + 1)
            mem[i] = 16'h0000;

        repeat (3) @(posedge clk);
        reset = 1'b0;
        wait_for_idle();

        write_word(24'h001000, 2'b11, 16'hA55A);
        read_word(24'h001000, 2'b11, 16'hA55A);
        write_word(24'h001000, 2'b01, 16'h00CC);
        read_word(24'h001000, 2'b11, 16'hA5CC);
        write_word(24'h001001, 2'b10, 16'h7700);
        read_word(24'h001000, 2'b11, 16'h77CC);
        refresh_beat();

        check(sdram_writes >= 3, "physical write command was not issued");
        check(sdram_reads >= 3, "physical read command was not issued");
        check(!protocol_error, "unexpected SDRAM owner protocol error");

        // These are backend byte addresses: CPU DF0000h-DFFFFFh is
        // shifted by 2 MiB for EMS and must never overwrite the BIOS.
        write_word(25'h00F0000, 2'b11, 16'hB105);
        write_word(25'h00FFFFE, 2'b11, 16'hB10E);
        write_word(25'h0FEFFFE, 2'b11, 16'h1001);
        write_word(25'h0FF0000, 2'b11, 16'h2002);
        write_word(25'h0FFFFFF, 2'b10, 16'h3300);
        write_word(25'h0FFFFFE, 2'b01, 16'h0044);
        write_word(25'h1000000, 2'b11, 16'h5005);
        write_word(25'h11DFFFE, 2'b11, 16'h6006);
        read_word(25'h00F0000, 2'b11, 16'hB105);
        read_word(25'h00FFFFE, 2'b11, 16'hB10E);
        read_word(25'h0FEFFFE, 2'b11, 16'h1001);
        read_word(25'h0FF0000, 2'b11, 16'h2002);
        read_word(25'h0FFFFFE, 2'b11, 16'h3344);
        read_word(25'h1000000, 2'b11, 16'h5005);
        read_word(25'h11DFFFE, 2'b11, 16'h6006);
        $display("AT_MISTER_SDRAM_OWNER_PASS writes=%0d reads=%0d", sdram_writes, sdram_reads);
        $finish;
    end
endmodule
