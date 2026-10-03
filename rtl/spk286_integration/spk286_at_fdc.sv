// IBM AT floppy-controller adapter for the normalized SPK286 device boundary.
//
// The controller is rtl/common/floppy.v, shared with the XT and ao486/z486
// profiles. Its optional write-address input isolates write decoding while
// io_address preserves the existing read path. This wrapper translates the
// normalized AT I/O, DMA and hps_ext management handshakes.
`timescale 1ns/1ps

module spk286_at_fdc #(
    parameter logic RETAINED_FDC_WRITE = 1'b0
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        request_valid,
    input  logic        request_command_valid,
    input  logic        request_write,
    input  logic        request_io,
    input  logic [23:0] request_address,
    input  logic [1:0]  request_byte_enable,
    input  logic [15:0] request_data_out,
    input  logic        retained_io_command,
    input  logic [23:0] retained_io_address,
    input  logic        retained_io_write,
    input  logic [1:0]  retained_io_byte_enable,
    input  logic [15:0] retained_io_data_out,
    output logic        request_accept,
    output logic        request_ready,
    output logic [15:0] request_read_data,
    output logic        request_read_data_valid,

    input  logic        dma_transfer_valid,
    input  logic        dma_transfer_complete,
    input  logic        dma_terminal_count,
    input  logic [2:0]  dma_active_channel,
    input  logic [15:0] dma_transfer_data_in,
    output logic        dma_transfer_accept,
    output logic        dma_transfer_ready,
    output logic [15:0] dma_transfer_data_out,
    output logic [7:0]  dma_request,
    output logic        irq6,

    input  logic [15:0] mgmt_address,
    input  logic [15:0] mgmt_writedata,
    input  logic        mgmt_write,
    input  logic        mgmt_read,
    output logic [15:0] mgmt_readdata,
    input  logic [1:0]  floppy_write_protect,
    output logic [1:0]  floppy_present,
    output logic [1:0]  floppy_request,

    output logic [15:0] side_effect_count,
    output logic [15:0] command_count,
    output logic        protocol_error
);
    localparam logic [1:0] IO_IDLE = 2'd0;
    localparam logic [1:0] IO_READ_WAIT = 2'd1;
    localparam logic [1:0] IO_DONE = 2'd2;

    logic [1:0] io_state_q;
    logic [1:0] io_byte_enable_q;
    logic [7:0] io_read_data_q;
    logic       io_read_data_valid_q;
    logic       endpoint_seen_q;
    logic       selected;
    logic       lane_valid;
    logic [7:0] request_byte;

    logic [7:0] fdc_io_readdata;
    logic [7:0] fdc_dma_writedata;
    logic       fdc_dma_request;
    logic       fdc_irq;
    logic [15:0] fdc_mgmt_readdata;
    logic [1:0] fdc_request;
    logic       fdc_mgmt_selected;
    logic       fdc_io_read;
    logic       fdc_io_write;
    logic       fdc_dma_ack;

    always_comb begin
        selected = request_valid && request_command_valid && request_io &&
                   (request_address[15:0] >= 16'h03F0) &&
                   (request_address[15:0] <= 16'h03F7);
        lane_valid = ((request_address[0] == 1'b0) &&
                      (request_byte_enable == 2'b01)) ||
                     ((request_address[0] == 1'b1) &&
                      (request_byte_enable == 2'b10));
        request_byte = request_byte_enable[1] ?
                       request_data_out[15:8] : request_data_out[7:0];
        fdc_mgmt_selected = (mgmt_address[15:8] == 8'hF2);
    end

    // Reads preserve the old general address/pulse/read-wait path exactly.
    // Writes use only retained I/O COMMAND, CPU grant and retained payload.
    wire retained_write_selected = retained_io_command && retained_io_write &&
                                   (retained_io_address[15:0] >= 16'h03F0) &&
                                   (retained_io_address[15:0] <= 16'h03F7) &&
                                   (retained_io_address[15:0] != 16'h03F6);
    wire retained_lane_valid = (!retained_io_address[0] &&
                                 (retained_io_byte_enable == 2'b01)) ||
                                (retained_io_address[0] &&
                                 (retained_io_byte_enable == 2'b10));
    wire read_accept = (io_state_q == IO_IDLE) && selected && lane_valid &&
                       !request_write;
    wire write_accept = (io_state_q == IO_IDLE) &&
                        (RETAINED_FDC_WRITE ?
                         retained_write_selected && retained_lane_valid :
                         selected && lane_valid && request_write);
    wire [1:0] accepted_byte_enable = (RETAINED_FDC_WRITE && write_accept) ?
                                      retained_io_byte_enable : request_byte_enable;
    wire [2:0] write_address = RETAINED_FDC_WRITE ?
                               retained_io_address[2:0] : request_address[2:0];
    wire [7:0] write_byte = RETAINED_FDC_WRITE ?
                            (retained_io_byte_enable[1] ?
                             retained_io_data_out[15:8] : retained_io_data_out[7:0]) :
                            request_byte;
    assign request_accept = read_accept || write_accept;
    assign request_ready = (io_state_q == IO_DONE);
    assign request_read_data_valid = request_ready && io_read_data_valid_q;
    assign request_read_data = io_byte_enable_q[1] ?
                               {io_read_data_q, 8'h00} :
                               {8'h00, io_read_data_q};

    // floppy.v registers its I/O read value on the access edge.  The wrapper
    // therefore adds one read-wait clock before exposing normalized READY.
    assign fdc_io_read = read_accept;
    assign fdc_io_write = write_accept;

    assign dma_request = fdc_dma_request ? 8'h04 : 8'h00;
    assign dma_transfer_accept = dma_transfer_valid &&
                                 (dma_active_channel == 3'd2) &&
                                 fdc_dma_request && !endpoint_seen_q;
    assign dma_transfer_ready = dma_transfer_valid &&
                                (dma_active_channel == 3'd2) &&
                                fdc_dma_request && endpoint_seen_q;
    assign dma_transfer_data_out = {8'h00, fdc_dma_writedata};
    // Advance the shared FDC only after the memory side has completed the same
    // normalized beat. This pulse is the falling-DACK equivalent used by XT.
    assign fdc_dma_ack = dma_transfer_complete &&
                         (dma_active_channel == 3'd2);

    assign irq6 = fdc_irq;
    assign mgmt_readdata = fdc_mgmt_selected ? fdc_mgmt_readdata : 16'h0000;
    assign floppy_request = fdc_request;

    always_ff @(posedge clk) begin
        if (reset) begin
            io_state_q <= IO_IDLE;
            io_byte_enable_q <= 2'b00;
            io_read_data_q <= 8'h00;
            io_read_data_valid_q <= 1'b0;
            endpoint_seen_q <= 1'b0;
            floppy_present <= 2'b00;
            side_effect_count <= 16'h0000;
            command_count <= 16'h0000;
            protocol_error <= 1'b0;
        end else begin
            case (io_state_q)
                IO_IDLE: begin
                    io_read_data_valid_q <= 1'b0;
                    if (request_accept) begin
                        io_byte_enable_q <= accepted_byte_enable;
                        side_effect_count <= side_effect_count + 16'h0001;
                        if (fdc_io_write) begin
                            io_state_q <= IO_DONE;
                            if (write_address == 3'd5)
                                command_count <= command_count + 16'h0001;
                        end else begin
                            io_state_q <= IO_READ_WAIT;
                        end
                    end
                end
                IO_READ_WAIT: begin
                    io_read_data_q <= fdc_io_readdata;
                    io_read_data_valid_q <= 1'b1;
                    io_state_q <= IO_DONE;
                end
                IO_DONE: io_state_q <= IO_IDLE;
                default: io_state_q <= IO_IDLE;
            endcase

            if (!dma_transfer_valid)
                endpoint_seen_q <= 1'b0;
            else if (dma_transfer_accept)
                endpoint_seen_q <= 1'b1;

            if (mgmt_write && fdc_mgmt_selected &&
                (mgmt_address[3:0] == 4'h0))
                floppy_present[mgmt_address[7]] <= mgmt_writedata[0];

            if (selected && !lane_valid)
                protocol_error <= 1'b1;
        end
    end

    floppy #(
        .SEPARATE_IO_WRITE_ADDRESS(RETAINED_FDC_WRITE)
    ) u_fdc (
        .clk             (clk),
        .rst_n           (!reset),
        .dma_req         (fdc_dma_request),
        .dma_ack         (fdc_dma_ack),
        .dma_tc          (fdc_dma_ack && dma_terminal_count),
        .dma_readdata    (dma_transfer_data_in[7:0]),
        .dma_writedata   (fdc_dma_writedata),
        .irq             (fdc_irq),
        .io_address      (request_address[2:0]),
        .io_write_address(write_address),
        .io_read         (fdc_io_read),
        .io_readdata     (fdc_io_readdata),
        .io_write        (fdc_io_write),
        .io_writedata    (write_byte),
        .fdd0_inserted   (),
        .mgmt_address    (mgmt_address[3:0]),
        .mgmt_fddn       (mgmt_address[7]),
        .mgmt_write      (mgmt_write && fdc_mgmt_selected),
        .mgmt_writedata  (mgmt_writedata),
        .mgmt_read       (mgmt_read && fdc_mgmt_selected),
        .mgmt_readdata   (fdc_mgmt_readdata),
        .wp              (floppy_write_protect),
        .clock_rate      (28'd50_000_000),
        .request         (fdc_request)
    );

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset) begin
            assert (!(request_accept && !selected))
                else $error("AT FDC accepted an unselected request");
            assert (!(fdc_dma_ack && (dma_active_channel != 3'd2)))
                else $error("AT FDC observed DMA completion outside channel 2");
        end
    end
`endif
endmodule
