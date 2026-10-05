// Independent rational-clock oracle for boundary-applied profile changes.
`timescale 1ns/1ps
module spk286_at_cpu_profile_live_tb;
    logic clk = 0, reset = 1, apply = 0;
    logic [2:0] requested = 0;
    wire [2:0] active;
    wire pending, historical, phase_enable, phase_two, cpu_boundary;
    integer age = 0, expected = 0, cases = 0, checks = 0;
    spk286_at_cpu_profile dut (.*);

    function automatic integer numerator(input integer profile);
        case (profile)
            1: numerator = 12; 2: numerator = 16; 3: numerator = 20;
            4: numerator = 25; 5: numerator = 32; 6: numerator = 40;
            7: numerator = 50; default: numerator = 0;
        endcase
    endfunction
    task automatic check(input logic value, input string message);
        checks++;
        if (value !== 1'b1) $fatal(1, "%s case=%0d age=%0d old=%0d request=%0d",
                                  message, cases, age, expected, requested);
    endtask
    task automatic tick;
        integer n;
        logic change;
        #1;
        n = numerator(expected);
        check(active == 3'(expected) && pending == (requested != active), "live selector retention");
        check(historical == (expected != 0), "live mode oracle");
        check(phase_enable == (!reset && expected != 0 && ((age + 1)*n/50 != age*n/50)),
              "live rational phase oracle");
        check(phase_two == (phase_enable && ((age*n/50) % 2 == 1)), "live second phase oracle");
        check(cpu_boundary == (!reset && (expected == 0 || ((age + 1)*n/100 != age*n/100))),
              "live rational CPU oracle");
        change = reset || (apply === 1'b1 && requested != active);
        #4; clk = 1; #5; clk = 0;
        if (change) begin expected = int'(requested); age = 0; end
        else age++;
    endtask
    initial begin
        // First reset establishes known state before invoking the oracle.
        #5; clk = 1; #5; clk = 0; reset = 0;
        for (integer old_profile = 0; old_profile < 8; old_profile++)
            for (integer new_profile = 0; new_profile < 8; new_profile++)
                for (integer offset = 0; offset < 100; offset++) begin
                    cases++; requested = 3'(old_profile); reset = 1; apply = 0; tick(); reset = 0;
                    repeat (offset) tick();
                    requested = 3'(new_profile);
                    // Request alone must never modify the running epoch.
                    repeat (3) tick();
                    apply = 1; tick(); apply = 0;
                    repeat (110) tick();
                    // An apply pulse with no pending request preserves phase.
                    apply = 1; tick(); apply = 0; tick();
                    // Latest request wins at the next approved boundary.
                    requested = 3'((new_profile + 1) % 8); tick();
                    requested = 3'((new_profile + 2) % 8); apply = 1; tick(); apply = 0;
                    repeat (4) tick();
                end
`ifdef PROFILE_LIVE_FOUR_STATE
        for (integer p = 0; p < 8; p++) begin
            requested = 3'(p); reset = 1; apply = 0; tick(); reset = 0;
            requested = 3'((p + 1) % 8);
            apply = 1'bx; repeat (7) tick();
            apply = 1'bz; repeat (7) tick();
            apply = 0;
        end
        $display("PROFILE_LIVE_FOUR_STATE_PASS cases=16");
`endif
        $display("PROFILE_LIVE_CLOCK_PASS cases=%0d checks=%0d", cases, checks);
        $finish;
    end
endmodule
