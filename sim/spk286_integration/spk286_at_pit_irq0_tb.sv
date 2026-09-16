`timescale 1ns/1ps

// Regression for the exact PIT channel-0 setup emitted by the Sergey BIOS:
// channel 0, LSB/MSB, mode 3, binary, divisor 0000 (=65536).
module spk286_at_pit_irq0_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    logic counter_clock = 1'b0;
    logic request_valid = 1'b0;
    logic request_command_valid = 1'b0;
    logic request_write = 1'b0;
    logic [23:0] request_address = 24'h0;
    logic [1:0] request_byte_enable = 2'b00;
    logic [15:0] request_data_out = 16'h0;
    wire request_accept;
    wire request_ready;
    wire [15:0] request_read_data;
    wire request_read_data_valid;
    wire irq0;
    wire [2:0] counter_out;
    wire protocol_error;
    integer transitions = 0;
    logic previous_out = 1'b0;

    always #10 clk = ~clk;

    spk286_at_pit dut (
        .clk                    (clk),
        .reset                  (reset),
        .counter_clock          (counter_clock),
        .counter_2_gate         (1'b0),
        .request_valid          (request_valid),
        .request_command_valid  (request_command_valid),
        .request_write          (request_write),
        .request_io             (1'b1),
        .request_address        (request_address),
        .request_byte_enable    (request_byte_enable),
        .request_data_out       (request_data_out),
        .request_accept         (request_accept),
        .request_ready          (request_ready),
        .request_read_data      (request_read_data),
        .request_read_data_valid(request_read_data_valid),
        .irq0                   (irq0),
        .counter_out            (counter_out),
        .protocol_error         (protocol_error)
    );

    always @(posedge clk) begin
        if (!reset && irq0 !== previous_out) begin
            transitions = transitions + 1;
            previous_out = irq0;
        end
    end

    task automatic pit_write(input logic [15:0] port,
                             input logic [7:0] value);
        integer cycles;
        begin
            @(negedge clk);
            request_valid = 1'b1;
            request_command_valid = 1'b1;
            request_write = 1'b1;
            request_address = {8'h00, port};
            request_byte_enable = port[0] ? 2'b10 : 2'b01;
            request_data_out = port[0] ? {value, 8'h00} : {8'h00, value};
            #1;
            if (!request_accept)
                $fatal(1, "PIT write was not accepted port=%h", port);
            @(negedge clk);
            request_command_valid = 1'b0;
            cycles = 0;
            while (!request_ready && cycles < 16) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!request_ready)
                $fatal(1, "PIT write did not complete port=%h", port);
            request_valid = 1'b0;
            request_data_out = 16'h0;
            request_byte_enable = 2'b00;
            @(negedge clk);
        end
    endtask

    task automatic pit_falling_edges(input integer count);
        integer i;
        begin
            for (i = 0; i < count; i = i + 1) begin
                @(negedge clk);
                counter_clock = 1'b1;
                @(negedge clk);
                counter_clock = 1'b0;
            end
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        reset = 1'b0;
        repeat (2) @(negedge clk);

        // 8253 control word 36h: channel 0, LSB/MSB, mode 3, binary.
        pit_write(16'h0043, 8'h36);
        pit_write(16'h0040, 8'h00);
        pit_write(16'h0040, 8'h00);

        previous_out = irq0;
        pit_falling_edges(32770);
        if (transitions < 1)
            $fatal(1, "PIT mode-3 divisor-zero produced no IRQ0 transition");

        pit_falling_edges(32770);
        if (transitions < 2)
            $fatal(1, "PIT mode-3 divisor-zero did not produce two half-periods");
        if (protocol_error)
            $fatal(1, "PIT mode-3 test reported a protocol error");

        $display("AT_PIT_IRQ0_PASS transitions=%0d mode=3 divisor=65536", transitions);
        $finish;
    end

    initial begin
        #5000000;
        $fatal(1, "PIT IRQ0 test watchdog");
    end
endmodule
