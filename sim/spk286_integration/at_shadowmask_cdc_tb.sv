`timescale 1ns/1ps
module at_shadowmask_cdc_tb;
    reg clk_sys=0, clk=0, run_video=1;
    always #10 clk_sys=~clk_sys;
    always #3.367 if(run_video) clk=~clk;
    reg cmd_wr=0, cmd_active=0;
    reg [15:0] cmd_in=0;
    reg enable=1;
    reg enable_video=1;
    reg [23:0] din=24'hA07040;
    reg hs=0,vs=0,de=0,brd=1;
    integer h=0,v=0,frame_count=0,compared=0;
    wire [23:0] pixels,legacy_pixels,local_pixels;
    wire local_hs,local_vs,local_de;
    wire ho,vo,deo,lho,lvo,ldeo;
    reg compare_pixels=0;
    shadowmask #(.AT_CDC(1)) dut(.clk(clk),.clk_sys(clk_sys),
        .cmd_wr(cmd_wr),.cmd_in(cmd_in),.cmd_active(cmd_active),
        .din(din),.hs_in(hs),.vs_in(vs),.de_in(de),.brd_in(brd),.enable(enable),
        .dout(pixels),.hs_out(ho),.vs_out(vo),.de_out(deo));
    shadowmask legacy(.clk(clk),.clk_sys(clk_sys),
        .cmd_wr(cmd_wr),.cmd_in(cmd_in),.cmd_active(cmd_active),
        .din(din),.hs_in(hs),.vs_in(vs),.de_in(de),.brd_in(brd),.enable(enable),
        .dout(legacy_pixels),.hs_out(lho),.vs_out(lvo),.de_out(ldeo));
    shadowmask #(.AT_CDC(1),.AT_VIDEO_ENABLE(1)) local_dut(.clk(clk),.clk_sys(clk_sys),
        .cmd_wr(cmd_wr),.cmd_in(cmd_in),.cmd_active(cmd_active),
        .din(din),.hs_in(hs),.vs_in(vs),.de_in(de),.brd_in(brd),.enable(enable_video),
        .dout(local_pixels),.hs_out(local_hs),.vs_out(local_vs),.de_out(local_de));

    always @(negedge clk) begin
        h=(h+1)%80;
        if(h==0) begin
            v=(v+1)%24;
            if(v==0) frame_count++;
        end
        hs=(h>=68 && h<72); vs=(v>=20 && v<22);
        de=(h<64 && v<16); brd=~de;
        din={8'(h+v+32),8'(h+64),8'(v*3+48)};
    end
    // Verify the visible configuration only changes on a VS falling edge.
    always @(posedge clk) begin : boundary_check
        reg [10:0] previous;
        reg may_change;
        previous=dut.g_at_config.config_active_q;
        may_change=dut.g_at_config.vs_seen && !vs;
        #0.001;
        if(!may_change && dut.g_at_config.config_active_q !== previous)
            $fatal(1,"Shadowmask configuration changed inside a frame");
        if(compare_pixels) begin
            if({ho,vo,deo} !== {lho,lvo,ldeo}) $fatal(1,"Video latency changed");
            if({local_hs,local_vs,local_de} !== {lho,lvo,ldeo}) $fatal(1,"Local enable video latency changed");
            if(deo) begin
                if(^pixels === 1'bx) $fatal(1,"Unknown visible pixel in comparison");
                if(pixels !== legacy_pixels) $fatal(1,"Mask output differs from legacy: %h != %h",pixels,legacy_pixels);
                if(local_pixels !== legacy_pixels) $fatal(1,"Local enable output differs from legacy");
                compared++;
            end
        end
    end

    task word(input [15:0] data);
        @(negedge clk_sys); cmd_wr=1; cmd_in=data;
    endtask
    task begin_transaction;
        @(negedge clk_sys); cmd_active=1;
    endtask
    task end_transaction;
        @(negedge clk_sys); cmd_wr=0; cmd_active=0;
        repeat(30) @(negedge clk_sys);
    endtask
    task configure(input [2:0] flags,input [3:0] hm,vm,input integer seed);
        begin_transaction();
        word({12'd0,flags,1'b0});
        for(integer i=0;i<256;i++) word(16'h6000 | 16'((i*13+seed)&2047));
        word(16'h4000 | hm); word(16'h2000 | vm);
        end_transaction();
        for(integer i=0;i<256;i++)
            if(dut.mask_lut[i] !== 11'((i*13+seed)&2047))
                $fatal(1,"LUT word lost/corrupt at %0d",i);
    endtask
    task check_active(input [2:0] flags,input [3:0] hm,vm);
        if(dut.g_at_config.config_active_q !== {flags,hm,vm})
            $fatal(1,"Wrong active config: %h expected=%h",dut.g_at_config.config_active_q,{flags,hm,vm});
    endtask
    task compare_stable(input [2:0] flags,input [3:0] hm,vm);
        repeat(3) @(negedge vs);
        repeat(12) @(negedge clk);
        check_active(flags,hm,vm);
        compare_pixels=1;
        repeat(2) @(negedge vs);
        compare_pixels=0;
    endtask
    initial begin
        configure(3'b100,3,2,17); compare_stable(3'b100,3,2);
        configure(3'b101,7,3,271); compare_stable(3'b101,7,3);
        configure(3'b110,5,1,531); compare_stable(3'b110,5,1);
        configure(3'b111,15,15,19); compare_stable(3'b111,15,15);

        // Keep UIO selected over several frames. Neither flags nor geometry
        // may become visible before the final word and transaction end.
        begin_transaction(); word(16'h0008); word(16'h4001);
        @(negedge clk_sys); cmd_wr=0;
        repeat(2) @(negedge vs); repeat(8) @(negedge clk);
        check_active(3'b111,15,15);
        word(16'h2004); end_transaction();
        compare_stable(3'b100,1,4);

        // Three complete uploads while HDMI is stopped: command data must
        // never enter the lossy latest-value configuration mailbox.
        @(negedge clk); run_video=0;
        configure(3'b101,7,8,23);
        configure(3'b110,2,3,65);
        configure(3'b111,9,10,141);
        run_video=1;
        compare_stable(3'b111,9,10);

        // LFB bypass is coherent with the flags and also applied at VS.
        @(negedge clk_sys); enable=0;
        @(negedge clk); enable_video=0;
        @(posedge clk); #0.001;
        if(local_dut.mask_enable !== 0 || local_dut.g_at_config.config_active_q[10] !== 1)
            $fatal(1,"HDMI-local bypass incorrectly waits for the sys mailbox");
        compare_stable(3'b011,9,10);
        @(negedge clk_sys); enable=1;
        @(negedge clk); enable_video=1;
        @(posedge clk); #0.001;
        if(local_dut.mask_enable !== 1) $fatal(1,"HDMI-local re-enable failed");
        compare_stable(3'b111,9,10);
        configure(3'b000,0,0,81); compare_stable(3'b000,0,0);
        if(compared<10000) $fatal(1,"Insufficient visible-pixel comparisons");
        $display("AT_SHADOWMASK_CDC_PASS pixels=%0d modes=4 lut_words=2048 partial_transaction=1 clock_pause=1 lfb=1 local_enable=1",compared);
        $finish;
    end
    initial begin #2000000; $fatal(1,"Shadowmask timeout"); end
endmodule
