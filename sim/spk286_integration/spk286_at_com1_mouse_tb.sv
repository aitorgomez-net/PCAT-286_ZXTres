`timescale 1ns/1ps

// Exercise the imported mouse converter through the AT COM1 UART endpoint.
module spk286_at_com1_mouse_tb;
    reg clk = 0;
    reg reset = 1;
    reg [20:0] baud_phase = 0;
    reg baudce = 0;
    reg request_valid = 0;
    reg request_command_valid = 0;
    reg request_write = 0;
    reg request_io = 0;
    reg [23:0] request_address = 0;
    reg [1:0] request_byte_enable = 0;
    reg [15:0] request_data_out = 0;
    wire request_accept;
    wire request_ready;
    wire [15:0] request_read_data;
    wire request_read_data_valid;
    wire uart_rx;
    wire uart_rts_n;
    wire uart_irq;
    wire ps2_clk_in;
    wire ps2_data_in;

    always #5 clk = ~clk;
    // 1.2 MHz test clock / 19200 x16 reference = 1200 serial bits/s.
    always @(posedge clk) begin
        if (reset) begin
            baud_phase <= 0;
            baudce <= 0;
        end else if (baud_phase + 21'd19200 >= 21'd1200000) begin
            baud_phase <= baud_phase + 21'd19200 - 21'd1200000;
            baudce <= 1;
        end else begin
            baud_phase <= baud_phase + 21'd19200;
            baudce <= 0;
        end
    end

    MSMouseWrapper #(.CLKFREQ(1_200_000)) mouse (
        .clk(clk), .ps2dta_in(1'b1), .ps2clk_in(1'b1),
        .ps2dta_out(ps2_data_in), .ps2clk_out(ps2_clk_in),
        .rts(~uart_rts_n), .rd(uart_rx)
    );

    spk286_at_serial #(.MPU_MODE(1'b0)) com1 (
        .clk(clk), .reset(reset), .baudce(baudce),
        .request_valid(request_valid),
        .request_command_valid(request_command_valid),
        .request_write(request_write), .request_io(request_io),
        .request_address(request_address),
        .request_byte_enable(request_byte_enable),
        .request_data_out(request_data_out),
        .request_accept(request_accept), .request_ready(request_ready),
        .request_read_data(request_read_data),
        .request_read_data_valid(request_read_data_valid),
        .rx(uart_rx), .cts_n(1'b0), .dsr_n(1'b0), .dcd_n(1'b0),
        .tx(), .rts_n(uart_rts_n), .dtr_n(), .irq(uart_irq),
        .side_effect_count(), .protocol_error()
    );

    task automatic bus_write(input [15:0] port, input [7:0] data);
        begin
            @(negedge clk);
            request_address = {8'h00,port};
            request_byte_enable = port[0] ? 2'b10 : 2'b01;
            request_data_out = port[0] ? {data,8'h00} : {8'h00,data};
            request_write = 1;
            request_io = 1;
            request_valid = 1;
            request_command_valid = 1;
            #1;
            while (!request_accept) @(negedge clk);
            @(posedge clk) request_valid <= 0;
            while (!request_ready) @(negedge clk);
            @(posedge clk);
        end
    endtask

    task automatic bus_read(input [15:0] port, output [7:0] data);
        begin
            @(negedge clk);
            request_address = {8'h00,port};
            request_byte_enable = port[0] ? 2'b10 : 2'b01;
            request_write = 0;
            request_io = 1;
            request_valid = 1;
            request_command_valid = 1;
            #1;
            while (!request_accept) @(negedge clk);
            @(posedge clk) request_valid <= 0;
            while (!request_ready) @(negedge clk);
            if (!request_read_data_valid)
                $fatal(1, "COM1 read missing data at %h", port);
            data = port[0] ? request_read_data[15:8] : request_read_data[7:0];
            @(posedge clk);
        end
    endtask

    reg [7:0] value;
    initial begin
        repeat (5) @(posedge clk);
        reset <= 0;
        bus_write(16'h03f9, 8'h01); // receive interrupt enable
        bus_write(16'h03fc, 8'h02); // RTS announces serial mouse
        if (uart_rts_n !== 1'b0)
            $fatal(1, "COM1 RTS did not assert");
        wait (uart_irq === 1'b1);
        bus_read(16'h03f8, value);
        // The compact UART model captures 8 bits regardless of LCR. It
        // therefore stores the first 7N2 stop bit as bit 7 of ASCII 'M'.
        if (value !== 8'hcd)
            $fatal(1, "COM1 mouse ID mismatch: %02h", value);
        repeat (3) @(posedge clk);
        if (uart_irq !== 1'b0)
            $fatal(1, "COM1 IRQ did not clear after reading RX");
        $display("AT_COM1_MOUSE_PASS id=%02h rts_n=%b", value, uart_rts_n);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "COM1 mouse ID timeout");
    end
endmodule
