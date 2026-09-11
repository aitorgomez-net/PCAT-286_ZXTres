// Portable PIC model used only by the fast whole-CPU composition test.
// The production spk286_at_machine path instantiates spk286_at_pic and the
// imported cascaded KF8259 pair when AT_MACHINE_PIC_MODEL is not defined.
`timescale 1ns/1ps

module spk286_at_machine_pic_model (
    input  logic         clk,
    input  logic         reset,
    input  logic         request_valid,
    input  logic         request_command_valid,
    input  logic         request_write,
    input  logic         request_io,
    input  logic         request_inta,
    input  logic [23:0]  request_address,
    input  logic [1:0]   request_byte_enable,
    input  logic [15:0]  request_data_out,
    input  logic [15:0]  irq_request,
    output logic         intr,
    output logic         slave_intr,
    output logic         request_accept,
    output logic         request_ready,
    output logic [15:0]  request_read_data,
    output logic         request_read_data_valid,
    output logic         inta_sequence_active,
    output logic         inta_first_active,
    output logic         inta_second_active,
    output logic         protocol_error
);
    localparam logic [1:0] STATE_IDLE = 2'd0;
    localparam logic [1:0] STATE_ACTIVE = 2'd1;
    localparam logic [1:0] STATE_DONE = 2'd2;

    logic [1:0] state_q;
    logic       inta_q;
    logic       inta_second_q;
    logic       write_q;
    logic       read_data_valid_q;
    logic [1:0] lane_q;
    logic [15:0] address_q;
    logic [7:0] write_data_q;
    logic [7:0] read_data_q;
    logic [7:0] vector_base_q;
    logic [7:0] interrupt_mask_q;
    logic [1:0] init_step_q;
    logic       previous_irq0_q;
    logic       irq_pending_q;

    logic pic_port_candidate;
    logic lane_valid;
    logic target_valid;
    logic [7:0] request_byte;

    always_comb begin
        pic_port_candidate = request_valid && request_command_valid &&
                             request_io &&
                             ((request_address[15:0] == 16'h0020) ||
                              (request_address[15:0] == 16'h0021) ||
                              (request_address[15:0] == 16'h00A0) ||
                              (request_address[15:0] == 16'h00A1));
        lane_valid = ((request_address[0] == 1'b0) &&
                      (request_byte_enable == 2'b01)) ||
                     ((request_address[0] == 1'b1) &&
                      (request_byte_enable == 2'b10));
        target_valid = (request_valid && request_command_valid &&
                        request_inta && !request_write &&
                        (request_byte_enable == 2'b00)) ||
                       (pic_port_candidate && lane_valid);
        request_byte = request_byte_enable[1] ? request_data_out[15:8] :
                       request_data_out[7:0];
    end

    assign request_accept = (state_q == STATE_IDLE) && target_valid;
    assign request_ready = (state_q == STATE_DONE);
    assign request_read_data = lane_q[1] ? {read_data_q, 8'h00} :
                               {8'h00, read_data_q};
    assign request_read_data_valid = request_ready && read_data_valid_q;
    assign inta_sequence_active = (state_q != STATE_IDLE) && inta_q;
    assign inta_first_active = inta_sequence_active && !inta_second_q;
    assign inta_second_active = inta_sequence_active && inta_second_q;
    assign intr = irq_pending_q;
    assign slave_intr = 1'b0;

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= STATE_IDLE;
            inta_q <= 1'b0;
            inta_second_q <= 1'b0;
            write_q <= 1'b0;
            read_data_valid_q <= 1'b0;
            lane_q <= 2'b00;
            address_q <= 16'h0000;
            write_data_q <= 8'h00;
            read_data_q <= 8'h00;
            vector_base_q <= 8'h08;
            interrupt_mask_q <= 8'hFF;
            init_step_q <= 2'd0;
            previous_irq0_q <= 1'b0;
            irq_pending_q <= 1'b0;
            protocol_error <= 1'b0;
        end else begin
            previous_irq0_q <= irq_request[0];
            if (irq_request[0] && !previous_irq0_q && !interrupt_mask_q[0])
                irq_pending_q <= 1'b1;

            if (state_q == STATE_DONE)
                state_q <= STATE_IDLE;

            if (request_accept) begin
                state_q <= STATE_ACTIVE;
                inta_q <= request_inta;
                write_q <= request_write;
                lane_q <= request_byte_enable;
                address_q <= request_address[15:0];
                write_data_q <= request_byte;
                read_data_valid_q <= 1'b0;
            end

            if (state_q == STATE_ACTIVE) begin
                state_q <= STATE_DONE;
                if (inta_q) begin
                    if (inta_second_q) begin
                        read_data_q <= vector_base_q;
                        read_data_valid_q <= 1'b1;
                        irq_pending_q <= 1'b0;
                    end else begin
                        read_data_q <= 8'h00;
                        read_data_valid_q <= 1'b0;
                    end
                    inta_second_q <= ~inta_second_q;
                end else if (!write_q) begin
                    read_data_q <= (address_q == 16'h0021) ?
                                   interrupt_mask_q : 8'h00;
                    read_data_valid_q <= 1'b1;
                end else if (address_q == 16'h0020) begin
                    if (write_data_q[4]) begin
                        init_step_q <= 2'd1;
                        interrupt_mask_q <= 8'hFF;
                    end
                end else if ((address_q == 16'h0021) &&
                             (init_step_q == 2'd1)) begin
                    vector_base_q <= {write_data_q[7:3], 3'b000};
                    init_step_q <= 2'd2;
                end else if (address_q == 16'h0021) begin
                    interrupt_mask_q <= write_data_q;
                    init_step_q <= 2'd0;
                end
            end

            if (pic_port_candidate && !lane_valid)
                protocol_error <= 1'b1;
            if (request_inta && (request_write ||
                                 (request_byte_enable != 2'b00)))
                protocol_error <= 1'b1;
        end
    end
endmodule
