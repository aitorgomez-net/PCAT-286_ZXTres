`timescale 1ns/1ps

module msmouse_wrapper_tb;
    localparam integer CLKFREQ = 1_200_000;
    localparam integer BIT_CYCLES = CLKFREQ / 1200;

    reg clk = 0;
    reg ps2_clk = 1;
    reg ps2_data = 1;
    reg rts = 0;
    wire host_clk;
    wire host_data;
    wire serial_rx;

    always #5 clk = ~clk;

    MSMouseWrapper #(.CLKFREQ(CLKFREQ)) dut (
        .clk(clk), .ps2dta_in(ps2_data), .ps2clk_in(ps2_clk),
        .ps2dta_out(host_data), .ps2clk_out(host_clk),
        .rts(rts), .rd(serial_rx)
    );

    task automatic ps2_bit(input reg value);
        begin
            ps2_data = value;
            repeat (40) @(posedge clk);
            ps2_clk = 0;
            repeat (40) @(posedge clk);
            ps2_clk = 1;
        end
    endtask

    task automatic ps2_byte(input reg [7:0] value);
        integer i;
        begin
            ps2_bit(0);
            for (i = 0; i < 8; i = i + 1) ps2_bit(value[i]);
            ps2_bit(~^value);
            ps2_bit(1);
            ps2_data = 1;
            repeat (140) @(posedge clk);
        end
    endtask

    task automatic serial_byte(output reg [6:0] value);
        integer i;
        begin
            @(negedge serial_rx);
            repeat (BIT_CYCLES + BIT_CYCLES/2) @(posedge clk);
            for (i = 0; i < 7; i = i + 1) begin
                value[i] = serial_rx;
                repeat (BIT_CYCLES) @(posedge clk);
            end
        end
    endtask

    reg [6:0] b0, b1, b2, b3, b4, b5, id_byte;
    initial begin
        // Enter the source wrapper's stream state to isolate PS/2 reception
        // and Microsoft serial packet encoding from the HPS command exchange.
        repeat (10) @(posedge clk);
        force dut.PS2Pr_STM = 4'd7;
        wait (serial_rx === 1'b1);
        fork
            begin
                ps2_byte(8'h09); // left button + PS/2 synchronization bit
                ps2_byte(8'h08); // +8 X; source wrapper scales this to +4
                ps2_byte(8'h00); // 0 Y
            end
            begin
                serial_byte(b0);
                serial_byte(b1);
                serial_byte(b2);
                serial_byte(b3);
                serial_byte(b4);
                serial_byte(b5);
            end
        join
        if ({b0,b1,b2,b3,b4,b5} !==
            {7'h60,7'h00,7'h00,7'h60,7'h04,7'h00})
            $fatal(1, "mouse packet mismatch: %02h %02h %02h / %02h %02h %02h",
                   b0,b1,b2,b3,b4,b5);
        repeat (3000) @(posedge clk);
        release dut.PS2Pr_STM;
        rts = 1;
        serial_byte(id_byte);
        if (id_byte !== 7'h4d)
            $fatal(1, "mouse RTS identification mismatch: %02h", id_byte);
        $display("MSMOUSE_WRAPPER_PASS id=%02h packets=%02h %02h %02h / %02h %02h %02h",
                 id_byte,b0,b1,b2,b3,b4,b5);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "mouse serial packet timeout");
    end
endmodule
