`timescale 1ns/1ps
module at_frame_counter_tb;
    reg clk_sys=0, clk_video=0, run_sys=1, run_video=1, vs=0;
    always #10 if (run_sys) clk_sys=~clk_sys;
    always #8.73 if (run_video) clk_video=~clk_video;
    wire [7:0] count;
    integer expected=0;
    at_frame_counter dut(.clk_sys(clk_sys),.clk_video(clk_video),.vs(vs),.frame_cnt(count));

    task drain;
        repeat(8) @(negedge clk_sys);
        if (count !== 8'(expected)) $fatal(1,"Frame count expected=%0d got=%0d",expected,count);
    endtask
    task frame(input integer high_cycles, low_cycles);
        repeat(low_cycles) @(negedge clk_video);
        vs=1; expected++;
        repeat(high_cycles) @(negedge clk_video);
        vs=0;
        drain();
    endtask
    initial begin
        drain();
        for(integer i=0;i<270;i++) frame(5+i%7,3+i%11);
        // Stopping the source while VS is high must not recount that level.
        @(negedge clk_video); vs=1; expected++;
        repeat(4) @(negedge clk_video); run_video=0;
        drain(); repeat(20) @(negedge clk_sys); drain();
        run_video=1;
        repeat(4) @(negedge clk_video); vs=0; drain();
        // A held VS level survives a stopped receiver and counts once on resume.
        @(negedge clk_sys); run_sys=0;
        @(negedge clk_video); vs=1; expected++;
        repeat(20) @(negedge clk_video); run_sys=1;
        drain();
        @(negedge clk_video); vs=0; drain();
        $display("AT_FRAME_COUNTER_PASS edges=%0d wrap=1 source_pause=1 receiver_pause=1",expected);
        $finish;
    end
    initial begin #500000; $fatal(1,"Counter timeout"); end
endmodule
