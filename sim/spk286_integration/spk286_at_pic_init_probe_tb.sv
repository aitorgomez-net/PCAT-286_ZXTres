`timescale 1ns/1ps

// Small probe for the exact five-write PIC initialization used by the
// AT-capable Sergey source. It intentionally stops before interrupt delivery
// so a stalled command sequence is easy to identify.
module spk286_at_pic_init_probe_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    logic request_valid = 1'b0;
    logic request_command_valid = 1'b0;
    logic request_write = 1'b0;
    logic request_io = 1'b0;
    logic request_inta = 1'b0;
    logic [23:0] request_address = 24'h0;
    logic [1:0] request_byte_enable = 2'b00;
    logic [15:0] request_data_out = 16'h0;
    logic [15:0] irq_request = 16'h0;
    wire request_accept, request_ready, request_read_data_valid;
    wire [15:0] request_read_data;
    wire intr, slave_intr, inta_sequence_active, inta_first_active,
         inta_second_active, protocol_error;

    always #5 clk = ~clk;

    spk286_at_pic dut (
        .clk                         (clk),
        .reset                       (reset),
        .request_valid               (request_valid),
        .request_command_valid       (request_command_valid),
        .request_write               (request_write),
        .request_io                  (request_io),
        .request_inta                (request_inta),
        .request_address             (request_address),
        .request_byte_enable         (request_byte_enable),
        .request_data_out            (request_data_out),
        .irq_request                 (irq_request),
        .intr                         (intr),
        .slave_intr                   (slave_intr),
        .request_accept               (request_accept),
        .request_ready                (request_ready),
        .request_read_data            (request_read_data),
        .request_read_data_valid      (request_read_data_valid),
        .inta_sequence_active         (inta_sequence_active),
        .inta_first_active            (inta_first_active),
        .inta_second_active           (inta_second_active),
        .protocol_error               (protocol_error)
    );

    task automatic write_pic(input logic [15:0] port,
                             input logic [7:0] value);
        integer cycles;
        begin
            @(negedge clk);
            request_valid = 1'b1;
            request_command_valid = 1'b1;
            request_write = 1'b1;
            request_io = 1'b1;
            request_address = {8'h00, port};
            request_byte_enable = port[0] ? 2'b10 : 2'b01;
            request_data_out = port[0] ? {value, 8'h00} : {8'h00, value};
            #1;
            if (!request_accept)
                $fatal(1, "PIC write not accepted port=%h", port);
            @(negedge clk);
            request_command_valid = 1'b0;
            cycles = 0;
            while (!request_ready && cycles < 16) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!request_ready)
                $fatal(1, "PIC write did not complete port=%h", port);
            request_valid = 1'b0;
            request_io = 1'b0;
            request_data_out = 16'h0;
            request_byte_enable = 2'b00;
            @(negedge clk);
        end
    endtask

    task automatic send_inta(input logic expected_valid,
                             input logic [7:0] expected_vector);
        integer cycles;
        begin
            @(negedge clk);
            request_valid = 1'b1;
            request_command_valid = 1'b1;
            request_write = 1'b0;
            request_io = 1'b0;
            request_inta = 1'b1;
            request_address = 24'h0;
            request_byte_enable = 2'b00;
            request_data_out = 16'h0;
            #1;
            $display("INTA_REQUEST accept=%b state=%0d idx=%b", request_accept,
                     dut.transaction_state_q, dut.inta_index_q);
            if (!request_accept)
                $fatal(1, "INTA was not accepted");
            @(negedge clk);
            request_command_valid = 1'b0;
            cycles = 0;
            while (!request_ready && cycles < 16) begin
                $display("INTA_WAIT cycle=%0d state=%0d idx=%b ack=%b/%b ready=%b",
                         cycles, dut.transaction_state_q, dut.inta_index_q,
                         dut.master_interrupt_acknowledge_n,
                         dut.slave_interrupt_acknowledge_n, request_ready);
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!request_ready)
                $fatal(1, "INTA did not complete");
            if (request_read_data_valid !== expected_valid)
                $fatal(1, "INTA data-valid mismatch got=%b expected=%b",
                       request_read_data_valid, expected_valid);
            if (expected_valid && request_read_data[7:0] !== expected_vector)
                $fatal(1, "INTA vector mismatch got=%h expected=%h",
                       request_read_data[7:0], expected_vector);
            request_valid = 1'b0;
            request_inta = 1'b0;
            @(negedge clk);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        reset = 1'b0;
        write_pic(16'h0020, 8'h11);
        write_pic(16'h00A0, 8'h11);
        write_pic(16'h0021, 8'h08);
        write_pic(16'h00A1, 8'h70);
        write_pic(16'h0021, 8'h04);
        write_pic(16'h00A1, 8'h02);
        write_pic(16'h0021, 8'h01);
        write_pic(16'h00A1, 8'h01);
        write_pic(16'h0021, 8'hB8);
        // Unmask IRQ14 explicitly for this probe. The BIOS leaves it masked
        // until the IDE option ROM enables its own IRQ line.
        write_pic(16'h00A1, 8'hBF);
        #1;
        if (protocol_error)
            $fatal(1, "PIC initialization reported protocol_error");
        irq_request = 16'h4000; // IRQ14, the AT IDE interrupt line.
        repeat (8) @(posedge clk);
        if (!intr || !slave_intr)
            $fatal(1, "AT IRQ14 did not reach the cascaded PICs");
        $display("IRQ14_ASSERTED state=%0d master=%0d slave=%0d",
                 dut.transaction_state_q,
                 dut.u_master_pic.u_Control_Logic.control_state,
                 dut.u_slave_pic.u_Control_Logic.control_state);
        send_inta(1'b0, 8'h00);
        send_inta(1'b1, 8'h76);
        irq_request = 16'h0000;
        write_pic(16'h00A0, 8'h20);
        write_pic(16'h0020, 8'h20);
        repeat (4) @(posedge clk);
        if (intr)
            $fatal(1, "AT IRQ14 EOI did not clear INTR");
        $display("AT_PIC_INIT_PROBE_PASS master_state=%0d slave_state=%0d irq14_vector=76 intr=%b",
                 dut.u_master_pic.u_Control_Logic.command_state,
                 dut.u_slave_pic.u_Control_Logic.command_state,
                 intr);
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "PIC initialization probe watchdog");
    end
endmodule
