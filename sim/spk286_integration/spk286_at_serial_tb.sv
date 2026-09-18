`timescale 1ns/1ps

module spk286_at_serial_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    logic baudce = 1'b1;
    logic request_valid = 1'b0;
    logic request_command_valid = 1'b0;
    logic request_write = 1'b0;
    logic request_io = 1'b0;
    logic [23:0] request_address = 24'h0;
    logic [1:0] request_byte_enable = 2'b00;
    logic [15:0] request_data_out = 16'h0;
    wire request_accept;
    wire request_ready;
    wire [15:0] request_read_data;
    wire request_read_data_valid;
    wire tx;
    wire irq;
    logic rx = 1'b1;

    always #5 clk = ~clk;

    spk286_at_serial #(.MPU_MODE(1'b1)) dut (
        .clk                    (clk),
        .reset                  (reset),
        .baudce                 (baudce),
        .request_valid          (request_valid),
        .request_command_valid  (request_command_valid),
        .request_write          (request_write),
        .request_io             (request_io),
        .request_address        (request_address),
        .request_byte_enable    (request_byte_enable),
        .request_data_out       (request_data_out),
        .request_accept         (request_accept),
        .request_ready          (request_ready),
        .request_read_data      (request_read_data),
        .request_read_data_valid(request_read_data_valid),
        .rx                     (rx),
        .cts_n                  (1'b1),
        .dsr_n                  (1'b1),
        .dcd_n                  (1'b1),
        .tx                     (tx),
        .rts_n                  (),
        .dtr_n                  (),
        .irq                    (irq),
        .side_effect_count      (),
        .protocol_error         ()
    );

    task automatic bus_write(input [15:0] port, input [7:0] data);
        begin
            @(negedge clk);
            request_address       = {8'h00, port};
            request_byte_enable   = port[0] ? 2'b10 : 2'b01;
            request_data_out      = port[0] ? {data, 8'h00} : {8'h00, data};
            request_write         = 1'b1;
            request_io            = 1'b1;
            request_valid         = 1'b1;
            request_command_valid = 1'b1;
            #1;
            while (!request_accept) @(negedge clk);
            @(posedge clk) request_valid <= 1'b0;
            while (!request_ready) @(negedge clk);
            @(posedge clk);
        end
    endtask

    task automatic bus_read(input [15:0] port, output [7:0] data);
        begin
            @(negedge clk);
            request_address       = {8'h00, port};
            request_byte_enable   = port[0] ? 2'b10 : 2'b01;
            request_data_out      = 16'h0000;
            request_write         = 1'b0;
            request_io            = 1'b1;
            request_valid         = 1'b1;
            request_command_valid = 1'b1;
            #1;
            while (!request_accept) @(negedge clk);
            @(posedge clk) request_valid <= 1'b0;
            while (!request_ready) @(negedge clk);
            if (!request_read_data_valid)
                $fatal(1, "MPU read did not return data at %h", port);
            data = port[0] ? request_read_data[15:8] : request_read_data[7:0];
            @(posedge clk);
        end
    endtask

    // Feed one valid 8N1 byte at the compact model's 16x baud enable.  This
    // is deliberately used both before and after 3Fh to catch IRQ9 leakage
    // while the MPU is still in its non-UART state.
    task automatic send_rx_byte(input [7:0] data);
        integer bit_index;
        begin
            @(negedge clk);
            rx = 1'b0;
            repeat (8) @(posedge clk);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                rx = data[bit_index];
                repeat (16) @(posedge clk);
            end
            rx = 1'b1;
            repeat (16) @(posedge clk);
        end
    endtask

    reg [7:0] value;
    initial begin
        repeat (2) @(posedge clk);
        reset <= 1'b0;
        repeat (70) @(posedge clk);

        send_rx_byte(8'h55);
        if (irq) $fatal(1, "MPU RX asserted IRQ before UART mode");

        bus_write(16'h0331, 8'hff);
        if (irq) $fatal(1, "MPU reset ACK unexpectedly asserted IRQ");
        bus_read(16'h0330, value);
        if (value !== 8'hfe) $fatal(1, "MPU reset ACK mismatch: %h", value);
        bus_read(16'h0330, value);

        bus_write(16'h0331, 8'h3f);
        bus_read(16'h0330, value);
        if (value !== 8'hfe) $fatal(1, "MPU UART-mode ACK mismatch: %h", value);
        if (irq) $fatal(1, "MPU UART-mode ACK unexpectedly asserted IRQ");

        send_rx_byte(8'h55);
        if (!irq) $fatal(1, "MPU RX did not assert IRQ in UART mode");

        bus_write(16'h0330, 8'h90);
        if (tx !== 1'b0) $fatal(1, "MPU TX did not start with a low start bit");

        $display("AT_SERIAL_MPU_PASS tx_start=%b", tx);
        $finish;
    end
endmodule
