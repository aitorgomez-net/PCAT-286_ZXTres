`timescale 1ns/1ps
module spk286_at_rtc_periodic_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    logic valid = 1'b0, wr = 1'b0;
    logic [23:0] address = 24'h70;
    logic [1:0] lanes = 2'b01;
    logic [15:0] data_out = 16'h0000;
    wire accept, ready, read_valid;
    wire [15:0] data_in;
    logic [15:0] mgmt_address = 16'hF40C;
    logic [15:0] mgmt_data = 16'h0000;
    logic mgmt_write = 1'b0;
    wire [15:0] mgmt_read;
    logic base_tick = 1'b0, second_tick = 1'b0;
    wire irq8, fault;

    spk286_at_rtc_cmos dut (
        .clk(clk), .reset(reset), .request_valid(valid),
        .request_command_valid(valid), .request_write(wr), .request_io(1'b1),
        .request_address(address), .installed_ram_size(3'd0),
        .request_byte_enable(lanes), .request_data_out(data_out),
        .request_accept(accept), .request_ready(ready),
        .request_read_data(data_in), .request_read_data_valid(read_valid),
        .mgmt_address(mgmt_address), .mgmt_writedata(mgmt_data),
        .mgmt_write(mgmt_write), .mgmt_readdata(mgmt_read),
        .periodic_tick(base_tick), .second_tick(second_tick),
        .irq8(irq8), .nmi_mask(), .side_effect_count(), .selected_index(),
        .protocol_error(fault)
    );

    task automatic check(input logic condition, input string message);
        if (!condition) $fatal(1, "RTC_PERIODIC_FAIL: %s", message);
    endtask

    task automatic write_port(input logic data_port, input logic [7:0] value);
        @(negedge clk);
        address = data_port ? 24'h71 : 24'h70;
        lanes = data_port ? 2'b10 : 2'b01;
        data_out = data_port ? {value,8'h00} : {8'h00,value};
        wr = 1'b1; valid = 1'b1;
        #1; check(accept, "write not accepted");
        @(negedge clk);
        valid = 1'b0; wr = 1'b0;
        #1; check(ready, "write did not complete");
        @(posedge clk);
    endtask

    task automatic write_cmos(input logic [6:0] index, input logic [7:0] value);
        write_port(1'b0, {1'b0,index});
        write_port(1'b1, value);
    endtask

    task automatic read_data(output logic [7:0] value);
        @(negedge clk);
        address = 24'h71; lanes = 2'b10; wr = 1'b0; valid = 1'b1;
        #1; check(accept, "read not accepted");
        @(negedge clk);
        valid = 1'b0;
        #1; check(ready && read_valid, "read did not complete");
        value = data_in[15:8];
        @(posedge clk);
    endtask

    task automatic read_cmos(input logic [6:0] index, output logic [7:0] value);
        write_port(1'b0, {1'b0,index});
        read_data(value);
    endtask

    // Accelerate only the external clock enables; each represents one
    // 32768 Hz reference period. The real 50 MHz generator has its own test.
    task automatic ticks(input integer count);
        repeat (count) begin
            @(negedge clk); base_tick = 1'b1;
            @(negedge clk); base_tick = 1'b0;
        end
    endtask

    task automatic second_pulse;
        @(negedge clk); second_tick = 1'b1;
        @(negedge clk); second_tick = 1'b0;
    endtask

    initial begin
        logic [7:0] value;
        integer divisor;
        repeat (4) @(negedge clk);
        reset = 1'b0;
        write_cmos(7'h0B, 8'h42);

        // Datasheet table: RS=0 off, RS=1/2 aliases, RS=3..15 powers of two.
        for (integer rate = 0; rate < 16; rate = rate + 1) begin
            write_cmos(7'h0A, 8'h20 | 8'(rate));
            read_cmos(7'h0C, value);
            if (rate == 0) begin
                ticks(32768);
                read_cmos(7'h0C, value);
                check(value == 8'h00 && !irq8, "RS=0 generated a periodic event");
            end else begin
                if (rate == 1) divisor = 128;
                else if (rate == 2) divisor = 256;
                else divisor = 1 << (rate - 1);
                repeat (2) begin
                    ticks(divisor - 1);
                    check(!irq8, $sformatf("RS=%0d fired early", rate));
                    ticks(1);
                    check(irq8, $sformatf("RS=%0d missed boundary", rate));
                    read_cmos(7'h0C, value);
                    check(value == 8'hC0 && !irq8, "PF/IRQF read or acknowledgement");
                end
            end
        end

        // OS/2 programs A=2B/B=52: exactly 32 PF events per 32768 enables.
        write_cmos(7'h0A, 8'h2B);
        write_cmos(7'h0B, 8'h52);
        write_cmos(7'h00, 8'h00);
        for (integer event_no = 1; event_no <= 32; event_no = event_no + 1) begin
            ticks(1023);
            check(!irq8, "OS/2 IRQ8 before 31.25 ms");
            @(negedge clk);
            base_tick = 1'b1;
            second_tick = (event_no == 32);
            @(negedge clk);
            base_tick = 1'b0; second_tick = 1'b0;
            check(irq8, "OS/2 missing 32 Hz event");
            read_cmos(7'h0C, value);
            check(value == ((event_no == 32) ? 8'hD0 : 8'hC0),
                  "OS/2 status C or independent one-second update");
            check(!irq8, "OS/2 status C did not release IRQ8");
        end
        read_cmos(7'h00, value);
        check(value == 8'h01, "32 periodic events did not span one calendar second");

        // PF must latch with PIE=0. Management reads must not acknowledge it.
        write_cmos(7'h0A, 8'h26);
        write_cmos(7'h0B, 8'h02);
        ticks(32);
        check(!irq8 && mgmt_read[7:0] == 8'h40, "PF must latch while PIE is masked");
        repeat (3) @(negedge clk);
        check(mgmt_read[7:0] == 8'h40, "HPS read cleared periodic flag");
        write_cmos(7'h0B, 8'h42);
        check(irq8, "enabling PIE did not assert pending PF");
        write_cmos(7'h0B, 8'h02);
        check(!irq8 && mgmt_read[6], "masking PIE failed or discarded PF");
        read_cmos(7'h0C, value);
        check(value == 8'h40 && !mgmt_read[6], "masked PF read/clear failed");

        // SET freezes the calendar, not the periodic divider.
        write_cmos(7'h0B, 8'hC2);
        ticks(32);
        second_pulse();
        read_cmos(7'h00, value);
        check(value == 8'h01, "SET did not freeze calendar");
        read_cmos(7'h0C, value);
        check(value == 8'hC0 && !irq8, "SET incorrectly inhibited PF");

        // A rewrite restarts the programmed period; exercise both CPU and HPS.
        write_cmos(7'h0B, 8'h42);
        ticks(16);
        write_cmos(7'h0A, 8'h2B);
        ticks(1023);
        check(!irq8, "rate change inherited the old partial period");
        ticks(1);
        read_cmos(7'h0C, value);
        check(value == 8'hC0, "changed rate did not fire");
        @(negedge clk);
        mgmt_address = 16'hF40A; mgmt_data = 16'h0026; mgmt_write = 1'b1;
        @(negedge clk);
        mgmt_write = 1'b0; mgmt_address = 16'hF40C;
        ticks(31); check(!irq8, "HPS rate write fired early");
        ticks(1); read_cmos(7'h0C, value);
        check(value == 8'hC0, "HPS rate write was ignored");

        // RS=0 leaves the second update running. DV=11x stops both and resets
        // the partial periodic count; returning to DV=010 starts a full period.
        write_cmos(7'h0A, 8'h20);
        second_pulse();
        read_cmos(7'h00, value);
        check(value == 8'h02, "RS=0 stopped calendar");
        read_cmos(7'h0C, value);
        check(value == 8'h10, "RS=0 update flag incorrect");
        for (integer dv = 0; dv < 8; dv = dv + 1) begin
            if (dv != 2) begin
                write_cmos(7'h0A, (8'(dv) << 4) | 8'h06);
                ticks(64); second_pulse();
                read_cmos(7'h0C, value);
                check(value == 8'h00 && !irq8, "inactive DV mode generated events");
                read_cmos(7'h00, value);
                check(value == 8'h02, "inactive DV mode advanced calendar");
            end
        end
        write_cmos(7'h0A, 8'h26);
        ticks(31); check(!irq8, "divider reset did not clear partial count");
        ticks(1); read_cmos(7'h0C, value);
        check(value == 8'hC0, "divider restart failed");

        // A new PF on the exact status-C read edge must remain pending.
        ticks(31);
        write_port(1'b0, 8'h0C);
        @(negedge clk);
        address = 24'h71; lanes = 2'b10; valid = 1'b1; base_tick = 1'b1;
        @(negedge clk);
        valid = 1'b0; base_tick = 1'b0;
        #1;
        check(data_in[15:8] == 8'h00 && irq8, "read/event collision lost the new PF");
        read_cmos(7'h0C, value);
        check(value == 8'hC0 && !irq8, "pending collision event did not clear");

        ticks(16);
        @(negedge clk); reset = 1'b1;
        repeat (3) @(negedge clk);
        reset = 1'b0;
        ticks(31); check(!irq8, "machine reset kept partial divider count");
        ticks(1); read_cmos(7'h0C, value);
        check(value == 8'hC0 && !fault, "reset/restart or protocol error");
        $display("AT_RTC_PERIODIC_PASS rates=16 os2_hz=32 pf_pie=1 rate_changes=1 dv_reset=1 read_collision=1");
        $finish;
    end

    initial begin
        #10000000;
        $fatal(1, "RTC periodic watchdog expired");
    end
endmodule
