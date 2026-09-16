`timescale 1ns/1ps
module at_video_calc_cdc_tb;
    reg clk=0, vid=0, refclk=0;
    reg [4:0] par=0;
    wire [15:0] dout;
    always #10 clk=~clk;
    always #8.73 vid=~vid;
    always #5 refclk=~refclk;
    video_calc #(.AT_CDC(1)) dut(.clk_100(refclk),.clk_vid(vid),.clk_sys(clk),
        .ce_pix(1'b1),.de(1'b0),.hs(1'b0),.vs(1'b0),.vs_hdmi(1'b0),.f1(1'b0),
        .new_vmode(1'b0),.video_rotated(1'b0),.par_num(par),.dout(dout));
    task check_word(input [4:0] n,input [15:0] value);
        @(negedge clk); par=n;
        repeat(2) @(negedge clk);
        if(dout!==value) $fatal(1,"HPS word %d expected %h got %h",n,value,dout);
    endtask
    initial begin
        force dut.vid_hcnt=32'h1234ffff;
        force dut.vid_vcnt=32'h5678aaaa;
        force dut.vid_htime=32'h9abc5555;
        force dut.vid_fclks=24'h112233;
        repeat(40) @(negedge clk);
        check_word(2,16'hffff);
        force dut.vid_hcnt=32'hfedc0000;
        force dut.vid_htime=32'h11112222;
        repeat(40) @(negedge clk);
        check_word(3,16'h1234); // Same query cannot tear across updates.
        check_word(6,16'h5555); check_word(7,16'h9abc);
        check_word(19,16'h2233); check_word(20,16'h0011);
        @(negedge clk); par=0;
        repeat(5) @(negedge clk);
        check_word(2,16'h0000); check_word(3,16'hfedc);
        check_word(6,16'h2222); check_word(7,16'h1111);
        $display("AT_VIDEO_CALC_CDC_PASS coherent_queries=2"); $finish;
    end
    initial begin #20000; $fatal(1,"Timeout"); end
endmodule
