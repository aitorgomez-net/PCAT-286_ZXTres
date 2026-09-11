// Functional AT DMA boundary.
//
// This block models the AT-visible register file and the eight-channel
// ownership/transfer contract.  It intentionally does not reuse KF8237: that
// imported XT-oriented device exposes four channels and a 16-bit address
// boundary.  The production AT path needs two controller banks, page bytes,
// channel 4 cascade semantics and a 24-bit retained transfer record.
`timescale 1ns/1ps

module spk286_at_dma (
    input  logic        clk,
    input  logic        reset,

    input  logic        request_valid,
    input  logic        request_command_valid,
    input  logic        request_write,
    input  logic        request_io,
    input  logic [23:0] request_address,
    input  logic [1:0]  request_byte_enable,
    input  logic [15:0] request_data_out,
    output logic        request_accept,
    output logic        request_ready,
    output logic [15:0] request_read_data,
    output logic        request_read_data_valid,

    input  logic [7:0]  dma_request,
    input  logic        dma_grant,
    input  logic        transfer_accept,
    input  logic        transfer_ready,
    input  logic [15:0] transfer_data_in,

    output logic        dma_bus_request,
    output logic        dma_transfer_valid,
    output logic [2:0]  dma_active_channel,
    output logic [23:0] dma_transfer_address,
    output logic [1:0]  dma_transfer_byte_enable,
    output logic        dma_transfer_write_to_memory,
    output logic        dma_transfer_read_from_memory,
    output logic        dma_transfer_io_to_memory,
    output logic        dma_transfer_memory_to_io,
    output logic [15:0] dma_transfer_data_out,
    output logic        dma_transfer_complete,
    output logic        dma_terminal_count,
    output logic [7:0]  dma_request_state,
    output logic [7:0]  dma_acknowledge,
    output logic        cascade_request,
    output logic        protocol_error
);
    localparam logic [1:0] IO_IDLE = 2'd0;
    localparam logic [1:0] IO_DONE = 2'd1;

    logic [1:0] io_state_q;
    logic [1:0] io_byte_enable_q;
    logic [7:0] io_read_data_q;
    logic       io_read_data_valid_q;

    logic [15:0] base_address_q [0:7];
    logic [15:0] current_address_q [0:7];
    logic [15:0] base_count_q [0:7];
    logic [15:0] current_count_q [0:7];
    logic [7:0]  page_q [0:7];
    logic [7:0]  mode_q [0:7];
    logic [7:0]  mask_q;
    logic [7:0]  software_request_q;
    logic [7:0]  single_block_q;
    logic [1:0]  byte_pointer_q;

    logic       transfer_active_q;
    logic       transfer_accepted_q;
    logic [2:0] active_channel_q;
    logic [7:0] transfer_request_state;
    logic       selected_channel_valid;
    logic [2:0] selected_channel;
    logic       config_port_valid;
    logic       config_lane_valid;
    logic       page_port_valid;
    logic [2:0] config_channel;
    logic       address_port_valid;
    logic       count_port_valid;
    logic       dma1_bank;
    logic       dma2_bank;
    logic [7:0] config_byte;
    logic       completion_block;

    integer i;
    integer j;

    function automatic logic is_page_port(input logic [15:0] port);
        begin
            case (port)
                16'h0080, 16'h0081, 16'h0082, 16'h0083,
                16'h0089, 16'h008A, 16'h008B, 16'h008F:
                    is_page_port = 1'b1;
                default:
                    is_page_port = 1'b0;
            endcase
        end
    endfunction

    function automatic logic [2:0] page_port_channel(input logic [15:0] port);
        begin
            case (port)
                16'h0080: page_port_channel = 3'd0;
                16'h0081: page_port_channel = 3'd2;
                16'h0082: page_port_channel = 3'd3;
                16'h0083: page_port_channel = 3'd1;
                16'h0089: page_port_channel = 3'd5;
                16'h008A: page_port_channel = 3'd6;
                16'h008B: page_port_channel = 3'd7;
                default:  page_port_channel = 3'd4;
            endcase
        end
    endfunction

    always_comb begin
        dma1_bank = (request_address[15:0] <= 16'h000F);
        dma2_bank = (request_address[15:0] >= 16'h00C0) &&
                    (request_address[15:0] <= 16'h00DF);
        config_byte = request_byte_enable[1] ?
                      request_data_out[15:8] : request_data_out[7:0];

        config_lane_valid =
            ((request_address[0] == 1'b0) &&
             (request_byte_enable == 2'b01)) ||
            ((request_address[0] == 1'b1) &&
             (request_byte_enable == 2'b10));
        page_port_valid = is_page_port(request_address[15:0]);

        address_port_valid =
            (dma1_bank && (request_address[3:0] <= 4'h7) &&
             !request_address[0]) ||
            (dma2_bank && (request_address[1:0] == 2'b00));
        count_port_valid =
            (dma1_bank && (request_address[3:0] <= 4'h7) &&
             request_address[0]) ||
            (dma2_bank && (request_address[1:0] == 2'b10));

        config_port_valid = dma1_bank || dma2_bank || page_port_valid;
        config_channel = 3'd0;
        if (page_port_valid)
            config_channel = page_port_channel(request_address[15:0]);
        else if (dma1_bank)
            config_channel = {1'b0, request_address[2:1]};
        else if (dma2_bank)
            config_channel = 3'd4 + request_address[3:2];

        transfer_request_state = dma_request | software_request_q;
        transfer_request_state = transfer_request_state & ~mask_q;
        transfer_request_state = transfer_request_state & ~single_block_q;
        dma_request_state = transfer_request_state;

        selected_channel_valid = 1'b0;
        selected_channel = 3'd0;
        for (j = 0; j < 8; j = j + 1) begin
            if (!selected_channel_valid && transfer_request_state[j] &&
                (j != 4)) begin
                selected_channel_valid = 1'b1;
                selected_channel = j[2:0];
            end
        end

        // Channel 4 is the AT cascade link and never emits a memory beat.
        cascade_request = transfer_request_state[4] &&
                          (mode_q[4][7:6] == 2'b11);
        completion_block = dma_transfer_complete;
    end

    assign request_accept = (io_state_q == IO_IDLE) && request_valid &&
                            request_command_valid && request_io &&
                            config_port_valid && config_lane_valid;
    assign request_ready = (io_state_q == IO_DONE);
    assign request_read_data_valid = request_ready &&
                                     io_read_data_valid_q;
    assign request_read_data = io_byte_enable_q[1] ?
                               {io_read_data_q, 8'h00} :
                               {8'h00, io_read_data_q};

    assign dma_bus_request = !completion_block &&
                             (transfer_active_q || selected_channel_valid);
    assign dma_transfer_valid = transfer_active_q;
    assign dma_active_channel = active_channel_q;
    assign dma_acknowledge = transfer_active_q ?
                             (8'b00000001 << active_channel_q) : 8'h00;

    always_comb begin
        if (active_channel_q < 3'd4) begin
            dma_transfer_address = {page_q[active_channel_q],
                                     current_address_q[active_channel_q]};
            dma_transfer_byte_enable = 2'b01;
        end else begin
            // DMA2 addresses are word addressed; this functional 24-bit
            // profile keeps the even byte address and both data lanes.
            dma_transfer_address = {page_q[active_channel_q],
                                    current_address_q[active_channel_q][15:1],
                                    1'b0};
            dma_transfer_byte_enable = 2'b11;
        end

        dma_transfer_write_to_memory =
            mode_q[active_channel_q][3:2] == 2'b01;
        dma_transfer_read_from_memory =
            mode_q[active_channel_q][3:2] == 2'b10;
        dma_transfer_io_to_memory = dma_transfer_write_to_memory;
        dma_transfer_memory_to_io = dma_transfer_read_from_memory;
        dma_transfer_data_out = transfer_data_in;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            io_state_q <= IO_IDLE;
            io_byte_enable_q <= 2'b00;
            io_read_data_q <= 8'h00;
            io_read_data_valid_q <= 1'b0;
            mask_q <= 8'hFF;
            software_request_q <= 8'h00;
            single_block_q <= 8'h00;
            byte_pointer_q <= 2'b00;
            transfer_active_q <= 1'b0;
            transfer_accepted_q <= 1'b0;
            active_channel_q <= 3'd0;
            dma_transfer_complete <= 1'b0;
            dma_terminal_count <= 1'b0;
            protocol_error <= 1'b0;
            for (i = 0; i < 8; i = i + 1) begin
                base_address_q[i] <= 16'h0000;
                current_address_q[i] <= 16'h0000;
                base_count_q[i] <= 16'h0000;
                current_count_q[i] <= 16'h0000;
                page_q[i] <= 8'h00;
                mode_q[i] <= 8'h00;
            end
        end else begin
            dma_transfer_complete <= 1'b0;
            dma_terminal_count <= 1'b0;

            for (i = 0; i < 8; i = i + 1)
                if (!dma_request[i])
                    single_block_q[i] <= 1'b0;

            if (io_state_q == IO_DONE)
                io_state_q <= IO_IDLE;

            if (request_accept) begin
                io_state_q <= IO_DONE;
                io_byte_enable_q <= request_byte_enable;
                io_read_data_valid_q <= !request_write;

                if (!request_write) begin
                    if (page_port_valid)
                        io_read_data_q <= page_q[config_channel];
                    else if (address_port_valid)
                        io_read_data_q <= byte_pointer_q[(dma2_bank ? 1 : 0)] ?
                            current_address_q[config_channel][15:8] :
                            current_address_q[config_channel][7:0];
                    else if (count_port_valid)
                        io_read_data_q <= byte_pointer_q[(dma2_bank ? 1 : 0)] ?
                            current_count_q[config_channel][15:8] :
                            current_count_q[config_channel][7:0];
                    else if ((request_address[15:0] == 16'h0008) ||
                             (request_address[15:0] == 16'h00D0))
                        io_read_data_q <= {dma_terminal_count,
                                            dma_request_state[6:0]};
                    else if ((request_address[15:0] == 16'h000A) ||
                             (request_address[15:0] == 16'h00D4))
                        io_read_data_q <= mask_q;
                    else
                        io_read_data_q <= 8'h00;
                end else begin
                    io_read_data_q <= 8'h00;

                    if (page_port_valid)
                        page_q[config_channel] <= config_byte;
                    else if (address_port_valid) begin
                        if (!byte_pointer_q[(dma2_bank ? 1 : 0)]) begin
                            base_address_q[config_channel][7:0] <= config_byte;
                            current_address_q[config_channel][7:0] <= config_byte;
                        end else begin
                            base_address_q[config_channel][15:8] <= config_byte;
                            current_address_q[config_channel][15:8] <= config_byte;
                        end
                        byte_pointer_q[(dma2_bank ? 1 : 0)] <=
                            ~byte_pointer_q[(dma2_bank ? 1 : 0)];
                    end else if (count_port_valid) begin
                        if (!byte_pointer_q[(dma2_bank ? 1 : 0)]) begin
                            base_count_q[config_channel][7:0] <= config_byte;
                            current_count_q[config_channel][7:0] <= config_byte;
                        end else begin
                            base_count_q[config_channel][15:8] <= config_byte;
                            current_count_q[config_channel][15:8] <= config_byte;
                        end
                        byte_pointer_q[(dma2_bank ? 1 : 0)] <=
                            ~byte_pointer_q[(dma2_bank ? 1 : 0)];
                    end else if ((request_address[15:0] == 16'h000C) ||
                                 (request_address[15:0] == 16'h00D8)) begin
                        byte_pointer_q[(dma2_bank ? 1 : 0)] <= 1'b0;
                    end else if ((request_address[15:0] == 16'h000D) ||
                                 (request_address[15:0] == 16'h00DA)) begin
                        mask_q <= 8'hFF;
                        software_request_q <= 8'h00;
                    end else if ((request_address[15:0] == 16'h000E) ||
                                 (request_address[15:0] == 16'h00DC)) begin
                        mask_q <= 8'h00;
                    end else if ((request_address[15:0] == 16'h000F) ||
                                 (request_address[15:0] == 16'h00DE)) begin
                        mask_q <= config_byte;
                    end else if ((request_address[15:0] == 16'h000A) ||
                                 (request_address[15:0] == 16'h00D4)) begin
                        mask_q[config_byte[1:0] + (dma2_bank ? 4 : 0)] <=
                            config_byte[2];
                    end else if ((request_address[15:0] == 16'h000B) ||
                                 (request_address[15:0] == 16'h00D6)) begin
                        mode_q[config_byte[1:0] + (dma2_bank ? 4 : 0)] <=
                            config_byte;
                    end else if ((request_address[15:0] == 16'h0009) ||
                                 (request_address[15:0] == 16'h00D2)) begin
                        software_request_q[config_byte[1:0] +
                                           (dma2_bank ? 4 : 0)] <= config_byte[2];
                    end
                end
            end

            if (transfer_active_q) begin
                if (!transfer_accepted_q && transfer_accept)
                    transfer_accepted_q <= 1'b1;
                else if (transfer_accepted_q && transfer_ready) begin
                    transfer_accepted_q <= 1'b0;
                    dma_transfer_complete <= 1'b1;

                    if (current_count_q[active_channel_q] == 16'h0000) begin
                        dma_terminal_count <= 1'b1;
                        software_request_q[active_channel_q] <= 1'b0;
                        if (mode_q[active_channel_q][4]) begin
                            current_address_q[active_channel_q] <=
                                base_address_q[active_channel_q];
                            current_count_q[active_channel_q] <=
                                base_count_q[active_channel_q];
                        end else begin
                            mask_q[active_channel_q] <= 1'b1;
                        end
                    end else begin
                        current_count_q[active_channel_q] <=
                            current_count_q[active_channel_q] - 16'h0001;
                        if (mode_q[active_channel_q][5])
                            current_address_q[active_channel_q] <=
                                current_address_q[active_channel_q] - 16'h0001;
                        else
                            current_address_q[active_channel_q] <=
                                current_address_q[active_channel_q] + 16'h0001;
                    end

                    if (mode_q[active_channel_q][7:6] == 2'b01)
                        single_block_q[active_channel_q] <= 1'b1;
                    transfer_active_q <= 1'b0;
                end
            end else if (!completion_block && selected_channel_valid && dma_grant) begin
                transfer_active_q <= 1'b1;
                transfer_accepted_q <= 1'b0;
                active_channel_q <= selected_channel;
            end

            if (request_valid && config_port_valid && !config_lane_valid)
                protocol_error <= 1'b1;
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset) begin
            assert (!(dma_transfer_complete && dma_transfer_valid))
                else $error("AT DMA completed while retaining a transfer beat");
            assert (!(request_accept && !config_lane_valid))
                else $error("AT DMA accepted an invalid byte lane");
        end
    end
`endif
endmodule
