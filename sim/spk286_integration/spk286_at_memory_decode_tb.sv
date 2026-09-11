`timescale 1ns/1ps

module spk286_at_memory_decode_tb;
    logic request_valid = 1'b0;
    logic request_write = 1'b0;
    logic [3:0] cycle_class = 4'hF;
    logic [23:0] address = 24'd0;
    wire memory_cycle, conventional_ram_select, video_aperture_select;
    wire option_region_select, system_bios_select, extended_ram_select;
    wire write_allowed, rom_write_blocked, unmapped_request;

    spk286_at_memory_decode dut (
        .request_valid(request_valid), .request_write(request_write),
        .cycle_class(cycle_class), .address(address),
        .memory_cycle(memory_cycle),
        .conventional_ram_select(conventional_ram_select),
        .video_aperture_select(video_aperture_select),
        .option_region_select(option_region_select),
        .system_bios_select(system_bios_select),
        .extended_ram_select(extended_ram_select),
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
        classify(24'h000000, 4'h5, 1'b0);
        check(conventional_ram_select && memory_cycle && !extended_ram_select,
              "conventional RAM base was not decoded");
        classify(24'h09FFFF, 4'h6, 1'b1);
        check(conventional_ram_select && write_allowed && !rom_write_blocked,
              "conventional RAM limit/write was not decoded");
        classify(24'h0A0000, 4'h6, 1'b1);
        check(video_aperture_select && write_allowed,
              "video aperture start was not writable");
        classify(24'h0BFFFF, 4'h5, 1'b0);
        check(video_aperture_select && memory_cycle,
              "video aperture end was not decoded");
        classify(24'h0C0000, 4'h5, 1'b0);
        check(option_region_select && !write_allowed,
              "option region start was not protected");
        classify(24'h0EFFFF, 4'h6, 1'b1);
        check(option_region_select && rom_write_blocked,
              "option region write protection was missing");
        classify(24'h0F0000, 4'hD, 1'b0);
        check(system_bios_select && memory_cycle && !unmapped_request,
              "BIOS code fetch was not decoded");
        classify(24'h0FFFFF, 4'h6, 1'b1);
        check(system_bios_select && rom_write_blocked && !write_allowed,
              "BIOS upper limit was writable");
        classify(24'h100000, 4'h5, 1'b0);
        check(extended_ram_select && memory_cycle,
              "extended RAM start lost the 24-bit boundary");
        classify(24'hFFFFFF, 4'h6, 1'b1);
        check(extended_ram_select && write_allowed,
              "extended RAM upper limit was not decoded");

        classify(24'h0F0000, 4'h9, 1'b0);
        check(!memory_cycle && unmapped_request && !system_bios_select,
              "I/O request leaked into memory decode");
        request_valid = 1'b0;
        #1;
        check(!memory_cycle && !unmapped_request,
              "inactive request produced a decode");
        $display("A2_MEMORY_DECODE_PASS");
        $finish;
    end
endmodule
