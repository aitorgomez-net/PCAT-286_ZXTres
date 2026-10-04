// Directed protection contract for the production FDC wrapper and shared core.
// The DMA and HPS peers are explicit drivers. This does not model SDRAM or
// persistence on the host filesystem; those need the separate sector-write bank.
`timescale 1ns/1ps
module spk286_at_floppy_write_protect_tb;
    logic clk = 0;
    always #10 clk = ~clk;
    logic reset = 1;
    logic request_valid = 0, request_command_valid = 0;
    logic request_write = 0, request_io = 0;
    logic [23:0] request_address = 0;
    logic [1:0] request_byte_enable = 0;
    logic [15:0] request_data_out = 0;
    wire request_accept, request_ready, request_read_data_valid;
    wire [15:0] request_read_data;
    logic dma_transfer_valid = 0, dma_transfer_complete = 0;
    logic dma_terminal_count = 0;
    logic [15:0] dma_transfer_data_in = 0;
    wire dma_transfer_accept, dma_transfer_ready;
    wire [15:0] dma_transfer_data_out;
    wire [7:0] dma_request;
    wire irq6;
    logic [15:0] mgmt_address = 0, mgmt_writedata = 0;
    logic mgmt_write = 0, mgmt_read = 0;
    wire [15:0] mgmt_readdata;
    logic [1:0] floppy_write_protect = 0;
    wire [1:0] floppy_present, floppy_request;
    wire [15:0] side_effect_count, command_count;
    wire protocol_error;
    logic forbid_write_activity = 0;
    integer matrix_cases = 0, reads = 0, blocked_writes = 0;
    integer blocked_formats = 0, allowed_writes = 0, allowed_formats = 0;
    integer sense_checks = 0, guarded_cycles = 0;
    logic [7:0] result_bytes [0:6];

    spk286_at_fdc #(.RETAINED_FDC_WRITE(1'b1)) dut (
        .clk(clk), .reset(reset), .request_valid(request_valid),
        .request_command_valid(request_command_valid),
        .request_write(request_write), .request_io(request_io),
        .request_address(request_address),
        .request_byte_enable(request_byte_enable), .request_data_out(request_data_out),
        .retained_io_command(request_valid && request_command_valid && request_io),
        .retained_io_address(request_address), .retained_io_write(request_write),
        .retained_io_byte_enable(request_byte_enable),
        .retained_io_data_out(request_data_out), .request_accept(request_accept),
        .request_ready(request_ready), .request_read_data(request_read_data),
        .request_read_data_valid(request_read_data_valid),
        .dma_transfer_valid(dma_transfer_valid),
        .dma_transfer_complete(dma_transfer_complete),
        .dma_terminal_count(dma_terminal_count), .dma_active_channel(3'd2),
        .dma_transfer_data_in(dma_transfer_data_in),
        .dma_transfer_accept(dma_transfer_accept), .dma_transfer_ready(dma_transfer_ready),
        .dma_transfer_data_out(dma_transfer_data_out), .dma_request(dma_request),
        .irq6(irq6), .mgmt_address(mgmt_address), .mgmt_writedata(mgmt_writedata),
        .mgmt_write(mgmt_write), .mgmt_read(mgmt_read), .mgmt_readdata(mgmt_readdata),
        .floppy_write_protect(floppy_write_protect), .floppy_present(floppy_present),
        .floppy_request(floppy_request), .side_effect_count(side_effect_count),
        .command_count(command_count), .protocol_error(protocol_error)
    );

    always @(posedge clk) if (!reset && forbid_write_activity) begin
        guarded_cycles = guarded_cycles + 1;
        if (dma_request !== 8'h00 || floppy_request[1] !== 1'b0 ||
            dma_transfer_accept !== 1'b0 || dma_transfer_ready !== 1'b0)
            $fatal(1, "Protected write/format reached DMA or HPS write path");
    end

    task automatic tick(input integer count);
        repeat(count) begin @(posedge clk); @(negedge clk); end
    endtask

    task automatic io_access(input logic wr, input logic [15:0] address,
                             input logic [7:0] value, output logic [7:0] answer);
        integer limit;
        @(negedge clk);
        request_valid = 1; request_command_valid = 1; request_io = 1;
        request_write = wr; request_address = {8'd0, address};
        request_byte_enable = address[0] ? 2'b10 : 2'b01;
        request_data_out = address[0] ? {value, 8'd0} : {8'd0, value};
        #1;
        if (!request_accept) $fatal(1, "FDC I/O request not accepted");
        @(posedge clk); @(negedge clk);
        request_valid = 0; request_command_valid = 0; request_io = 0;
        limit = 0;
        while (!request_ready && limit < 10) begin tick(1); limit = limit + 1; end
        if (!request_ready || (!wr && !request_read_data_valid))
            $fatal(1, "FDC I/O response missing");
        answer = address[0] ? request_read_data[15:8] : request_read_data[7:0];
        tick(2);
    endtask

    task automatic write_port(input logic [15:0] address, input logic [7:0] value);
        logic [7:0] ignored;
        io_access(1, address, value, ignored);
    endtask

    task automatic management_write(input logic [15:0] address, input logic [15:0] value);
        @(negedge clk); mgmt_address = address; mgmt_writedata = value; mgmt_write = 1;
        @(posedge clk); @(negedge clk); mgmt_write = 0; tick(1);
    endtask

    task automatic prepare(input integer osd_mask, input integer host_mask,
                           input integer drive);
        forbid_write_activity = 0; reset = 1;
        dma_transfer_valid = 0; dma_transfer_complete = 0; dma_terminal_count = 0;
        request_valid = 0; request_command_valid = 0; request_io = 0;
        mgmt_write = 0; mgmt_read = 0;
        tick(4); reset = 0; tick(4); floppy_write_protect = 2'(osd_mask);
        for (integer disk = 0; disk < 2; disk = disk + 1) begin
            management_write(16'hF200 + 16'(disk * 128), 1);
            management_write(16'hF201 + 16'(disk * 128), 16'((host_mask >> disk) & 1));
            management_write(16'hF202 + 16'(disk * 128), 80);
            management_write(16'hF203 + 16'(disk * 128), 9);
            management_write(16'hF204 + 16'(disk * 128), 1440);
            management_write(16'hF205 + 16'(disk * 128), 2);
        end
        if (floppy_present !== 2'b11) $fatal(1, "Both media must be present");
        write_port(16'h03F2, 8'h3C | 8'(drive));
        write_port(16'h03F5, 8'h03); write_port(16'h03F5, 8'hCF);
        write_port(16'h03F5, 8'h02); // DMA, 250 kbit/s reset rate matches 9 sectors.
    endtask

    task automatic data_command(input logic [7:0] opcode, input integer drive);
        write_port(16'h03F5, opcode); write_port(16'h03F5, 8'(drive));
        write_port(16'h03F5, 0); write_port(16'h03F5, 0);
        write_port(16'h03F5, 1); write_port(16'h03F5, 2);
        write_port(16'h03F5, 9); write_port(16'h03F5, 8'h2A);
        write_port(16'h03F5, 8'hFF);
    endtask

    task automatic format_command(input integer drive);
        write_port(16'h03F5, 8'h4D); write_port(16'h03F5, 8'(drive));
        write_port(16'h03F5, 2); write_port(16'h03F5, 9);
        write_port(16'h03F5, 8'h2A); write_port(16'h03F5, 8'hF6);
    endtask

    task automatic wait_request(input logic [1:0] expected);
        integer limit;
        limit = 0;
        while (floppy_request !== expected && limit < 100) begin tick(1); limit = limit + 1; end
        if (floppy_request !== expected) $fatal(1, "Missing HPS sector request");
    endtask

    task automatic dma_byte(input logic [7:0] value, input logic last,
                            input logic reading, input integer index);
        integer limit;
        limit = 0;
        while (!dma_request[2] && limit < 100) begin tick(1); limit = limit + 1; end
        if (!dma_request[2]) $fatal(1, "DMA request missing");
        @(negedge clk); dma_transfer_valid = 1; dma_transfer_data_in = {8'd0, value};
        #1;
        if (!dma_transfer_accept) $fatal(1, "DMA endpoint did not accept beat");
        if (reading && dma_transfer_data_out[7:0] !== 8'(index ^ 8'hA5))
            $fatal(1, "Protected read altered sector data");
        tick(1);
        if (!dma_transfer_ready) $fatal(1, "DMA endpoint not ready");
        dma_transfer_complete = 1; dma_terminal_count = last;
        tick(1); dma_transfer_complete = 0; dma_terminal_count = 0;
        dma_transfer_valid = 0; tick(1);
    endtask

    task automatic read_result(input integer drive, input logic blocked);
        integer limit;
        logic [7:0] result_byte;
        limit = 0;
        while (!irq6 && limit < 4100) begin tick(1); limit = limit + 1; end
        if (!irq6) $fatal(1, "FDC result interrupt missing");
        for (integer byte_index = 0; byte_index < 7; byte_index = byte_index + 1) begin
            io_access(0, 16'h03F5, 0, result_byte);
            result_bytes[byte_index] = result_byte;
        end
        if (result_bytes[0][1:0] !== 2'(drive) || result_bytes[6] !== 2)
            $fatal(1, "Wrong result drive/sector size drive=%0d blocked=%0d bytes=%h %h %h %h %h %h %h", drive, blocked, result_bytes[0], result_bytes[1], result_bytes[2], result_bytes[3], result_bytes[4], result_bytes[5], result_bytes[6]);
        if (blocked) begin
            if (result_bytes[0][7:6] !== 2'b01 || result_bytes[1] !== 8'h27 ||
                result_bytes[2] !== 8'h31)
                $fatal(1, "Write protection result missing");
        end else if (result_bytes[0][7:6] !== 0 || result_bytes[1] !== 0 || result_bytes[2] !== 0)
            $fatal(1, "Allowed read/write reported failure");
        if (irq6 || floppy_request !== 0 || dma_request !== 0 || protocol_error)
            $fatal(1, "FDC did not return to idle after result");
    endtask

    task automatic drain_sector(input logic [7:0] filler, input logic format);
        logic [15:0] value;
        tick(3); mgmt_address = 16'hF2FF;
        for (integer byte_index = 0; byte_index < 512; byte_index = byte_index + 1) begin
            tick(2); value = mgmt_readdata;
            if (value[7:0] !== (format ? filler : 8'(byte_index ^ 8'h5A)))
                $fatal(1, "Allowed write/format HPS payload mismatch");
            mgmt_read = 1; tick(1); mgmt_read = 0;
        end
        tick(2);
    endtask

    initial begin : matrix
        logic [7:0] st3;
        logic protected_disk;
        for (integer osd_mask = 0; osd_mask < 4; osd_mask = osd_mask + 1)
            for (integer host_mask = 0; host_mask < 4; host_mask = host_mask + 1)
                for (integer drive = 0; drive < 2; drive = drive + 1) begin
                    protected_disk = ((osd_mask | host_mask) >> drive) & 1;
                    prepare(osd_mask, host_mask, drive);
                    write_port(16'h03F5, 8'h04); write_port(16'h03F5, 8'(drive));
                    io_access(0, 16'h03F5, 0, st3);
                    if (st3[6] !== protected_disk || st3[1:0] !== 2'(drive))
                        $fatal(1, "Sense Drive Status did not combine OSD and host protection");
                    sense_checks = sense_checks + 1;
                    data_command(8'h46, drive); wait_request(2'b01);
                    for (integer index = 0; index < 512; index = index + 1)
                        management_write(16'hF2FF, {8'd0, 8'(index ^ 8'hA5)});
                    for (integer index = 0; index < 512; index = index + 1)
                        dma_byte(0, index == 511, 1, index);
                    read_result(drive, 0); reads = reads + 1;

                    prepare(osd_mask, host_mask, drive);
                    forbid_write_activity = protected_disk;
                    data_command(8'h45, drive);
                    if (protected_disk) begin
                        read_result(drive, 1); blocked_writes = blocked_writes + 1;
                    end else begin
                        for (integer index = 0; index < 512; index = index + 1)
                            dma_byte(8'(index ^ 8'h5A), index == 511, 0, index);
                        wait_request(2'b10); drain_sector(0, 0); read_result(drive, 0);
                        allowed_writes = allowed_writes + 1;
                    end
                    forbid_write_activity = 0;

                    prepare(osd_mask, host_mask, drive);
                    forbid_write_activity = protected_disk;
                    format_command(drive);
                    if (protected_disk) begin
                        read_result(drive, 1); blocked_formats = blocked_formats + 1;
                    end else begin
                        dma_byte(0, 0, 0, 0); dma_byte(0, 0, 0, 1);
                        dma_byte(1, 0, 0, 2); dma_byte(2, 0, 0, 3);
                        wait_request(2'b10); drain_sector(8'hF6, 1);
                        // Only the first permitted format sector is checked;
                        // reset the controller before the remaining eight CHRN inputs.
                        allowed_formats = allowed_formats + 1;
                    end
                    forbid_write_activity = 0;
                    matrix_cases = matrix_cases + 1;
                    $display("FDC_WP_CASE osd=%0d host=%0d drive=%0d protected=%0d", osd_mask, host_mask, drive, protected_disk);
                end
        if (matrix_cases != 32 || reads != 32 || sense_checks != 32 ||
            blocked_writes != 24 || blocked_formats != 24 ||
            allowed_writes != 8 || allowed_formats != 8 || guarded_cycles == 0)
            $fatal(1, "Incomplete protection matrix");
        $display("AT_FLOPPY_WRITE_PROTECT_PASS cases=%0d reads=%0d blocked_writes=%0d blocked_formats=%0d allowed_writes=%0d allowed_formats=%0d sense=%0d guarded_cycles=%0d", matrix_cases, reads, blocked_writes, blocked_formats, allowed_writes, allowed_formats, sense_checks, guarded_cycles);
        $finish;
    end
    initial begin #20_000_000; $fatal(1, "Protection bank timeout"); end
endmodule
