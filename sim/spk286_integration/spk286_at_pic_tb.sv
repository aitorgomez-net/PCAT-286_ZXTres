`timescale 1ns/1ps

// A3 acceptance test for the production-compatible dual KF8259 boundary.
// It checks AT programming ports, IMR reads, master IRQ delivery, slave IRQ8
// cascade through master IRQ2 and the rule that only INTA beat two returns a
// vector byte.
module spk286_at_pic_tb;
    logic        clk = 1'b0;
    logic        reset = 1'b1;
    logic        request_valid = 1'b0;
    logic        request_command_valid = 1'b0;
    logic        request_write = 1'b0;
    logic        request_io = 1'b0;
    logic        request_inta = 1'b0;
    logic [23:0] request_address = 24'h0;
    logic [1:0]  request_byte_enable = 2'b00;
    logic [15:0] request_data_out = 16'h0;
    logic [15:0] irq_request = 16'h0;
    wire         intr;
    wire         slave_intr;
    wire         request_accept;
    wire         request_ready;
    wire [15:0]  request_read_data;
    wire         request_read_data_valid;
    wire         inta_sequence_active;
    wire         inta_first_active;
    wire         inta_second_active;
    wire         protocol_error;

    always #5 clk = ~clk;

`ifdef A3_PIC_MODEL
    spk286_at_pic_model dut (
`else
    spk286_at_pic dut (
`endif
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
        .intr                        (intr),
        .slave_intr                  (slave_intr),
        .request_accept              (request_accept),
        .request_ready               (request_ready),
        .request_read_data           (request_read_data),
        .request_read_data_valid     (request_read_data_valid),
        .inta_sequence_active        (inta_sequence_active),
        .inta_first_active           (inta_first_active),
        .inta_second_active          (inta_second_active),
        .protocol_error              (protocol_error)
    );

    task automatic clear_request;
        begin
            request_valid = 1'b0;
            request_command_valid = 1'b0;
            request_write = 1'b0;
            request_io = 1'b0;
            request_inta = 1'b0;
            request_address = 24'h0;
            request_byte_enable = 2'b00;
            request_data_out = 16'h0;
        end
    endtask

    task automatic wait_request_ready;
        integer cycles;
        logic found;
        begin
            found = 1'b0;
            for (cycles = 0; cycles < 12 && !found; cycles = cycles + 1) begin
                @(posedge clk);
                #1;
                if (request_ready) begin
                    found = 1'b1;
                end
            end
            if (!found)
                $fatal(1, "A3 PIC request did not complete");
        end
    endtask

    task automatic write_pic(input logic [15:0] port,
                             input logic [7:0] value);
        begin
            @(negedge clk);
            request_valid = 1'b1;
            request_command_valid = 1'b1;
            request_write = 1'b1;
            request_io = 1'b1;
            request_inta = 1'b0;
            request_address = {8'h00, port};
            request_byte_enable = port[0] ? 2'b10 : 2'b01;
            request_data_out = port[0] ? {value, 8'h00} : {8'h00, value};
            #1;
            if (!request_accept)
                $fatal(1, "A3 PIC write was not accepted port=%h", port);
            wait_request_ready();
            clear_request();
            @(posedge clk);
            #1;
        end
    endtask

    task automatic read_pic(input logic [15:0] port,
                            input logic [7:0] expected);
        begin
            @(negedge clk);
            request_valid = 1'b1;
            request_command_valid = 1'b1;
            request_write = 1'b0;
            request_io = 1'b1;
            request_inta = 1'b0;
            request_address = {8'h00, port};
            request_byte_enable = port[0] ? 2'b10 : 2'b01;
            request_data_out = 16'h0;
            #1;
            if (!request_accept)
                $fatal(1, "A3 PIC read was not accepted port=%h", port);
            wait_request_ready();
            if (!request_read_data_valid ||
                (port[0] ? request_read_data[15:8] :
                           request_read_data[7:0]) !== expected)
                $fatal(1, "A3 PIC read mismatch port=%h data=%h expected=%h valid=%b",
                       port, request_read_data, expected,
                       request_read_data_valid);
            clear_request();
            @(posedge clk);
            #1;
        end
    endtask

    task automatic send_inta(input logic expected_valid,
                             input logic [7:0] expected_vector);
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
            if (!request_accept)
                $fatal(1, "A3 INTA beat was not accepted");
            wait_request_ready();
            if (request_read_data_valid !== expected_valid)
                $fatal(1, "A3 INTA data-valid mismatch valid=%b expected=%b",
                       request_read_data_valid, expected_valid);
            if (expected_valid && request_read_data[7:0] !== expected_vector)
                $fatal(1, "A3 INTA vector mismatch vector=%h expected=%h",
                       request_read_data[7:0], expected_vector);
            clear_request();
            @(posedge clk);
            #1;
        end
    endtask

    task automatic wait_for_intr;
        integer cycles;
        logic found;
        begin
            found = 1'b0;
            for (cycles = 0; cycles < 24 && !found; cycles = cycles + 1) begin
                @(posedge clk);
                #1;
                if (intr) begin
                    found = 1'b1;
                end
            end
            if (!found)
                $fatal(1, "A3 PIC did not assert INTR");
        end
    endtask

    task automatic send_master_eoi;
        begin
            write_pic(16'h0020, 8'h20);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        reset = 1'b0;

        // Master: cascade mode, vector 08h, slave on IRQ2, 8086 mode,
        // unmask IRQ0 and IRQ2 only.
        write_pic(16'h0020, 8'h11);
        write_pic(16'h0021, 8'h08);
        write_pic(16'h0021, 8'h04);
        write_pic(16'h0021, 8'h01);
        write_pic(16'h0021, 8'hFA);

        // Slave: cascade identity 2, vector 70h, unmask IRQ8 only.
        write_pic(16'h00A0, 8'h11);
        write_pic(16'h00A1, 8'h70);
        write_pic(16'h00A1, 8'h02);
        write_pic(16'h00A1, 8'h01);
        write_pic(16'h00A1, 8'hFE);

        read_pic(16'h0021, 8'hFA);
        read_pic(16'h00A1, 8'hFE);

        // A masked master IRQ must not reach INTR.
        irq_request = 16'h0008;
        repeat (8) @(posedge clk);
        #1;
        if (intr)
            $fatal(1, "A3 masked IRQ3 reached INTR");
        irq_request = 16'h0000;

        // Master IRQ0: first INTA has no data, second returns base+0.
        irq_request = 16'h0001;
        wait_for_intr();
        send_inta(1'b0, 8'h00);
        send_inta(1'b1, 8'h08);
        irq_request = 16'h0000;
        send_master_eoi();
        repeat (3) @(posedge clk);
        #1;
        if (intr)
            $fatal(1, "A3 master EOI did not clear INTR");

        // Slave IRQ8 must assert both the slave output and master INTR and
        // return the programmed slave vector after the same two beats.
        irq_request = 16'h0100;
        wait_for_intr();
        if (!slave_intr)
            $fatal(1, "A3 slave IRQ did not reach the cascade boundary");
        send_inta(1'b0, 8'h00);
        send_inta(1'b1, 8'h70);
        irq_request = 16'h0000;
        write_pic(16'h00A0, 8'h20);
        send_master_eoi();
        repeat (3) @(posedge clk);
        #1;
        if (intr)
            $fatal(1, "A3 cascaded EOI did not clear INTR");

`ifndef A3_PIC_MODEL
        // A BIOS soft reboot can abandon IRQ1 without sending EOI. ICW1
        // must clear that service state without a board reset. Also cover
        // the slave, where both its ISR and master IRQ2 remain in service.
        write_pic(16'h0021, 8'hF9); // IRQ1 and IRQ2
        irq_request = 16'h0002;
        wait_for_intr();
        send_inta(1'b0, 8'h00);
        send_inta(1'b1, 8'h09);
        irq_request = 16'h0000;
        write_pic(16'h0020, 8'h0B); // read ISR
        read_pic(16'h0020, 8'h02);
        write_pic(16'h0020, 8'h11);
        write_pic(16'h0021, 8'h08);
        write_pic(16'h0021, 8'h04);
        write_pic(16'h0021, 8'h01);
        write_pic(16'h0020, 8'h0B);
        read_pic(16'h0020, 8'h00);
        write_pic(16'h0021, 8'hF9);
        irq_request = 16'h0002;
        wait_for_intr();
        send_inta(1'b0, 8'h00);
        send_inta(1'b1, 8'h09);
        irq_request = 16'h0000;
        send_master_eoi();
        repeat (8) @(posedge clk);
        irq_request = 16'h0100;
        wait_for_intr();
        send_inta(1'b0, 8'h00);
        send_inta(1'b1, 8'h70);
        irq_request = 16'h0000;
        write_pic(16'h0020, 8'h0B);
        write_pic(16'h00A0, 8'h0B);
        read_pic(16'h0020, 8'h04);
        read_pic(16'h00A0, 8'h01);
        write_pic(16'h0020, 8'h11);
        write_pic(16'h0021, 8'h08);
        write_pic(16'h0021, 8'h04);
        write_pic(16'h0021, 8'h01);
        write_pic(16'h00A0, 8'h11);
        write_pic(16'h00A1, 8'h70);
        write_pic(16'h00A1, 8'h02);
        write_pic(16'h00A1, 8'h01);
        write_pic(16'h0020, 8'h0B);
        write_pic(16'h00A0, 8'h0B);
        read_pic(16'h0020, 8'h00);
        read_pic(16'h00A0, 8'h00);
        write_pic(16'h0021, 8'hFB);
        write_pic(16'h00A1, 8'hFE);
        irq_request = 16'h0100;
        wait_for_intr();
        send_inta(1'b0, 8'h00);
        send_inta(1'b1, 8'h70);
        irq_request = 16'h0000;
        write_pic(16'h00A0, 8'h20);
        send_master_eoi();
        $display("A3_AT_PIC_REINIT_PASS master_irq1=09 slave_irq8=70");
`endif

        if (protocol_error)
            $fatal(1, "A3 PIC reported a protocol error");

        $display("A3_AT_PIC_PASS master=08 slave=70");
        $finish;
    end

    initial begin
        #30000;
        $fatal(1, "A3 PIC test timeout");
    end
endmodule
