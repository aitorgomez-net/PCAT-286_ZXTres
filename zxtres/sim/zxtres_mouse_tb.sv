// A real PS/2 mouse on the ZXTRES mouse port, against the guest's COM1 mouse
// converter (MSMouseWrapper) at the board's 50 MHz.
//
// The converter is a PS/2 host. On the MiSTer the HPS plays the mouse and
// answers its commands; here a real device has to, so this checks the whole
// host side from the bus: the converter inhibits the clock, sends Reset (FFh)
// and Stream (F4h) with the device clocking the bits in, the mouse answers
// ACK, BAT and ID as a real one does, and from then on the converter relays
// the movement as Microsoft serial mouse packets (1200 baud, 7N1) on COM1 and
// answers the RTS toggle of the driver with the 'M' identification.
//
// The bus is open collector with a pull-up, as the pins of the board
// (PULLUP true): the converter's two outputs and the mouse pull it down.
`timescale 1ns/1ps

module zxtres_mouse_tb;
    localparam real BIT_NS = 1.0e9 / 1200.0;     // one serial bit

    reg clk = 0;
    always #10 clk = ~clk;                       // 50 MHz

    wire ps2_clk, ps2_dat;
    pullup (ps2_clk);
    pullup (ps2_dat);
    wire host_clk, host_dat;                     // converter outputs, 1 = released
    reg  dev_clk_low = 0, dev_dat_low = 0;       // the mouse
    assign ps2_clk = host_clk    ? 1'bz : 1'b0;
    assign ps2_clk = dev_clk_low ? 1'b0 : 1'bz;
    assign ps2_dat = host_dat    ? 1'bz : 1'b0;
    assign ps2_dat = dev_dat_low ? 1'b0 : 1'bz;

    reg  rts = 0;
    wire rd;

    MSMouseWrapper #(.CLKFREQ(50_000_000)) dut (
        .clk(clk), .ps2dta_in(ps2_dat), .ps2clk_in(ps2_clk),
        .ps2dta_out(host_dat), .ps2clk_out(host_clk),
        .rts(rts), .rd(rd)
    );

    // ---------------------------------------------------------------- mouse
    reg dev_busy  = 0;
    reg stream_on = 0;
    integer cmd_count = 0;
    reg [7:0] cmds [0:7];
    integer proto_errors = 0;

    // device to host: start, 8 data bits LSB first, odd parity, stop; about
    // 12 kHz, data valid before the clock falls and held past the rising edge
    task dev_send(input [7:0] b);
        reg [10:0] frame;
        integer i;
        begin
            frame = {1'b1, ~^b, b, 1'b0};
            wait (ps2_clk === 1'b1 && ps2_dat === 1'b1);
            #50_000;
            for (i = 0; i < 11; i = i + 1) begin
                dev_dat_low = !frame[i];
                #5_000;
                dev_clk_low = 1;
                #40_000;
                dev_clk_low = 0;
                #35_000;
            end
            dev_dat_low = 0;
            #20_000;
        end
    endtask

    // host to device: the host holds the clock low, pulls data low and lets
    // the clock go; the device then clocks 8 data bits, parity and stop in
    // (the host changes the data on each falling edge), and answers with ACK
    task dev_recv(output [7:0] cmd);
        reg par;
        reg stop;
        integer i;
        begin
            cmd = 8'h00;
            for (i = 0; i < 8; i = i + 1) begin
                #5_000;
                dev_clk_low = 1;
                #35_000;
                cmd[i] = ps2_dat;
                #5_000;
                dev_clk_low = 0;
                #35_000;
            end
            #5_000; dev_clk_low = 1; #35_000; par = ps2_dat; #5_000; dev_clk_low = 0; #35_000;
            #5_000; dev_clk_low = 1; #35_000; stop = ps2_dat; #5_000; dev_clk_low = 0; #35_000;
            if ((^cmd ^ par) !== 1'b1 || stop !== 1'b1) proto_errors = proto_errors + 1;
            // ACK: data low for one more clock
            dev_dat_low = 1;
            #5_000; dev_clk_low = 1; #40_000; dev_clk_low = 0;
            dev_dat_low = 0;
            #40_000;
        end
    endtask

    reg [7:0] cmd_q;
    time t_inhibit;
    initial forever begin
        wait (!dev_busy && host_clk === 1'b0);
        t_inhibit = $time;
        wait (host_clk === 1'b1);
        if ($time - t_inhibit >= 60_000 && host_dat === 1'b0) begin
            dev_busy = 1;
            dev_recv(cmd_q);
            if (cmd_count < 8) cmds[cmd_count] = cmd_q;
            cmd_count = cmd_count + 1;
            #200_000;
            case (cmd_q)
                8'hFF: begin dev_send(8'hFA); dev_send(8'hAA); dev_send(8'h00); end
                8'hF4: begin stream_on = 1; dev_send(8'hFA); end
                default: dev_send(8'hFA);
            endcase
            dev_busy = 0;
        end else if ($time - t_inhibit < 60_000) begin
            proto_errors = proto_errors + 1;     // inhibit shorter than 60 us
        end
    end

    // ------------------------------------------------- serial line (COM1)
    reg [6:0] ser [0:15];
    integer nser = 0;
    always @(negedge rd) begin : serial_mon
        reg [6:0] v;
        integer k;
        #(BIT_NS * 1.5);
        for (k = 0; k < 7; k = k + 1) begin
            v[k] = rd;
            #(BIT_NS);
        end
        ser[nser] = v;
        nser = nser + 1;
    end

    task packet(input [7:0] b0, input [7:0] b1, input [7:0] b2);
        begin
            dev_busy = 1;
            dev_send(b0);
            dev_send(b1);
            dev_send(b2);
            dev_busy = 0;
        end
    endtask

    integer i;
    initial begin
        wait (stream_on);
        // after the handshake the converter announces itself once
        wait (nser == 1);
        if (ser[0] !== 7'h4D) $fatal(1, "no 'M' after the handshake: %02h", ser[0]);

        // the driver toggles RTS, and the converter answers 'M'
        #1_000_000;
        rts = 1;
        wait (nser == 2);
        if (ser[1] !== 7'h4D) $fatal(1, "no 'M' after RTS: %02h", ser[1]);
        #2_000_000;

        // left button down with +8 on X (PS/2 first byte 09h, sync bit set)
        packet(8'h09, 8'h08, 8'h00);
        #3_000_000;
        wait (nser >= 8);
        #1_000_000;

        if (cmd_count < 2 || cmds[0] !== 8'hFF || cmds[1] !== 8'hF4)
            $fatal(1, "host commands: n=%0d %02h %02h (want FF F4)", cmd_count, cmds[0], cmds[1]);
        if (proto_errors != 0)
            $fatal(1, "%0d PS/2 protocol errors on the bus", proto_errors);
        if ({ser[2], ser[3], ser[4], ser[5], ser[6], ser[7]} !==
            {7'h60, 7'h00, 7'h00, 7'h60, 7'h04, 7'h00})
            $fatal(1, "serial packets: %02h %02h %02h / %02h %02h %02h",
                   ser[2], ser[3], ser[4], ser[5], ser[6], ser[7]);
        $display("ZXTRES_MOUSE_PASS cmds=%02h,%02h id=%02h,%02h packets=%02h %02h %02h / %02h %02h %02h",
                 cmds[0], cmds[1], ser[0], ser[1], ser[2], ser[3], ser[4], ser[5], ser[6], ser[7]);
        $finish;
    end

    initial begin
        #200_000_000;
        $fatal(1, "timeout: stream_on=%0b nser=%0d cmds=%0d", stream_on, nser, cmd_count);
    end
endmodule
