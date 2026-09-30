`timescale 1ns/1ps
module spk286_at_rtc_clock_tb;
    logic clk = 1'b0, reset = 1'b1;
    always #10 clk = ~clk;
    wire tick_32768, second_tick;
    spk286_at_rtc_clock dut (.*);

    initial begin
        integer cycles, pulses, seconds, last_pulse;
        cycles = $test$plusargs("FULL_SECOND") ? 50000000 : 390625;
        pulses = 0; seconds = 0; last_pulse = 0;
        repeat (3) @(negedge clk);
        if (tick_32768 || second_tick) $fatal(1, "RTC clock active during reset");
        reset = 1'b0;
        for (integer c = 1; c <= cycles; c = c + 1) begin
            @(negedge clk);
            if (tick_32768) begin
                if ((last_pulse != 0) && ((c-last_pulse < 1525) || (c-last_pulse > 1526)))
                    $fatal(1, "RTC base-clock spacing incorrect: %0d", c-last_pulse);
                pulses = pulses + 1;
                last_pulse = c;
            end
            if (second_tick) begin
                seconds = seconds + 1;
                if (c != 50000000) $fatal(1, "RTC second pulse at cycle %0d", c);
            end
        end
        if (pulses != ((cycles == 50000000) ? 32768 : 256))
            $fatal(1, "RTC base rate wrong: %0d pulses", pulses);
        if (seconds != ((cycles == 50000000) ? 1 : 0))
            $fatal(1, "RTC second rate wrong");
        @(negedge clk);
        if (tick_32768 || second_tick) $fatal(1, "RTC enables wider than one cycle");
        reset = 1'b1;
        @(negedge clk);
        if (tick_32768 || second_tick) $fatal(1, "RTC clock reset failed");
        $display("AT_RTC_CLOCK_PASS cycles=%0d base_pulses=%0d seconds=%0d", cycles, pulses, seconds);
        $finish;
    end
endmodule
