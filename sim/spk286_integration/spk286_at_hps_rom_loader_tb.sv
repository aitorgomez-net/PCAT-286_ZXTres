`timescale 1ns/1ps

module spk286_at_hps_rom_loader_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    logic        sdram_initialized;
    logic        ioctl_download;
    logic [7:0]  ioctl_index;
    logic        ioctl_wr;
    logic [24:0] ioctl_addr;
    logic [15:0] ioctl_data;
    wire         ioctl_wait;
    wire         loader_valid;
    wire         loader_write;
    wire [23:0]  loader_address;
    wire [1:0]   loader_byte_enable;
    wire [15:0]  loader_data_out;
    logic        loader_accept;
    logic        loader_ready;
    wire [2:0]   bios_protect_flag;
    wire         main_rom_loaded;
    wire         ega_rom_loaded;
    wire         xtide_rom_loaded;
    wire         load_active;
    wire         protocol_error;

    spk286_at_hps_rom_loader dut (
        .clk(clk), .reset(reset), .sdram_initialized(sdram_initialized),
        .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
        .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_data(ioctl_data),
        .ioctl_wait(ioctl_wait), .loader_valid(loader_valid),
        .loader_write(loader_write), .loader_address(loader_address),
        .loader_byte_enable(loader_byte_enable),
        .loader_data_out(loader_data_out),
        .loader_accept(loader_accept), .loader_ready(loader_ready),
        .bios_protect_flag(bios_protect_flag),
        .main_rom_loaded(main_rom_loaded), .ega_rom_loaded(ega_rom_loaded),
        .xtide_rom_loaded(xtide_rom_loaded), .load_active(load_active),
        .protocol_error(protocol_error)
    );

    integer failures = 0;
    task automatic check(input logic condition, input string message);
        begin
            if (!condition) begin
                $display("AT_HPS_ROM_LOADER_FAIL %s", message);
                failures = failures + 1;
            end
        end
    endtask

    task automatic complete_word(input logic [7:0] index,
                                 input logic [24:0] address,
                                 input logic [15:0] data);
        begin
            ioctl_index = index;
            ioctl_addr = address;
            ioctl_data = data;
            ioctl_wr = 1'b1;
            @(posedge clk);
            #1;
            check(loader_valid && load_active && ioctl_wait,
                  "loader did not retain the incoming word");
            loader_accept = 1'b1;
            @(posedge clk);
            #1;
            loader_accept = 1'b0;
            check(loader_valid && ioctl_wait,
                  "loader dropped the word after acceptance");
            check(loader_address == ((index[5:0] == 0) ?
                                     24'h0F0000 + {8'h00, address[15:0]} :
                                     ((index == 8'd2) ? 24'h0EC000 : 24'h0C0000) + {8'h00, address[15:0]}),
                  "loader mapped the ROM address incorrectly");
            check(loader_data_out == data && loader_write &&
                  loader_byte_enable == 2'b11,
                  "loader changed data or byte lanes while waiting");
            loader_ready = 1'b1;
            @(posedge clk);
            #1;
            loader_ready = 1'b0;
            check(!load_active && !loader_valid,
                  "loader did not return to idle after completion");
        end
    endtask

    function automatic logic target_loaded(input logic [7:0] index);
        case (index)
            8'd0: target_loaded = main_rom_loaded;
            8'd3: target_loaded = ega_rom_loaded;
            8'd2: target_loaded = xtide_rom_loaded;
            default: target_loaded = 1'b0;
        endcase
    endfunction

    task automatic reload_with_pending_final(input logic [7:0] index);
        begin
            @(negedge clk);
            ioctl_index = index;
            // End-of-previous-file address may still be visible when HPS
            // raises download. Presence must reset based on file identity.
            ioctl_addr = 25'h0010000;
            ioctl_download = 1'b1;
            ioctl_wr = 1'b0;
            @(posedge clk); #1;
            check(!target_loaded(index), "new download retained old ROM presence");
            @(negedge clk);
            ioctl_addr = 25'h000FFF0;
            ioctl_data = 16'h5BEA;
            ioctl_wr = 1'b1;
            @(posedge clk); #1;
            ioctl_wr = 1'b0;
            loader_accept = 1'b1;
            @(posedge clk); #1;
            loader_accept = 1'b0;
            ioctl_download = 1'b0;
            repeat (3) @(posedge clk);
            #1;
            check(loader_valid && ioctl_wait && !target_loaded(index),
                  "ROM became present before final SDRAM write completed");
            loader_ready = 1'b1;
            @(posedge clk); #1;
            loader_ready = 1'b0;
            @(posedge clk); #1;
            check(!loader_valid && target_loaded(index),
                  "ROM did not become present after final write drained");
        end
    endtask

    task automatic empty_reload(input logic [7:0] index);
        begin
            @(negedge clk);
            ioctl_index = index;
            ioctl_addr = 25'h0010000;
            ioctl_download = 1'b1;
            ioctl_wr = 1'b0;
            @(posedge clk); #1;
            ioctl_download = 1'b0;
            repeat (2) @(posedge clk);
            #1;
            check(!target_loaded(index), "empty reload restored stale ROM presence");
        end
    endtask
    initial begin
        sdram_initialized = 1'b0;
        ioctl_download = 1'b0;
        ioctl_index = 8'h00;
        ioctl_wr = 1'b0;
        ioctl_addr = 25'h0000000;
        ioctl_data = 16'h0000;
        loader_accept = 1'b0;
        loader_ready = 1'b0;

        repeat (3) @(posedge clk);
        #1;
        check(ioctl_wait && bios_protect_flag == 3'b011,
              "loader did not hold while SDRAM was uninitialized");
        reset = 1'b0;
        sdram_initialized = 1'b1;
        ioctl_download = 1'b1;

        complete_word(8'd0, 25'h0000010, 16'h2860);
        complete_word(8'd3, 25'h0000020, 16'hE6A5);
        ioctl_wr = 1'b0;
        ioctl_download = 1'b0;
        @(posedge clk);
        #1;
        check(main_rom_loaded && ega_rom_loaded,
              "ROM presence was not latched after download completion");
        check(bios_protect_flag == 3'b011,
              "ROM protection was not restored after download");
        reload_with_pending_final(8'd0);
        check(ega_rom_loaded, "main reload invalidated the EGA ROM");
        reload_with_pending_final(8'd3);
        check(main_rom_loaded, "EGA reload invalidated the main ROM");
        reload_with_pending_final(8'd2);
        reload_with_pending_final(8'd2);
        empty_reload(8'd0);
        empty_reload(8'd3);
        empty_reload(8'd2);
        check(!protocol_error, "unexpected HPS loader protocol error");
        if (failures != 0)
            $fatal(1, "AT_HPS_ROM_LOADER_FAILURES count=%0d", failures);
        $display("AT_HPS_ROM_LOADER_PASS main=%b ega=%b", main_rom_loaded,
                 ega_rom_loaded);
        $finish;
    end
endmodule
