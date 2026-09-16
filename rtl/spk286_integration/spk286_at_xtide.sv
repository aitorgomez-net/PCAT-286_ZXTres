// Standard AT IDE controller.  The AT BIOS image uses 1F0h-1F7h plus 3F6h
// and expects the data register at 1F0h to be a native 16-bit I/O port.
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
    logic [1:0]  byte_enable_q;
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
    logic standard_selected;
    logic lane_valid;
    logic data_word;
    logic mgmt_selected;
    logic [7:0] request_byte;

    always_comb begin
        // Regular AT IDE, as used by 86Box's ide_isa_device and by the
        // ao486/z486 integrations: 1F0h-1F7h plus the alternate-status /
        // device-control port at 3F6h.  3F7h remains owned by the floppy
        // controller.
        standard_selected = request_valid && request_command_valid &&
                            request_io &&
                            (((request_address[15:0] >= 16'h01F0) &&
                              (request_address[15:0] <= 16'h01F7)) ||
                             (request_address[15:0] == 16'h03F6));
        selected = standard_selected;
        lane_valid = ((request_address[0] == 1'b0) &&
                      (request_byte_enable == 2'b01)) ||
                     ((request_address[0] == 1'b1) &&
                      (request_byte_enable == 2'b10));
        data_word = selected &&
                    (request_address[15:0] == 16'h01F0) &&
                    (request_byte_enable == 2'b11);
        mgmt_selected = (mgmt_address[15:8] == 8'hF0);
        request_byte = request_byte_enable[1] ?
                       request_data_out[15:8] : request_data_out[7:0];

        // Standard AT maps 3F6h to IDE register 14.  The same bit-9
        // transform is used by ao486/z486.
        ide_io_address = request_address[9] ?
                         {1'b1, request_address[2:0]} :
                         {1'b0, request_address[2:0]};
        ide_io_writedata = data_word ?
                           {16'h0000, request_data_out} :
                           {24'h000000, request_byte};
    end

    assign request_accept = selected && !busy_q &&
                            (lane_valid || data_word);
    assign request_ready = busy_q;
    assign request_read_data_valid = busy_q && read_q;
    assign request_read_data = word_q ? ide_io_readdata[15:0] :
                               (byte_enable_q[1] ?
                                {ide_io_readdata[7:0], 8'h00} :
                                {8'h00, ide_io_readdata[7:0]});
    assign mgmt_readdata = mgmt_selected ? ide_mgmt_readdata : 16'h0000;
    assign irq14 = ide_irq;
    assign protocol_error = protocol_error_q;

    // ide.v samples io_read/io_write on this edge.  request_accept is a
    // one-cycle pulse while the router is idle, so it is already the edge
    // detector used by the normalized endpoint.
    assign ide_io_read = request_accept && !request_write;
    assign ide_io_write = request_accept && request_write;

    always_ff @(posedge clk) begin
        if (reset) begin
            busy_q <= 1'b0;
            read_q <= 1'b0;
            word_q <= 1'b0;
            byte_enable_q <= 2'b00;
            protocol_error_q <= 1'b0;
        end else begin
            if (busy_q) begin
                busy_q <= 1'b0;
            end else if (request_accept) begin
                busy_q <= 1'b1;
                read_q <= !request_write;
                word_q <= data_word;
                byte_enable_q <= request_byte_enable;
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
