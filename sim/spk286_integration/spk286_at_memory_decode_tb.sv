`timescale 1ns/1ps

module spk286_at_memory_decode_tb;
    logic request_valid = 1'b0;
    logic request_write = 1'b0;
    logic [3:0] cycle_class = 4'hF;
    logic [23:0] address = 24'd0;
    logic ems_enabled = 1'b1;
    logic ems_window_enabled [0:3];
    logic umb_enabled = 1'b1;
    logic [2:0] installed_ram_size = 3'd0;
    wire memory_cycle, conventional_ram_select, video_aperture_select;
    wire option_region_select, system_bios_select, extended_ram_select;
    wire ems_aperture_select;
    wire umb_region_select;
    wire write_allowed, rom_write_blocked, unmapped_request;
    wire word_capable;

    spk286_at_memory_decode dut (
        .request_valid(request_valid), .request_write(request_write),
        .cycle_class(cycle_class), .address(address),
        .ems_enabled(ems_enabled), .ems_window_enabled(ems_window_enabled),
        .umb_enabled(umb_enabled),
        .installed_ram_size(installed_ram_size),
        .memory_cycle(memory_cycle),
        .conventional_ram_select(conventional_ram_select),
        .video_aperture_select(video_aperture_select),
        .option_region_select(option_region_select),
        .system_bios_select(system_bios_select),
        .extended_ram_select(extended_ram_select),
        .ems_aperture_select(ems_aperture_select),
        .umb_region_select(umb_region_select),
        .word_capable(word_capable),
        .write_allowed(write_allowed),
        .rom_write_blocked(rom_write_blocked),
        .unmapped_request(unmapped_request)
    );

    task automatic check(input logic condition, input string message);
        if (!condition)
            $fatal(1, "CHECK_FAIL: %s", message);
    endtask

    task automatic classify(input logic [23:0] address_value,
                            input logic [3:0] class_value,
                            input logic write_value);
        begin
            address = address_value;
            cycle_class = class_value;
            request_write = write_value;
            request_valid = 1'b1;
            #1;
        end
    endtask

    initial begin
        ems_window_enabled[0] = 1'b0;
        ems_window_enabled[1] = 1'b0;
        ems_window_enabled[2] = 1'b0;
        ems_window_enabled[3] = 1'b0;
        classify(24'h000000, 4'h5, 1'b0);
        check(word_capable && conventional_ram_select && memory_cycle && !extended_ram_select,
              "conventional RAM base was not decoded");
        classify(24'h09FFFF, 4'h6, 1'b1);
        check(word_capable && conventional_ram_select && write_allowed && !rom_write_blocked,
              "conventional RAM limit/write was not decoded");
        classify(24'h0A0000, 4'h6, 1'b1);
        check(!word_capable && video_aperture_select && write_allowed,
              "video aperture start was not writable");
        classify(24'h0BFFFF, 4'h5, 1'b0);
        check(!word_capable && video_aperture_select && memory_cycle,
              "video aperture end was not decoded");
        classify(24'h0C0000, 4'h5, 1'b0);
        check(word_capable && option_region_select && !write_allowed,
              "option region start was not protected");
        classify(24'h0C7FFF, 4'h6, 1'b1);
        check(word_capable && option_region_select && rom_write_blocked,
              "EGA BIOS write protection was missing");
        classify(24'h0F0000, 4'hD, 1'b0);
        check(word_capable && system_bios_select && memory_cycle && !unmapped_request,
              "BIOS code fetch was not decoded");
        classify(24'h0FFFFF, 4'h6, 1'b1);
        check(word_capable && system_bios_select && rom_write_blocked && !write_allowed,
              "BIOS upper limit was writable");
        classify(24'hFFFFF0, 4'hD, 1'b0);
        check(word_capable && system_bios_select && memory_cycle && !extended_ram_select &&
              !unmapped_request,
              "reset-vector BIOS alias was not decoded");
        classify(24'hFFFFFF, 4'h6, 1'b1);
        check(word_capable && system_bios_select && rom_write_blocked && !write_allowed,
              "reset-vector BIOS alias was writable");
        classify(24'h100000, 4'h5, 1'b0);
        check(word_capable && extended_ram_select && memory_cycle,
              "extended RAM start lost the 24-bit boundary");
        classify(24'h15FFFF, 4'h6, 1'b1);
        check(word_capable && extended_ram_select && write_allowed,
              "default 4 MiB profile lost its first extended-RAM block");
        classify(24'h160000, 4'h5, 1'b0);
        check(word_capable && extended_ram_select && memory_cycle,
              "default 4 MiB profile did not expose memory above 1 MiB");
        classify(24'h45FFFF, 4'h6, 1'b1);
        check(word_capable && extended_ram_select && write_allowed,
              "default 4 MiB profile upper limit was not decoded");
        classify(24'h460000, 4'h5, 1'b0);
        check(!word_capable && !extended_ram_select && !memory_cycle && unmapped_request,
              "default 4 MiB profile exposed memory above its limit");
        classify(24'hFEFFFF, 4'h6, 1'b1);
        check(!word_capable && !extended_ram_select && !write_allowed && unmapped_request,
              "high unmapped memory was exposed as SDRAM");

        // The 8 MiB profile is OSD code 001.
        installed_ram_size = 3'd1;
        classify(24'h85FFFF, 4'h6, 1'b1);
        check(extended_ram_select && write_allowed,
              "8 MiB profile upper limit was not decoded");
        classify(24'h860000, 4'h5, 1'b0);
        check(!memory_cycle && unmapped_request,
              "8 MiB profile exposed memory above its limit");

        // The 16 MiB profile is OSD code 010.
        installed_ram_size = 3'd2;
        classify(24'hFDFFFF, 4'h6, 1'b1);
        check(extended_ram_select && write_allowed,
              "16 MiB profile upper limit was not decoded");
        classify(24'hFE0000, 4'h5, 1'b0);
        check(!memory_cycle && !extended_ram_select && unmapped_request,
              "16 MiB profile exposed the reserved FE0000h block");
        classify(24'hFEFFFF, 4'h5, 1'b0);
        check(!memory_cycle && !extended_ram_select && unmapped_request,
              "16 MiB profile exposed the reserved FEFFFFh boundary");
        classify(24'hFF0000, 4'hD, 1'b0);
        check(memory_cycle && system_bios_select && !extended_ram_select &&
              !unmapped_request,
              "64 KiB high BIOS alias did not start at FF0000h");

        // The remaining small profiles are still selectable after the default.
        installed_ram_size = 3'd3;
        classify(24'h15FFFF, 4'h6, 1'b1);
        check(extended_ram_select && write_allowed,
              "1 MiB profile upper limit was not decoded");
        classify(24'h160000, 4'h5, 1'b0);
        check(!memory_cycle && unmapped_request,
              "1 MiB profile exposed memory above its limit");

        installed_ram_size = 3'd4;
        classify(24'h25FFFF, 4'h6, 1'b1);
        check(extended_ram_select && write_allowed,
              "2 MiB profile upper limit was not decoded");
        classify(24'h260000, 4'h5, 1'b0);
        check(!memory_cycle && unmapped_request,
              "2 MiB profile exposed memory above its limit");
        installed_ram_size = 3'd0;

        ems_window_enabled[0] = 1'b1;
        classify(24'h0E0000, 4'h6, 1'b1);
        check(word_capable && ems_aperture_select && !option_region_select &&
              write_allowed && !rom_write_blocked,
              "EMS E000 window was not writable expanded memory");
        classify(24'h0E3FFF, 4'h5, 1'b0);
        check(memory_cycle && ems_aperture_select && !option_region_select,
              "EMS first 16 KiB window limit was not decoded");
        classify(24'h0E4000, 4'h6, 1'b1);
        check(!memory_cycle && !option_region_select && !ems_aperture_select &&
              !write_allowed && unmapped_request,
              "unmapped EMS window did not remain an unmapped page frame");

        classify(24'h0C4000, 4'h6, 1'b1);
        check(memory_cycle && option_region_select && !umb_region_select &&
              word_capable && !write_allowed && rom_write_blocked,
              "EGA BIOS window was incorrectly exposed as UMB");
        classify(24'h0C8000, 4'h5, 1'b0);
        check(memory_cycle && umb_region_select && !option_region_select &&
              word_capable && !write_allowed,
              "UMB did not begin at C8000h");
        classify(24'h0CFFFF, 4'h5, 1'b0);
        check(memory_cycle && umb_region_select && !option_region_select,
              "UMB C8000-CFFFF range was not decoded");
        classify(24'h0D0000, 4'h6, 1'b1);
        check(memory_cycle && umb_region_select && !option_region_select &&
              word_capable && write_allowed && !rom_write_blocked,
              "UMB D000 range was not writable RAM");
        classify(24'h0DFFFF, 4'h5, 1'b0);
        check(memory_cycle && umb_region_select && !option_region_select,
              "UMB upper limit DFFFFh was not decoded");
        classify(24'h0C0000, 4'h6, 1'b1);
        check(option_region_select && !umb_region_select &&
              !write_allowed && rom_write_blocked,
              "EGA BIOS C0000h was incorrectly exposed as UMB");

        classify(24'h0F0000, 4'h9, 1'b0);
        check(!word_capable && !memory_cycle && unmapped_request && !system_bios_select,
              "I/O request leaked into memory decode");
        request_valid = 1'b0;
        #1;
        check(!word_capable && !memory_cycle && !unmapped_request,
              "inactive request produced a decode");
        $display("A2_MEMORY_DECODE_PASS");
        $finish;
    end
endmodule
