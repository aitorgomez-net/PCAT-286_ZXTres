// XT-IDE controller at the standard XT2IDE I/O window (300h-30Fh).
//
// The common IDE engine is clocked directly from the normalized AT bus clock.
// The wrapper turns one normalized request into the single-cycle io_read or
// io_write pulse expected by ide.v, then holds the response for the router's
// completion phase.  The management window and request encoding deliberately
// match the working XT Peripherals.sv integration.
`timescale 1ns/1ps

module spk286_at_xtide (
    input  logic        clk,
    input  logic        reset,

    input  logic        [1:0]  use_mmc,

    input  logic        request_valid,
    input  logic        request_command_valid,
    input  logic        request_write,
    input  logic        request_io,
    input  logic        [23:0] request_address,
    input  logic        [1:0]  request_byte_enable,
    input  logic        [15:0] request_data_out,
    output logic        request_accept,
    output logic        request_ready,
    output logic        [15:0] request_read_data,
    output logic        request_read_data_valid,

    input  logic        [15:0] mgmt_address,
    input  logic        [15:0] mgmt_writedata,
    input  logic        mgmt_write,
    input  logic        mgmt_read,
    output logic        [15:0] mgmt_readdata,
    output logic        [2:0]  ide_request,
    output logic        irq14,
    output logic        protocol_error
);
    logic        busy_q;
    logic        read_q;
    logic        word_q;
    logic        high_byte_port_q;
    logic [1:0]  byte_enable_q;
    logic [7:0]  data_high_q;
    logic        protocol_error_q;

    logic [3:0]  ide_io_address;
    logic        ide_io_read;
    logic        ide_io_write;
    logic [31:0] ide_io_writedata;
    logic [31:0] ide_io_readdata;
    logic [15:0] ide_mgmt_readdata;
    logic        ide_irq;
    logic        ide_ignore_access;
    logic        ide_drq;
    logic        ide_no_data;
    logic [1:0]  ide_drive_en;
    logic        ide_io_wait;

    logic selected;
    logic lane_valid;
    logic data_word;
    logic high_byte_port;
    logic mgmt_selected;
    logic [7:0] request_byte;

    always_comb begin
        // XT2IDE selects 300h-307h as the command block.  Port 308h is the
        // auxiliary high-byte latch for the 16-bit data register, while 309h
        // is the only hole in the 300h-30Fh window.  The control decoder
        // responds to 30Ah-30Fh.
        selected = request_valid && request_command_valid && request_io &&
                   (request_address[15:4] == 12'h030) &&
                   ((!request_address[3]) ||
                    (request_address[3:0] == 4'h8) ||
                    (request_address[2:1] != 2'b00));
        lane_valid = ((request_address[0] == 1'b0) &&
                      (request_byte_enable == 2'b01)) ||
                     ((request_address[0] == 1'b1) &&
                      (request_byte_enable == 2'b10));
        data_word = selected &&
                    (request_address[15:0] == 16'h0300) &&
                    (request_byte_enable == 2'b11);
        high_byte_port = selected &&
                         (request_address[15:0] == 16'h0308);
        mgmt_selected = (mgmt_address[15:8] == 8'hF0);
        request_byte = request_byte_enable[1] ?
                       request_data_out[15:8] : request_data_out[7:0];

        // This is the same address transform as XT2IDE followed by the XT
        // command/control select in Peripherals.sv.  30Eh therefore reaches
        // IDE status/control register 14 and 30Fh reaches register 15.
        ide_io_address = request_address[3] ?
                         {1'b1, request_address[2:0]} :
                         {1'b0, request_address[2:0]};
        ide_io_writedata = data_word ?
                           {16'h0000, request_data_out} :
                           ((request_address[15:0] == 16'h0300) ?
                            {16'h0000, data_high_q, request_byte} :
                            {24'h000000, request_byte});
    end

    assign request_accept = selected && !busy_q &&
                            (lane_valid || data_word);
    assign request_ready = busy_q;
    assign request_read_data_valid = busy_q && read_q;
    assign request_read_data = word_q ? ide_io_readdata[15:0] :
                               high_byte_port_q ? {8'h00, data_high_q} :
                               (byte_enable_q[1] ?
                                {ide_io_readdata[7:0], 8'h00} :
                                {8'h00, ide_io_readdata[7:0]});
    assign mgmt_readdata = mgmt_selected ? ide_mgmt_readdata : 16'h0000;
    assign irq14 = ide_irq;
    assign protocol_error = protocol_error_q;

    // ide.v samples io_read/io_write on this edge.  request_accept is a
    // one-cycle pulse while the router is idle, so it is already the edge
    // detector used by the normalized endpoint.
    assign ide_io_read = request_accept && !request_write && !high_byte_port;
    assign ide_io_write = request_accept && request_write && !high_byte_port;

    always_ff @(posedge clk) begin
        if (reset) begin
            busy_q <= 1'b0;
            read_q <= 1'b0;
            word_q <= 1'b0;
            high_byte_port_q <= 1'b0;
            byte_enable_q <= 2'b00;
            data_high_q <= 8'hFF;
            protocol_error_q <= 1'b0;
        end else begin
            if (busy_q) begin
                busy_q <= 1'b0;
                // XT2IDE makes the high byte of a data read available at 308h
                // after the corresponding read from 300h.
                if (read_q && !high_byte_port_q && !word_q &&
                    (request_address[15:0] == 16'h0300))
                    data_high_q <= ide_io_readdata[15:8];
            end else if (request_accept) begin
                busy_q <= 1'b1;
                read_q <= !request_write;
                word_q <= data_word;
                high_byte_port_q <= high_byte_port;
                byte_enable_q <= request_byte_enable;
                if (high_byte_port && request_write)
                    data_high_q <= request_byte;
            end

            if (selected && !(lane_valid || data_word))
                protocol_error_q <= 1'b1;
        end
    end

    ide u_ide (
        .clk             (clk),
        .rst_n           (!reset),
        .irq             (ide_irq),
        .drq             (ide_drq),
        .use_fast        (1'b0),
        .no_data         (ide_no_data),
        .drive_en        (ide_drive_en),
        .io_address      (ide_io_address),
        .io_read         (ide_io_read),
        .io_readdata     (ide_io_readdata),
        .io_write        (ide_io_write),
        .io_writedata    (ide_io_writedata),
        .io_32           (1'b0),
        .io_wait         (ide_io_wait),
        .request         (ide_request),
        .mgmt_address    (mgmt_address[3:0]),
        .mgmt_write      (mgmt_write && mgmt_selected),
        .mgmt_writedata  (mgmt_writedata),
        .mgmt_read       (mgmt_read && mgmt_selected),
        .mgmt_readdata   (ide_mgmt_readdata),
        .primary_only    (use_mmc == 2'b10),
        .secondary_only  (use_mmc == 2'b01),
        .ignore_access   (ide_ignore_access)
    );

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset)
            assert (!(request_accept && !selected))
                else $error("AT XT-IDE accepted an unselected request");
    end
`endif
endmodule
