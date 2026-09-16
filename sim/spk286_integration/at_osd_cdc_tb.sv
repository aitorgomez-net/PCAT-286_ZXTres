`timescale 1ns/1ps
module at_osd_cdc_tb;
    reg clk=0, vid=0, run=1, select_osd=0, strobe=0;
    reg [15:0] data=0;
    always #10 clk=~clk;
    always #3.367 if(run) vid=~vid;
    osd #(.AT_CDC(1)) dut(.clk_sys(clk),.io_osd(select_osd),.io_strobe(strobe),.io_din(data),
        .clk_video(vid),.din(24'h123456),.de_in(1'b0),.vs_in(1'b0),.hs_in(1'b0),
        .dout(),.de_out(),.vs_out(),.hs_out(),.osd_status());
    task word(input [15:0] value);
        @(negedge clk); data=value; strobe=1;
        @(negedge clk); strobe=0;
    endtask
    task configure_osd(input [1:0] rotation);
        @(negedge clk); select_osd=1;
        word('h45); word(33); word(71); word(29); word(11); word({14'd0,rotation});
        @(negedge clk); select_osd=0;
    endtask
    task verify(input [1:0] rotation);
        repeat(30) @(negedge clk);
        if(dut.rot_video!==rotation || dut.info_video!==1'b1 || dut.osd_enable_video!==1'b1 ||
           dut.infox_video!==22'd33 || dut.infoy_video!==22'd71 || dut.infow_video!==9'd232 || dut.infoh_video!==9'd88)
            $fatal(1,"OSD geometry did not arrive atomically");
        if(dut.osd_w_video !== (rotation[0] ? 22'd88 : 22'd232) ||
           dut.osd_h_video !== (rotation[0] ? 22'd232 : 22'd88)) $fatal(1,"OSD derived size stale");
    endtask
    initial begin
        repeat(10) @(negedge clk);
        if(dut.osd_enable_video!==0) $fatal(1,"OSD not initially disabled");
        for(integer r=0;r<4;r=r+1) begin configure_osd(2'(r)); verify(2'(r)); end
        @(negedge vid); run=0;
        configure_osd(0); configure_osd(1); configure_osd(2); configure_osd(3);
        #197; run=1; verify(3);
        @(negedge clk); select_osd=1; word('h28); word('ha5);
        @(negedge clk); select_osd=0;
        repeat(25) @(negedge clk);
        if(dut.osd_buffer[2048]!==8'ha5) $fatal(1,"Bitmap RAM path changed");
        @(negedge clk); select_osd=1; word('h40);
        @(negedge clk); select_osd=0;
        repeat(25) @(negedge clk);
        if(dut.osd_enable_video!==0) $fatal(1,"Disable lost");
        $display("AT_OSD_CDC_PASS rotations=4 pause=1 bitmap=1 disable=1"); $finish;
    end
    initial begin #50000; $fatal(1,"Timeout"); end
endmodule
