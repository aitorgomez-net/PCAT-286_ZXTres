// Functional AT interrupt subsystem boundary.
//
// The interrupt state machine is provided by the imported KF8259 blocks.  This
// wrapper supplies the AT port map, routes slave IRQs through master IRQ2 and
// converts the normalized AT command record into one-shot 8259 bus strobes.
// INTA is intentionally kept as two independently accepted transactions;
// only the second transaction is allowed to return data to the CPU bridge.
`timescale 1ns/1ps

module spk286_at_pic (
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
    localparam logic [1:0] TRANSACTION_IDLE   = 2'd0;
    localparam logic [1:0] TRANSACTION_ACTIVE = 2'd1;
    localparam logic [1:0] TRANSACTION_DONE   = 2'd2;

    logic [1:0] transaction_state_q;
    logic       transaction_is_io_q;
    logic       transaction_is_inta_q;
    logic       transaction_write_q;
    logic       transaction_master_q;
    logic       transaction_slave_q;
    logic       transaction_address_q;
    logic [1:0] transaction_byte_enable_q;
    logic [7:0] transaction_write_data_q;

    // inta_index_q is the externally visible pair sequencing state: zero is
    // the first acknowledge beat and one is the second vector beat.
    logic       inta_index_q;
    logic [2:0] cascade_id_q;
    logic [7:0] read_data_q;
    logic       read_data_valid_q;

    logic       pic_port_candidate;
    logic       pic_port_valid;
    logic       inta_request_valid;
    logic       target_request_valid;
    logic       selected_write_lane_valid;

    logic [7:0] master_irq_request;
    logic       master_interrupt;
    logic       slave_interrupt;

    logic [7:0] master_data_bus_out;
    logic       master_data_bus_io;
    logic [7:0] slave_data_bus_out;
    logic       slave_data_bus_io;
    logic [2:0] master_cascade_out;
    logic [2:0] slave_cascade_out;
    logic       master_cascade_io;
    logic       slave_cascade_io;
    logic       master_buffer_enable;
    logic       slave_buffer_enable;
    logic       master_slave_program_or_enable_buffer;
    logic       slave_slave_program_or_enable_buffer;

    logic       master_chip_select_n;
    logic       master_read_enable_n;
    logic       master_write_enable_n;
    logic       slave_chip_select_n;
    logic       slave_read_enable_n;
    logic       slave_write_enable_n;
    logic       master_interrupt_acknowledge_n;
    logic       slave_interrupt_acknowledge_n;

    always_comb begin
        pic_port_candidate = request_valid && request_command_valid &&
                             request_io &&
                             ((request_address[15:0] == 16'h0020) ||
                              (request_address[15:0] == 16'h0021) ||
                              (request_address[15:0] == 16'h00A0) ||
                              (request_address[15:0] == 16'h00A1));

        // An 8-bit AT peripheral is selected on the lane matching its port
        // address.  A word request is serialized by spk286_at_bus_bridge.
        selected_write_lane_valid =
            ((request_address[0] == 1'b0) &&
             (request_byte_enable == 2'b01)) ||
            ((request_address[0] == 1'b1) &&
             (request_byte_enable == 2'b10));
        pic_port_valid = pic_port_candidate && selected_write_lane_valid;

        // INTA has no ordinary A0/BHE lane.  The bridge represents it with a
        // zero byte-enable field and never writes during acknowledgement.
        inta_request_valid = request_valid && request_command_valid &&
                             request_inta && !request_write &&
                             (request_byte_enable == 2'b00);
        target_request_valid = pic_port_valid || inta_request_valid;
    end

    assign request_accept = (transaction_state_q == TRANSACTION_IDLE) &&
                            target_request_valid;
    assign request_ready = (transaction_state_q == TRANSACTION_DONE);
    assign request_read_data_valid = request_ready && read_data_valid_q;
    assign request_read_data = transaction_byte_enable_q[1] ?
                               {read_data_q, 8'h00} :
                               {8'h00, read_data_q};

    assign inta_sequence_active = (transaction_state_q != TRANSACTION_IDLE) &&
                                  (transaction_is_inta_q || inta_index_q);
    assign inta_first_active = inta_sequence_active &&
                               transaction_is_inta_q && !inta_index_q;
    assign inta_second_active = inta_sequence_active &&
                                transaction_is_inta_q && inta_index_q;

    assign intr = master_interrupt;
    assign slave_intr = slave_interrupt;

    // Slave IRQ8..IRQ15 are presented to the master through IRQ2.  A direct
    // IRQ2 input is retained as a diagnostic-friendly wired-OR source.
    always_comb begin
        master_irq_request = irq_request[7:0];
        master_irq_request[2] = irq_request[2] | slave_interrupt;
    end

    // The imported KF8259 bus control logic expects an active-low select and
    // a one-cycle low write/read strobe.  ACTIVE is exactly that one-cycle
    // envelope; DONE is the READY/completion interval seen by the normalized
    // consumer.
    always_comb begin
        master_chip_select_n = 1'b1;
        master_read_enable_n = 1'b1;
        master_write_enable_n = 1'b1;
        slave_chip_select_n = 1'b1;
        slave_read_enable_n = 1'b1;
        slave_write_enable_n = 1'b1;

        if ((transaction_state_q == TRANSACTION_ACTIVE) &&
            transaction_is_io_q) begin
            if (transaction_master_q) begin
                master_chip_select_n = 1'b0;
                master_read_enable_n = transaction_write_q;
                master_write_enable_n = !transaction_write_q;
            end
            if (transaction_slave_q) begin
                slave_chip_select_n = 1'b0;
                slave_read_enable_n = transaction_write_q;
                slave_write_enable_n = !transaction_write_q;
            end
        end
    end

    // Both devices observe both INTA strobes.  The master's ACK1 cascade ID
    // is captured between transactions and presented to the slave below;
    // only the selected slave drives the second acknowledge data beat.
    assign master_interrupt_acknowledge_n =
        !((transaction_state_q == TRANSACTION_ACTIVE) &&
          transaction_is_inta_q);
    assign slave_interrupt_acknowledge_n = master_interrupt_acknowledge_n;

    KF8259 u_master_pic (
        .clock                              (clk),
        .reset                              (reset),
        .chip_select_n                      (master_chip_select_n),
        .read_enable_n                      (master_read_enable_n),
        .write_enable_n                     (master_write_enable_n),
        .address                            (transaction_address_q),
        .data_bus_in                        (transaction_write_data_q),
        .data_bus_out                       (master_data_bus_out),
        .data_bus_io                        (master_data_bus_io),
        .cascade_in                         (3'b000),
        .cascade_out                        (master_cascade_out),
        .cascade_io                         (master_cascade_io),
        .slave_program_n                    (1'b1),
        .buffer_enable                      (master_buffer_enable),
        .slave_program_or_enable_buffer     (master_slave_program_or_enable_buffer),
        .interrupt_acknowledge_n            (master_interrupt_acknowledge_n),
        .interrupt_to_cpu                   (master_interrupt),
        .interrupt_request                  (master_irq_request)
    );

    KF8259 u_slave_pic (
        .clock                              (clk),
        .reset                              (reset),
        .chip_select_n                      (slave_chip_select_n),
        .read_enable_n                      (slave_read_enable_n),
        .write_enable_n                     (slave_write_enable_n),
        .address                            (transaction_address_q),
        .data_bus_in                        (transaction_write_data_q),
        .data_bus_out                       (slave_data_bus_out),
        .data_bus_io                        (slave_data_bus_io),
        // Register the master's ACK1 slave ID before the second normalized
        // transaction.  This preserves the KF8259 cascade protocol while
        // avoiding an unstable combinational cascade path.
        .cascade_in                         (cascade_id_q),
        .cascade_out                        (slave_cascade_out),
        .cascade_io                         (slave_cascade_io),
        .slave_program_n                    (1'b0),
        .buffer_enable                      (slave_buffer_enable),
        .slave_program_or_enable_buffer     (slave_slave_program_or_enable_buffer),
        .interrupt_acknowledge_n            (slave_interrupt_acknowledge_n),
        .interrupt_to_cpu                   (slave_interrupt),
        .interrupt_request                  (irq_request[15:8])
    );

    always_ff @(posedge clk) begin
        if (reset) begin
            transaction_state_q <= TRANSACTION_IDLE;
            transaction_is_io_q <= 1'b0;
            transaction_is_inta_q <= 1'b0;
            transaction_write_q <= 1'b0;
            transaction_master_q <= 1'b0;
            transaction_slave_q <= 1'b0;
            transaction_address_q <= 1'b0;
            transaction_byte_enable_q <= 2'b00;
            transaction_write_data_q <= 8'h00;
            inta_index_q <= 1'b0;
            read_data_q <= 8'h00;
            read_data_valid_q <= 1'b0;
            cascade_id_q <= 3'b000;
            protocol_error <= 1'b0;
        end else begin
            case (transaction_state_q)
                TRANSACTION_IDLE: begin
                    read_data_valid_q <= 1'b0;
                    if (request_accept) begin
                        transaction_state_q <= TRANSACTION_ACTIVE;
                        transaction_is_io_q <= pic_port_valid;
                        transaction_is_inta_q <= inta_request_valid;
                        transaction_write_q <= request_write;
                        transaction_master_q <=
                            (request_address[15:0] == 16'h0020) ||
                            (request_address[15:0] == 16'h0021);
                        transaction_slave_q <=
                            (request_address[15:0] == 16'h00A0) ||
                            (request_address[15:0] == 16'h00A1);
                        transaction_address_q <= request_address[0];
                        transaction_byte_enable_q <= request_byte_enable;
                        transaction_write_data_q <= request_byte_enable[1] ?
                                                    request_data_out[15:8] :
                                                    request_data_out[7:0];
                    end

                    if (pic_port_candidate && !selected_write_lane_valid)
                        protocol_error <= 1'b1;
                    if (request_inta &&
                        (request_write || (request_byte_enable != 2'b00)))
                        protocol_error <= 1'b1;
                end

                TRANSACTION_ACTIVE: begin
                    transaction_state_q <= TRANSACTION_DONE;
                    if (transaction_is_io_q && !transaction_write_q) begin
                        if (transaction_master_q) begin
                            read_data_q <= master_data_bus_out;
                            read_data_valid_q <= !master_data_bus_io;
                        end else if (transaction_slave_q) begin
                            read_data_q <= slave_data_bus_out;
                            read_data_valid_q <= !slave_data_bus_io;
                        end
                    end else if (transaction_is_inta_q) begin
                        // KF8259 owns the vector.  Suppress its first-ACK
                        // bus value and expose only the second-ACK byte.
                        if (inta_index_q) begin
                            if (!master_data_bus_io) begin
                                read_data_q <= master_data_bus_out;
                                read_data_valid_q <= 1'b1;
                            end else if (!slave_data_bus_io) begin
                                read_data_q <= slave_data_bus_out;
                                read_data_valid_q <= 1'b1;
                            end else begin
                                read_data_q <= 8'h00;
                                read_data_valid_q <= 1'b0;
                            end
                        end else begin
                            read_data_q <= 8'h00;
                            read_data_valid_q <= 1'b0;
                        end

                        inta_index_q <= ~inta_index_q;
                    end
                end

                TRANSACTION_DONE: begin
                    if (transaction_is_inta_q && inta_index_q)
                        cascade_id_q <= master_cascade_out;
                    transaction_state_q <= TRANSACTION_IDLE;
                end

                default: begin
                    transaction_state_q <= TRANSACTION_IDLE;
                    inta_index_q <= 1'b0;
                    protocol_error <= 1'b1;
                end
            endcase
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset) begin
            assert (!(request_accept && !target_request_valid))
                else $error("AT PIC accepted an unselected request");
            assert (!(request_read_data_valid && !request_ready))
                else $error("AT PIC returned data outside READY");
            assert (!(inta_first_active && inta_second_active))
                else $error("AT PIC exposed both INTA beats");
        end
    end
`endif
endmodule
