`timescale 1ns/1ps

// Focused check of the unchanged production KF8259 behavior when an IRQ edge
// is withdrawn before acknowledgement. The controller must produce the
// documented spurious IRQ7 vector on the second 8086-mode INTA pulse.
module spk286_pic_spurious_tb;
    logic clock = 1'b0;
    logic reset = 1'b1;
    logic chip_select_n = 1'b1;
    logic read_enable_n = 1'b1;
    logic write_enable_n = 1'b1;
    logic address = 1'b0;
    logic [7:0] data_bus_in = 8'h00;
    logic interrupt_acknowledge_n = 1'b1;
    logic [7:0] interrupt_request = 8'h00;
    wire [7:0] data_bus_out;
    wire data_bus_io;
    wire interrupt_to_cpu;

    always #5 clock = ~clock;

    KF8259 dut (
        .clock(clock), .reset(reset),
        .chip_select_n(chip_select_n),
        .read_enable_n(read_enable_n),
        .write_enable_n(write_enable_n),
        .address(address), .data_bus_in(data_bus_in),
        .data_bus_out(data_bus_out), .data_bus_io(data_bus_io),
        .cascade_in(3'b000), .cascade_out(), .cascade_io(),
        .slave_program_n(1'b1), .buffer_enable(),
        .slave_program_or_enable_buffer(),
        .interrupt_acknowledge_n(interrupt_acknowledge_n),
        .interrupt_to_cpu(interrupt_to_cpu),
        .interrupt_request(interrupt_request)
    );

    task automatic write_pic(input logic port_address, input logic [7:0] value);
        begin
            @(negedge clock);
            chip_select_n = 1'b0;
            write_enable_n = 1'b0;
            address = port_address;
            data_bus_in = value;
            @(negedge clock);
            chip_select_n = 1'b1;
            write_enable_n = 1'b1;
            address = 1'b0;
            data_bus_in = 8'h00;
        end
    endtask

    task automatic acknowledge_pulse;
        begin
            @(negedge clock);
            interrupt_acknowledge_n = 1'b0;
            @(negedge clock);
            interrupt_acknowledge_n = 1'b1;
        end
    endtask

    initial begin
        integer deadline;
        repeat (5) @(posedge clock);
        reset = 1'b0;

        // Single, edge-triggered controller; vector base 20h; 8086 mode;
        // only IRQ0 enabled.
        write_pic(1'b0, 8'h13);
        write_pic(1'b1, 8'h20);
        write_pic(1'b1, 8'h01);
        write_pic(1'b1, 8'hfe);

        // A masked, withdrawn IRQ1 must never assert the CPU interrupt pin.
        @(negedge clock);
        interrupt_request = 8'h02;
        @(negedge clock);
        interrupt_request = 8'h00;
        repeat (8) @(negedge clock);
        if (interrupt_to_cpu)
            $fatal(1, "masked withdrawn request reached the CPU");

        // Withdraw IRQ0 after the edge is latched but before either INTA.
        interrupt_request = 8'h01;
        @(negedge clock);
        interrupt_request = 8'h00;
        for (deadline = 0; deadline < 40 && !interrupt_to_cpu;
             deadline = deadline + 1)
            @(negedge clock);
        if (!interrupt_to_cpu)
            $fatal(1, "withdrawn IRQ0 was not initially presented");

        acknowledge_pulse();
        @(negedge clock);
        interrupt_acknowledge_n = 1'b0;
        #1;
        if (data_bus_io || data_bus_out !== 8'h27)
            $fatal(1, "spurious second INTA vector mismatch vector=%h io=%b",
                   data_bus_out, data_bus_io);
        @(negedge clock);
        interrupt_acknowledge_n = 1'b1;
        repeat (4) @(negedge clock);
        if (interrupt_to_cpu)
            $fatal(1, "spurious request remained asserted after INTA");

        $display("I4_PIC_SPURIOUS_PASS vector=%h", 8'h27);
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "PIC spurious test timeout");
    end
endmodule
