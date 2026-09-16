`timescale 1ns/1ps
// Compile WITHOUT either helper: default-disabled legacy modules must retain
// their direct paths and must not require an active CDC instance.
module at_cdc_legacy_tb;
    reg clk=0, vid=0;
    reg [4:0] par=2;
    wire [15:0] dout;
    always #10 clk=~clk;
    always #8.73 vid=~vid;
    osd osd_legacy(.clk_sys(clk),.io_osd(1'b0),.io_strobe(1'b0),.io_din(16'd0),
        .clk_video(vid),.din(24'd0),.de_in(1'b0),.vs_in(1'b0),.hs_in(1'b0),
        .dout(),.de_out(),.vs_out(),.hs_out(),.osd_status());
    video_calc calc_legacy(.clk_100(clk),.clk_vid(vid),.clk_sys(clk),
        .ce_pix(1'b1),.de(1'b0),.hs(1'b0),.vs(1'b0),.vs_hdmi(1'b0),.f1(1'b0),
        .new_vmode(1'b0),.video_rotated(1'b0),.par_num(par),.dout(dout));
    initial begin
        force osd_legacy.infox=22'd199;
        force osd_legacy.rot=2'd3;
        force calc_legacy.vid_hcnt=32'h12345678;
        #1;
        if(osd_legacy.infox_video!==199 || osd_legacy.rot_video!==3) $fatal(1,"Legacy OSD path delayed");
        repeat(3) @(negedge clk);
        if(dout!==16'h5678) $fatal(1,"Legacy low word changed");
        force calc_legacy.vid_hcnt=32'hfedcaaaa;
        par=3;
        repeat(2) @(negedge clk);
        if(dout!==16'hfedc) $fatal(1,"Legacy unexpectedly uses frozen queries");
        $display("AT_CDC_LEGACY_PASS defaults_disabled=1"); $finish;
    end
endmodule
