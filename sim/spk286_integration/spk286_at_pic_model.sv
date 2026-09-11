// Portable A3 reference model used only by the Icarus run.
//
// The production spk286_at_pic wrapper instantiates the imported KF8259 pair
// and is exercised by the Verilator run.  Icarus cannot complete a cascaded
// KF8259 INTA delta cycle reliably, so this small model keeps the same
// normalized boundary and acceptance assertions available to the portable
// simulator.  It models the AT programming sequence, masks, IRQ2 cascade and
// two-beat INTA contract; it is not a replacement for the production PIC.
`timescale 1ns/1ps

module spk286_at_pic_model (
    input  logic        clk,
    input  logic        reset,
    input  logic        request_valid,
    input  logic        request_command_valid,
    input  logic        request_write,
    input  logic        request_io,
    input  logic        request_inta,
    input  logic [23:0] request_address,
    input  logic [1:0]  request_byte_enable,
    input  logic [15:0] request_data_out,
    input  logic [15:0] irq_request,
    output logic        intr,
    output logic        slave_intr,
    output logic        request_accept,
    output logic        request_ready,
    output logic [15:0] request_read_data,
    output logic        request_read_data_valid,
    output logic        inta_sequence_active,
    output logic        inta_first_active,
    output logic        inta_second_active,
    output logic        protocol_error
);
    localparam logic [1:0] STATE_IDLE   = 2'd0;
    localparam logic [1:0] STATE_ACTIVE = 2'd1;
    localparam logic [1:0] STATE_DONE   = 2'd2;

    logic [1:0] state_q;
    logic       transaction_is_io_q;
    logic       transaction_is_inta_q;
    logic       transaction_write_q;
    logic       transaction_master_q;
    logic       transaction_slave_q;
    logic [1:0] transaction_byte_enable_q;
    logic [7:0] transaction_write_data_q;
    logic [7:0] read_data_q;
    logic       read_data_valid_q;

    logic [7:0] master_base_q;
    logic [7:0] slave_base_q;
    logic [7:0] master_mask_q;
    logic [7:0] slave_mask_q;
    logic [1:0] master_icw_step_q;
    logic [1:0] slave_icw_step_q;
    logic [7:0] master_pending_q;
    logic [7:0] slave_pending_q;
    logic [15:0] previous_irq_q;
    logic       inta_index_q;
    logic [7:0] inta_vector_q;

    logic       port_candidate;
    logic       selected_lane_valid;
    logic       port_valid;
    logic       inta_valid;

    function automatic [2:0] first_level(input logic [7:0] value);
        integer level;
        begin
            first_level = 3'd7;
            for (level = 0; level < 8; level = level + 1)
                if (value[level] && (first_level == 3'd7))
                    first_level = level[2:0];
        end
    endfunction

    always_comb begin
        port_candidate = request_valid && request_command_valid &&
                         request_io &&
                         ((request_address[15:0] == 16'h0020) ||
                          (request_address[15:0] == 16'h0021) ||
                          (request_address[15:0] == 16'h00A0) ||
                          (request_address[15:0] == 16'h00A1));
        selected_lane_valid =
            ((request_address[0] == 1'b0) &&
             (request_byte_enable == 2'b01)) ||
            ((request_address[0] == 1'b1) &&
             (request_byte_enable == 2'b10));
        port_valid = port_candidate && selected_lane_valid;
        inta_valid = request_valid && request_command_valid &&
                     request_inta && !request_write &&
                     (request_byte_enable == 2'b00);
    end

    assign request_accept = (state_q == STATE_IDLE) &&
                            (port_valid || inta_valid);
    assign request_ready = (state_q == STATE_DONE);
    assign request_read_data = transaction_byte_enable_q[1] ?
                               {read_data_q, 8'h00} :
                               {8'h00, read_data_q};
    assign request_read_data_valid = request_ready && read_data_valid_q;

    assign slave_intr = (slave_pending_q & ~slave_mask_q) != 8'h00;
    assign intr = ((master_pending_q & ~master_mask_q) != 8'h00) ||
                  (!master_mask_q[2] && slave_intr);
    assign inta_sequence_active = (state_q != STATE_IDLE) &&
                                  (transaction_is_inta_q || inta_index_q);
    assign inta_first_active = inta_sequence_active &&
                               transaction_is_inta_q && !inta_index_q;
    assign inta_second_active = inta_sequence_active &&
                                transaction_is_inta_q && inta_index_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= STATE_IDLE;
            transaction_is_io_q <= 1'b0;
            transaction_is_inta_q <= 1'b0;
            transaction_write_q <= 1'b0;
            transaction_master_q <= 1'b0;
            transaction_slave_q <= 1'b0;
            transaction_byte_enable_q <= 2'b00;
            transaction_write_data_q <= 8'h00;
            read_data_q <= 8'h00;
            read_data_valid_q <= 1'b0;
            master_base_q <= 8'h08;
            slave_base_q <= 8'h70;
            master_mask_q <= 8'hFF;
            slave_mask_q <= 8'hFF;
            master_icw_step_q <= 2'd0;
            slave_icw_step_q <= 2'd0;
            master_pending_q <= 8'h00;
            slave_pending_q <= 8'h00;
            previous_irq_q <= 16'h0000;
            inta_index_q <= 1'b0;
            inta_vector_q <= 8'h27;
            protocol_error <= 1'b0;
        end else begin
            // The source boundary is edge-qualified like the portable
            // KF8259 tests: a low-to-high request pulse creates IRR state.
            if (irq_request[7:0] & ~previous_irq_q[7:0])
                master_pending_q <= master_pending_q |
                                    (irq_request[7:0] & ~previous_irq_q[7:0]);
            if (irq_request[15:8] & ~previous_irq_q[15:8])
                slave_pending_q <= slave_pending_q |
                                   (irq_request[15:8] & ~previous_irq_q[15:8]);
            previous_irq_q <= irq_request;

            case (state_q)
                STATE_IDLE: begin
                    read_data_valid_q <= 1'b0;
                    if (request_accept) begin
                        state_q <= STATE_ACTIVE;
                        transaction_is_io_q <= port_valid;
                        transaction_is_inta_q <= inta_valid;
                        transaction_write_q <= request_write;
                        transaction_master_q <=
                            (request_address[15:0] == 16'h0020) ||
                            (request_address[15:0] == 16'h0021);
                        transaction_slave_q <=
                            (request_address[15:0] == 16'h00A0) ||
                            (request_address[15:0] == 16'h00A1);
                        transaction_byte_enable_q <= request_byte_enable;
                        transaction_write_data_q <= request_byte_enable[1] ?
                                                    request_data_out[15:8] :
                                                    request_data_out[7:0];

                        if (port_valid && request_write) begin
                            if (((request_address[15:0] == 16'h0020) ||
                                 (request_address[15:0] == 16'h0021)) &&
                                (request_address[0] == 1'b0)) begin
                                if (request_data_out[4])
                                    master_icw_step_q <= 2'd1;
                                else if (request_data_out[7:0] == 8'h20)
                                    master_pending_q <= master_pending_q;
                            end else if ((request_address[15:0] == 16'h0021)) begin
                                case (master_icw_step_q)
                                    2'd1: begin
                                        master_base_q <= request_data_out[15:8];
                                        master_icw_step_q <= 2'd2;
                                    end
                                    2'd2: master_icw_step_q <= 2'd3;
                                    2'd3: master_icw_step_q <= 2'd0;
                                    default: master_mask_q <= request_data_out[15:8];
                                endcase
                            end else if (((request_address[15:0] == 16'h00A0) ||
                                          (request_address[15:0] == 16'h00A1)) &&
                                         (request_address[0] == 1'b0)) begin
                                if (request_data_out[12])
                                    slave_icw_step_q <= 2'd1;
                                else if (request_data_out[15:8] == 8'h20)
                                    slave_pending_q <= slave_pending_q;
                            end else if (request_address[15:0] == 16'h00A1) begin
                                case (slave_icw_step_q)
                                    2'd1: begin
                                        slave_base_q <= request_data_out[15:8];
                                        slave_icw_step_q <= 2'd2;
                                    end
                                    2'd2: slave_icw_step_q <= 2'd3;
                                    2'd3: slave_icw_step_q <= 2'd0;
                                    default: slave_mask_q <= request_data_out[15:8];
                                endcase
                            end
                        end else if (port_valid && !request_write) begin
                            if ((request_address[15:0] == 16'h0020) ||
                                (request_address[15:0] == 16'h0021))
                                read_data_q <= master_mask_q;
                            else
                                read_data_q <= slave_mask_q;
                        end else if (inta_valid && !inta_index_q) begin
                            if (!master_mask_q[2] && slave_intr) begin
                                inta_vector_q <= slave_base_q +
                                    {5'b00000, first_level(slave_pending_q &
                                                               ~slave_mask_q)};
                                slave_pending_q <= slave_pending_q &
                                    ~(8'b00000001 << first_level(slave_pending_q &
                                                                   ~slave_mask_q));
                            end else if ((master_pending_q & ~master_mask_q) != 0) begin
                                inta_vector_q <= master_base_q +
                                    {5'b00000, first_level(master_pending_q &
                                                               ~master_mask_q)};
                                master_pending_q <= master_pending_q &
                                    ~(8'b00000001 << first_level(master_pending_q &
                                                                  ~master_mask_q));
                            end else begin
                                inta_vector_q <= 8'h27;
                            end
                        end
                    end
                end

                STATE_ACTIVE: begin
                    state_q <= STATE_DONE;
                    if (transaction_is_io_q && !transaction_write_q)
                        read_data_valid_q <= 1'b1;
                    else if (transaction_is_inta_q) begin
                        read_data_q <= inta_vector_q;
                        read_data_valid_q <= inta_index_q;
                        inta_index_q <= ~inta_index_q;
                    end
                end

                STATE_DONE:
                    state_q <= STATE_IDLE;

                default: begin
                    state_q <= STATE_IDLE;
                    inta_index_q <= 1'b0;
                    protocol_error <= 1'b1;
                end
            endcase

            if (request_inta &&
                (request_write || (request_byte_enable != 2'b00)))
                protocol_error <= 1'b1;
        end
    end
endmodule
