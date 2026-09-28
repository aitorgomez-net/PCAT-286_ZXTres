`timescale 1ns/1ps

module spk286_at_rtc_cmos_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    logic request_valid = 1'b0;
    logic request_command_valid = 1'b0;
    logic request_write = 1'b0;
    logic request_io = 1'b1;
    logic [23:0] request_address = 24'h000070;
    logic [1:0] request_byte_enable = 2'b01;
    logic [15:0] request_data_out = 16'h0000;
    wire request_accept;
    wire request_ready;
    wire [15:0] request_read_data;
    wire request_read_data_valid;

    logic [15:0] mgmt_address = 16'h0000;
    logic [15:0] mgmt_writedata = 16'h0000;
    logic mgmt_write = 1'b0;
    wire [15:0] mgmt_readdata;
    logic periodic_tick = 1'b0;
    logic second_tick = 1'b0;
    logic [2:0] installed_ram_size = 3'd0;
    wire irq8;
    wire nmi_mask;
    wire [15:0] side_effect_count;
    wire [6:0] selected_index;
    wire protocol_error;
    logic [7:0] saved_cmos [0:47];
    integer cmos_test_index;

    spk286_at_rtc_cmos dut (
        .clk(clk), .reset(reset),
        .request_valid(request_valid),
        .request_command_valid(request_command_valid),
        .request_write(request_write), .request_io(request_io),
        .request_address(request_address),
        .installed_ram_size(installed_ram_size),
        .request_byte_enable(request_byte_enable),
        .request_data_out(request_data_out),
        .request_accept(request_accept), .request_ready(request_ready),
        .request_read_data(request_read_data),
        .request_read_data_valid(request_read_data_valid),
        .mgmt_address(mgmt_address), .mgmt_writedata(mgmt_writedata),
        .mgmt_write(mgmt_write),
        .mgmt_readdata(mgmt_readdata),
        .periodic_tick(periodic_tick), .second_tick(second_tick),
        .irq8(irq8), .nmi_mask(nmi_mask),
        .side_effect_count(side_effect_count),
        .selected_index(selected_index), .protocol_error(protocol_error)
    );

    task automatic check(input logic condition, input string message);
        if (!condition)
            $fatal(1, "CHECK_FAIL: %s", message);
    endtask

    task automatic io_write_byte(input logic [15:0] port,
                                 input logic [7:0] value);
        begin
            @(negedge clk);
            request_address = {8'h00, port};
            request_byte_enable = port[0] ? 2'b10 : 2'b01;
            request_data_out = port[0] ? {value, 8'h00} : {8'h00, value};
            request_write = 1'b1;
            request_valid = 1'b1;
            request_command_valid = 1'b1;
            #1;
            check(request_accept, "RTC write was not accepted");
            @(posedge clk);
            @(negedge clk);
            request_valid = 1'b0;
            request_command_valid = 1'b0;
            request_write = 1'b0;
            #1;
            check(request_ready, "RTC write did not complete");
            @(posedge clk);
        end
    endtask

    task automatic io_read_byte(input logic [15:0] port,
                                output logic [7:0] value);
        begin
            @(negedge clk);
            request_address = {8'h00, port};
            request_byte_enable = port[0] ? 2'b10 : 2'b01;
            request_write = 1'b0;
            request_valid = 1'b1;
            request_command_valid = 1'b1;
            #1;
            check(request_accept, "RTC read was not accepted");
            @(posedge clk);
            @(negedge clk);
            request_valid = 1'b0;
            request_command_valid = 1'b0;
            #1;
            check(request_ready && request_read_data_valid,
                  "RTC read did not return valid data");
            value = port[0] ? request_read_data[15:8] :
                              request_read_data[7:0];
            @(posedge clk);
        end
    endtask

    task automatic cmos_write(input logic [6:0] index,
                              input logic [7:0] value);
        begin
            io_write_byte(16'h0070, {1'b0, index});
            io_write_byte(16'h0071, value);
        end
    endtask

    task automatic cmos_read(input logic [6:0] index,
                             output logic [7:0] value);
        begin
            io_write_byte(16'h0070, {1'b0, index});
            io_read_byte(16'h0071, value);
        end
    endtask

    task automatic mgmt_write_byte(input logic [15:0] address,
                                   input logic [7:0] value);
        begin
            @(negedge clk);
            mgmt_address = address;
            mgmt_writedata = {8'h00, value};
            mgmt_write = 1'b1;
            @(posedge clk);
            @(negedge clk);
            mgmt_write = 1'b0;
        end
    endtask

    task automatic pulse_second;
        begin
            @(negedge clk);
            second_tick = 1'b1;
            @(posedge clk);
            @(negedge clk);
            second_tick = 1'b0;
        end
    endtask

    task automatic check_cmos(input logic [6:0] index,
                              input logic [7:0] expected,
                              input string message);
        logic [7:0] value;
        begin
            cmos_read(index, value);
            check(value == expected, message);
        end
    endtask

    task automatic check_ram_profile(input logic [2:0] profile,
                                     input logic [15:0] extended_kib,
                                     input logic [15:0] expected_checksum);
        begin
            installed_ram_size = profile;
            repeat (2) @(negedge clk);
            check_cmos(7'h17, extended_kib[7:0],
                       "profile extended-memory low byte was wrong");
            check_cmos(7'h18, extended_kib[15:8],
                       "profile extended-memory high byte was wrong");
            check_cmos(7'h30, extended_kib[7:0],
                       "profile duplicate extended-memory low byte was wrong");
            check_cmos(7'h31, extended_kib[15:8],
                       "profile duplicate extended-memory high byte was wrong");
            check_cmos(7'h2E, expected_checksum[15:8],
                       "profile checksum high byte was wrong");
            check_cmos(7'h2F, expected_checksum[7:0],
                       "profile checksum low byte was wrong");
        end
    endtask

    // MRBIOS 1.65 F000:E9EC checks these fields independently of the AT
    // checksum. The low five bits of CMOS 3Fh hold the sum plus 1Fh.
    task automatic read_mrbios_checksum(output logic [4:0] sum);
        logic [7:0] value;
        integer address;
        begin
            sum = 5'h1F;
            for (address = 'h10; address < 'h3F; address = address + 1) begin
                if ((address == 'h11) || (address == 'h13) ||
                    ((address >= 'h1B) && (address <= 'h2D)) ||
                    ((address >= 'h33) && (address <= 'h3E))) begin
                    cmos_read(address[6:0], value);
                    sum = sum + value[4:0];
                end
            end
        end
    endtask

    task automatic check_mrbios_date_sequence;
        logic [7:0] original_century, original_37, original_3f;
        logic [7:0] snapshot [0:47];
        logic [7:0] century, stored;
        logic [4:0] sum;
        integer cycle, address;
        begin
            cmos_read(7'h32, original_century);
            cmos_read(7'h37, original_37);
            cmos_read(7'h3F, original_3f);
            cmos_write(7'h32, 8'h00);
            cmos_write(7'h37, 8'h00);
            read_mrbios_checksum(sum);
            cmos_write(7'h3F, {3'b101, sum});

            // FreeDOS initializes the DOS clock and calls INT 1Ah/AH=05.
            // MRBIOS's date setter writes the century at 32h. Its private
            // checksum includes 37h but deliberately excludes century 32h.
            for (cycle = 0; cycle < 4; cycle = cycle + 1) begin
                century = cycle[0] ? 8'h20 : 8'h19;
                cmos_write(7'h08, 8'h01);
                cmos_write(7'h09, 8'h80);
                cmos_write(7'h32, century);
                cmos_write(7'h07, 8'h01);
                cmos_write(7'h0B, 8'h02);
                read_mrbios_checksum(sum);
                cmos_read(7'h3F, stored);
                check(stored[4:0] == sum,
                      "MRBIOS secondary checksum changed after setting the date");
                check_cmos(7'h37, 8'h00,
                           "CPU century write changed independent CMOS 37h");

                // Capture through the side-effect-free HPS readback path,
                // then restore in ascending order as Main does on reset.
                for (address = 'h10; address <= 'h3F; address = address + 1) begin
                    @(negedge clk);
                    mgmt_address = 16'hF400 + address[15:0];
                    #1;
                    snapshot[address - 'h10] = mgmt_readdata[7:0];
                end
                check(snapshot['h27] == 8'h00,
                      "CMOS snapshot substituted century for register 37h");
                @(negedge clk);
                reset = 1'b1;
                for (address = 'h10; address <= 'h3F; address = address + 1)
                    mgmt_write_byte(16'hF400 + address[15:0],
                                    snapshot[address - 'h10]);
                reset = 1'b0;
                repeat (2) @(negedge clk);
                check_cmos(7'h32, century,
                           "host restore of CMOS 37h overwrote century 32h");
                read_mrbios_checksum(sum);
                cmos_read(7'h3F, stored);
                check(stored[4:0] == sum,
                      "MRBIOS secondary checksum changed across host reset");
            end

            cmos_write(7'h37, 8'h5A);
            check_cmos(7'h32, century,
                       "CPU write to CMOS 37h overwrote century 32h");
            cmos_write(7'h32, original_century);
            cmos_write(7'h37, original_37);
            cmos_write(7'h3F, original_3f);
            $display("AT_RTC_MRBIOS_DATE_PASS resets=4 independent_32_37=1");
        end
    endtask

    initial begin
        logic [7:0] value;

        repeat (4) @(negedge clk);
        // x86_init holds status[0] high while uploading F4xx. Both initial
        // loading and later OSD resets must preserve the battery-backed CMOS.
        mgmt_write_byte(16'hF410, 8'h44);
        mgmt_write_byte(16'hF414, 8'h4D);
        mgmt_write_byte(16'hF400, 8'h56);
        mgmt_write_byte(16'hF40F, 8'h0A);
        mgmt_write_byte(16'hF47F, 8'h5A);
        mgmt_write_byte(16'hF418, 8'h3C); // Host RAM size is not our RAM size.
        mgmt_write_byte(16'hF42E, 8'hFF); // Host checksum must not override ours.
        mgmt_write_byte(16'hF42F, 8'hFF);
        mgmt_write_byte(16'hF490, 8'h00); // Outside the 128-byte CMOS window.
        repeat (8) @(negedge clk);
        // A stray CPU write to the reset-selected seconds register must not
        // reach retained RAM while the host is allowed to initialize it.
        request_address = 24'h000071;
        request_byte_enable = 2'b10;
        request_data_out = 16'h9900;
        request_valid = 1'b1;
        request_command_valid = 1'b1;
        request_write = 1'b1;
        #1;
        check(!request_accept, "RTC accepted CPU I/O during reset");
        repeat (2) @(negedge clk);
        request_valid = 1'b0;
        request_command_valid = 1'b0;
        request_write = 1'b0;
        reset = 1'b0;
        repeat (2) @(negedge clk);
        check_cmos(7'h10, 8'h44, "host floppy types were lost during reset");
        check_cmos(7'h14, 8'h4D, "host equipment byte was lost during reset");
        check_cmos(7'h00, 8'h56, "host seconds were lost during reset");
        check_cmos(7'h0F, 8'h0A, "host shutdown byte was lost during reset");
        check_cmos(7'h7F, 8'h5A, "last host CMOS byte was lost during reset");
        check_cmos(7'h18, 8'h0D, "host reset upload replaced fixed RAM size");
        check_cmos(7'h2E, 8'h01, "reset upload checksum high byte was wrong");
        check_cmos(7'h2F, 8'hA0, "reset upload checksum low byte was wrong");

        check_mrbios_date_sequence();

        cmos_write(7'h10, 8'h24);
        // Even a BIOS-supplied checksum is RAM, not resettable device state.
        cmos_write(7'h2E, 8'hBE);
        cmos_write(7'h2F, 8'hEF);
        @(negedge clk);
        reset = 1'b1;
        repeat (8) @(negedge clk);
        reset = 1'b0;
        repeat (2) @(negedge clk);
        check_cmos(7'h10, 8'h24, "warm reset erased BIOS floppy configuration");
        check_cmos(7'h00, 8'h56, "warm reset erased RTC time");
        check_cmos(7'h0F, 8'h0A, "warm reset erased BIOS shutdown code");
        check_cmos(7'h7F, 8'h5A, "warm reset erased CMOS RAM");
        check_cmos(7'h2E, 8'hBE, "warm reset erased BIOS checksum high byte");
        check_cmos(7'h2F, 8'hEF, "warm reset erased BIOS checksum low byte");

        // A subsequent host upload during an OSD reset is also effective.
        @(negedge clk);
        reset = 1'b1;
        mgmt_write_byte(16'hF410, 8'h34);
        repeat (8) @(negedge clk);
        reset = 1'b0;
        repeat (2) @(negedge clk);
        check_cmos(7'h10, 8'h34, "second host upload during reset was lost");
        check_cmos(7'h2E, 8'hBE, "second upload checksum high byte was wrong");
        check_cmos(7'h2F, 8'hFF, "second upload checksum low byte was wrong");

        // Restore the initial configuration for the existing calendar/RAM tests.
        cmos_write(7'h10, 8'h00);
        cmos_write(7'h14, 8'h00);
        cmos_write(7'h0F, 8'h00);
        cmos_write(7'h2E, 8'h01);
        cmos_write(7'h2F, 8'h0F);

        // The default CMOS description and actual decode agree on a 4 MiB AT:
        // 640 KiB conventional plus 3456 KiB above 1 MiB.
        check_cmos(7'h15, 8'h80, "base-memory low byte was not 640 KiB");
        check_cmos(7'h16, 8'h02, "base-memory high byte was not 640 KiB");
        check_cmos(7'h17, 8'h80, "extended-memory low byte was not 3456 KiB");
        check_cmos(7'h18, 8'h0D, "extended-memory high byte was not 3456 KiB");
        check_cmos(7'h30, 8'h80, "duplicate extended-memory low byte differed");
        check_cmos(7'h31, 8'h0D, "duplicate extended-memory high byte differed");
        check_cmos(7'h34, 8'h00, "memory above 16 MiB was advertised");
        check_cmos(7'h35, 8'h00, "memory above 16 MiB was advertised");
        check_cmos(7'h2E, 8'h01, "initial CMOS checksum high byte was wrong");
        check_cmos(7'h2F, 8'h0F, "initial CMOS checksum low byte was wrong");

        // Exercise every OSD profile explicitly. The 16 MiB selection must
        // advertise 15232 KiB (3B80h), an integral 238 blocks of 64 KiB.
        check_ram_profile(3'd0, 16'd3456, 16'h010F);
        check_ram_profile(3'd1, 16'd7552, 16'h011F);
        check_ram_profile(3'd2, 16'd15232, 16'h013D);
        check_ram_profile(3'd3, 16'd384, 16'h0103);
        check_ram_profile(3'd4, 16'd1408, 16'h0107);
        // The remaining RAM/checksum fixtures use the 1 MiB profile.
        check_ram_profile(3'd3, 16'd384, 16'h0103);

        // Exact Landmark CMOS RAM algorithm (F000:A26C): save 10h-3Fh,
        // write/read 55h, write/read AAh, then restore all 48 bytes. This
        // includes the memory geometry and checksum bytes 2Eh/2Fh.
        for (cmos_test_index = 0; cmos_test_index < 48;
             cmos_test_index = cmos_test_index + 1)
            cmos_read(7'h10 + cmos_test_index[6:0],
                      saved_cmos[cmos_test_index]);
        for (cmos_test_index = 0; cmos_test_index < 48;
             cmos_test_index = cmos_test_index + 1)
            cmos_write(7'h10 + cmos_test_index[6:0], 8'h55);
        for (cmos_test_index = 0; cmos_test_index < 48;
             cmos_test_index = cmos_test_index + 1)
            check_cmos(7'h10 + cmos_test_index[6:0], 8'h55,
                       "Landmark 55h CMOS pattern did not read back");
        for (cmos_test_index = 0; cmos_test_index < 48;
             cmos_test_index = cmos_test_index + 1)
            cmos_write(7'h10 + cmos_test_index[6:0], 8'hAA);
        for (cmos_test_index = 0; cmos_test_index < 48;
             cmos_test_index = cmos_test_index + 1)
            check_cmos(7'h10 + cmos_test_index[6:0], 8'hAA,
                       "Landmark AAh CMOS pattern did not read back");
        for (cmos_test_index = 0; cmos_test_index < 48;
             cmos_test_index = cmos_test_index + 1)
            cmos_write(7'h10 + cmos_test_index[6:0],
                       saved_cmos[cmos_test_index]);
        check_cmos(7'h2E, 8'h01, "restored CMOS checksum high byte was wrong");
        check_cmos(7'h2F, 8'h03, "restored CMOS checksum low byte was wrong");

        // F4xx is the hps_ext RTC window used by ao486/z486. Values written
        // there must be the values visible through ports 70h/71h.
        mgmt_write_byte(16'hF400, 8'h59);
        mgmt_write_byte(16'hF402, 8'h59);
        mgmt_write_byte(16'hF404, 8'h23);
        mgmt_write_byte(16'hF406, 8'h03);
        mgmt_write_byte(16'hF407, 8'h31);
        mgmt_write_byte(16'hF408, 8'h12);
        mgmt_write_byte(16'hF409, 8'h24);
        mgmt_write_byte(16'hF432, 8'h20);
        check_cmos(7'h00, 8'h59, "MiSTer seconds did not reach CMOS");
        check_cmos(7'h04, 8'h23, "MiSTer hour did not reach CMOS");
        check_cmos(7'h32, 8'h20, "MiSTer century did not reach CMOS");

        pulse_second();
        check_cmos(7'h00, 8'h00, "seconds did not roll over");
        check_cmos(7'h02, 8'h00, "minutes did not roll over");
        check_cmos(7'h04, 8'h00, "hours did not roll over");
        check_cmos(7'h06, 8'h04, "day of week did not advance");
        check_cmos(7'h07, 8'h01, "day of month did not roll over");
        check_cmos(7'h08, 8'h01, "month did not roll over");
        check_cmos(7'h09, 8'h25, "year did not roll over");

        // Gregorian leap day and month transition.
        mgmt_write_byte(16'hF400, 8'h59);
        mgmt_write_byte(16'hF402, 8'h59);
        mgmt_write_byte(16'hF404, 8'h23);
        mgmt_write_byte(16'hF406, 8'h04);
        mgmt_write_byte(16'hF407, 8'h28);
        mgmt_write_byte(16'hF408, 8'h02);
        mgmt_write_byte(16'hF409, 8'h24);
        pulse_second();
        check_cmos(7'h07, 8'h29, "2024 leap day was skipped");
        check_cmos(7'h08, 8'h02, "leap day changed month early");
        mgmt_write_byte(16'hF400, 8'h59);
        mgmt_write_byte(16'hF402, 8'h59);
        mgmt_write_byte(16'hF404, 8'h23);
        pulse_second();
        check_cmos(7'h07, 8'h01, "leap day did not roll to day one");
        check_cmos(7'h08, 8'h03, "leap day did not roll to March");

        // Century rollover and the Gregorian exception for 2100.
        mgmt_write_byte(16'hF400, 8'h59);
        mgmt_write_byte(16'hF402, 8'h59);
        mgmt_write_byte(16'hF404, 8'h23);
        mgmt_write_byte(16'hF407, 8'h31);
        mgmt_write_byte(16'hF408, 8'h12);
        mgmt_write_byte(16'hF409, 8'h99);
        mgmt_write_byte(16'hF432, 8'h20);
        pulse_second();
        check_cmos(7'h09, 8'h00, "year 2099 did not roll to 00");
        check_cmos(7'h32, 8'h21, "century did not roll from 20 to 21");
        check_cmos(7'h37, 8'h00, "calendar rollover changed CMOS 37h");
        mgmt_write_byte(16'hF400, 8'h59);
        mgmt_write_byte(16'hF402, 8'h59);
        mgmt_write_byte(16'hF404, 8'h23);
        mgmt_write_byte(16'hF407, 8'h28);
        mgmt_write_byte(16'hF408, 8'h02);
        pulse_second();
        check_cmos(7'h07, 8'h01, "2100 was incorrectly treated as leap year");
        check_cmos(7'h08, 8'h03, "2100 February did not roll to March");

        // SET freezes calendar updates. Alarm and update-ended interrupts use
        // the MC146818 status-C bits and clear together when C is read.
        cmos_write(7'h0B, 8'h82);
        mgmt_write_byte(16'hF400, 8'h10);
        pulse_second();
        check_cmos(7'h00, 8'h10, "SET did not freeze RTC updates");
        cmos_write(7'h0B, 8'h32);
        mgmt_write_byte(16'hF401, 8'h11);
        mgmt_write_byte(16'hF403, 8'h00);
        mgmt_write_byte(16'hF405, 8'h00);
        mgmt_write_byte(16'hF402, 8'h00);
        mgmt_write_byte(16'hF404, 8'h00);
        pulse_second();
        check(irq8, "alarm/update interrupt did not assert IRQ8");
        cmos_read(7'h0C, value);
        check(value[7] && value[5] && value[4],
              "status C did not report IRQF/AF/UF");
        check(!irq8, "status-C read did not clear IRQ8");

        // Memory geometry is hardware-owned. HPS/BIOS attempts to replace it
        // cannot make CMOS advertise RAM the decoder does not expose.
        mgmt_write_byte(16'hF415, 8'h00);
        mgmt_write_byte(16'hF416, 8'h00);
        mgmt_write_byte(16'hF417, 8'h00);
        mgmt_write_byte(16'hF418, 8'h00);
        check_cmos(7'h15, 8'h80, "HPS replaced fixed base-memory size");
        check_cmos(7'h17, 8'h80, "HPS replaced fixed extended-memory size");

        // Checksum follows writable configuration bytes while the fixed RAM
        // fields remain included.
        cmos_write(7'h14, 8'h01);
        check_cmos(7'h2E, 8'h01, "updated CMOS checksum high byte was wrong");
        check_cmos(7'h2F, 8'h04, "updated CMOS checksum low byte was wrong");
        check_cmos(7'h0D, 8'h80, "RTC valid-RAM status was not set");
        check(!protocol_error, "RTC reported a protocol error");

        $display("AT_RTC_CMOS_PASS host_reset_upload=1 warm_retention=1 host_time=1 calendar=1 irq=1 memory_kib=1024 checksum=0104");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "AT RTC/CMOS watchdog expired");
    end
endmodule
