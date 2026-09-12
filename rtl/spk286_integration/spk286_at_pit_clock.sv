// Fractional PIT clock from the AT 50 MHz system clock. No derived FPGA
// clock domain: KF8253 samples this signal on clk. 14.31818 MHz / 12,
// rounded to 1,193,182 Hz; half periods are 20 or 21 system clocks.
`timescale 1ns/1ps
module spk286_at_pit_clock(input logic clk, reset, output logic counter_clock);
    logic [25:0] phase_q;
    always_ff @(posedge clk) begin
        if(reset) begin phase_q <= 0; counter_clock <= 0; end
        else if(phase_q >= 26'd47_613_636) begin
            phase_q <= phase_q - 26'd47_613_636;
            counter_clock <= ~counter_clock;
        end else phase_q <= phase_q + 26'd2_386_364;
    end
endmodule
