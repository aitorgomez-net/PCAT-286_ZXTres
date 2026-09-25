`timescale 1ns/1ps
module at_scaler_config_tb;
    reg cs=0, cv=0, co=0, run_video=1, run_hdmi=1;
    always #10 cs=~cs;
    always #8.730 if (run_video) cv=~cv;
    always #3.367 if (run_hdmi) co=~co;
    reg idle=1, ivs=0, ovs=0;
    reg [11:0] width=1920, hfp=88, hbp=148, height=1080, vfp=4, vbp=36;
    reg [12:0] hs=48, vs=5, arc1x=16, arc1y=9, arc2x=5, arc2y=4, arx=4, ary=3;
    reg [11:0] hset=0, vset=0, lhmin=0, lhmax=0, lvmin=0, lvmax=0;
    reg pr=0, free=0, en=1, vrr=0, lfb=0, fb_en=0;
    reg [4:0] mode=8;
    reg [11:0] fw=640, fh=480;
    reg [5:0] fmt=5;
    reg [31:0] base=32'h24000000;
    reg [13:0] stride=1920;
    wire [11:0] dw,dh,axs,ays,ht,hss,hse,hd,hmn,hmx,vt,vss,vse,vd,vmn,vmx,vrmax,ofw,ofh;
    wire axys,oe,ovrr,olfb,hpol,vpol,ofe,update,retime;
    wire [4:0] imode,omode;
    wire [5:0] ofmt;
    wire [31:0] obase;
    wire [13:0] ostride;
    at_scaler_config dut (
        .clk_sys(cs),.clk_video(cv),.clk_hdmi(co),.src_idle(idle),.video_vs(ivs),.hdmi_vs(ovs),
        .width(width),.hfp(hfp),.hbp(hbp),.height(height),.vfp(vfp),.vbp(vbp),.hs(hs),.vs(vs),
        .hset(hset),.vset(vset),.pixel_repeat(pr),.freescale(free),.enable(en),.vrr(vrr),.mode(mode),
        .arc1x(arc1x),.arc1y(arc1y),.arc2x(arc2x),.arc2y(arc2y),.arx_video(arx),.ary_video(ary),
        .lfb(lfb),.lfb_hmin(lhmin),.lfb_hmax(lhmax),.lfb_vmin(lvmin),.lfb_vmax(lvmax),
        .fb_enable(fb_en),.fb_width(fw),.fb_height(fh),.fb_format(fmt),.fb_base(base),.fb_stride(stride),
        .hdmi_width(dw),.hdmi_height(dh),.arx_sys(axs),.ary_sys(ays),.arxy_sys(axys),
        .input_mode(imode),.output_mode(omode),.output_enable(oe),.output_vrr(ovrr),.output_lfb(olfb),
        .htotal(ht),.hsstart(hss),.hsend(hse),.hdisp(hd),.hmin(hmn),.hmax(hmx),
        .vtotal(vt),.vsstart(vss),.vsend(vse),.vdisp(vd),.vmin(vmn),.vmax(vmx),.vrrmax(vrmax),
        .hs_polarity(hpol),.vs_polarity(vpol),.output_fb_enable(ofe),.output_fb_width(ofw),.output_fb_height(ofh),
        .output_fb_format(ofmt),.output_fb_base(obase),.output_fb_stride(ostride),.output_update(update),.output_retime(retime)
    );
    integer checks=0, retimes=0, saved_retimes;
    reg [243:0] last_frame=0;
    reg prior_enable=0, prior_vs=0;
    always @(posedge co) begin
        prior_enable=oe;
        prior_vs=dut.hdmi_vs_q && !ovs;
        #1;
        if (retime) retimes++;
        if (dut.output_active_q !== last_frame && prior_enable && !prior_vs)
            $fatal(1,"Output changed outside frame boundary");
        last_frame=dut.output_active_q;
    end
    task settle;
        repeat(1400) @(posedge cv);
    endtask
    task frame;
        @(negedge co); ovs=1;
        repeat(8) @(negedge co);
        ovs=0;
        repeat(8) @(negedge co);
        @(negedge cv); ivs=1;
        repeat(8) @(negedge cv);
        ivs=0;
        repeat(8) @(negedge cv);
    endtask
    task expect_frame(input integer left_i,right_i,top_i,bottom_i);
        if ({hmn,hmx,vmn,vmx} !== {12'(left_i),12'(right_i),12'(top_i),12'(bottom_i)})
            $fatal(1,"Geometry got %0d:%0d %0d:%0d expected %0d:%0d %0d:%0d",hmn,hmx,vmn,vmx,left_i,right_i,top_i,bottom_i);
        if (ht !== 12'(width+hfp+hbp+hs[11:0]) || hss !== 12'(width+hfp) || hse !== 12'(width+hfp+hs[11:0]) || hd !== width ||
            vt !== 12'(height+vfp+vbp+vs[11:0]) || vss !== 12'(height+vfp) || vse !== 12'(height+vfp+vs[11:0]) || vd !== height ||
            vrmax !== 12'(height+vbp+vs[11:0]+1) || hpol !== hs[12] || vpol !== vs[12])
            $fatal(1,"Output timing packet torn");
        if ({omode,oe,ovrr,olfb,ofe,ofw,ofh,ofmt,obase,ostride} !== {mode,en,vrr,lfb,fb_en,fw,fh,fmt,base,stride})
            $fatal(1,"Mode/framebuffer packet torn");
        if (imode !== mode) $fatal(1,"Input mode not applied at input VS");
        checks++;
    endtask
    task commit;
        @(negedge cs); idle=1;
        repeat(3) begin settle(); frame(); end
    endtask
    initial begin
        // Disabled output must bootstrap without receiving any HDMI VS.
        settle();
        if (!oe || hd!=1920 || hmn!=240 || hmx!=1679) $fatal(1,"Startup deadlock or geometry");
        frame(); expect_frame(240,1679,0,1079);
        if (axs!=4 || ays!=3 || axys) $fatal(1,"Aspect readback");
        saved_retimes=retimes;
        @(negedge cv); arx=16; ary=9;
        settle(); frame(); expect_frame(0,1919,0,1079);
        frame();
        if(retimes!=saved_retimes) $fatal(1,"Aspect change shortened raster cadence");
        @(negedge cv); arx=4; ary=3;
        settle(); frame();

        // Deliberately keep a multiword HPS command open across video frames.
        @(negedge cs); idle=0; width=1280; hs=40; hfp=110;
        settle(); frame();
        if(hd!=1920 || vd!=1080 || ht!=2204) $fatal(1,"Partial HPS command published");
        @(negedge cs); height=720; hbp=220; vfp=5; vs=5; vbp=20;
        mode=12; vrr=1;
        commit(); expect_frame(160,1119,0,719);

        // Pixel repetition, limited dimensions and custom aspects preserve
        // the arithmetic/truncation of the previous sys_top calculator.
        @(negedge cs); idle=0; width=720; height=480; pr=1;
        commit(); expect_frame(200,519,0,479);
        @(negedge cs); idle=0; width=1920; height=1080; pr=0;
        free=1; hset=1280; vset=960;
        commit(); expect_frame(320,1599,60,1019);
        @(negedge cs); idle=0; width=1000; height=800; free=0; hset=0; vset=0;
        @(negedge cv); arx=1; ary=0;
        arc1x=13'h1000+900; arc1y=700;
        commit(); expect_frame(50,949,50,749);
        if(axs!=900 || ays!=700 || !axys) $fatal(1,"Custom aspect readback");
        @(negedge cs); idle=0; width=1280; height=1024;
        @(negedge cv); arx=2; ary=0;
        commit(); expect_frame(0,1279,0,1023);

        // A pending calculation must finish with its captured configuration.
        @(negedge cv); arx=4; ary=3;
        wait(dut.state==3);
        @(negedge cs); idle=0; width=640; height=480; mode=8;
        commit(); expect_frame(0,639,0,479);

        // Geometry, framebuffer format, stride and 32-bit base commit together.
        @(negedge cs); idle=0; lfb=1; fb_en=1;
        lhmin=12; lhmax=611; lvmin=10; lvmax=409;
        fw=600; fh=400; fmt=6; stride=2400; base=32'h26abcdef;
        hs[12]=1; vs[12]=1;
        settle(); frame();
        if(ofe || obase!=32'h24000000) $fatal(1,"Partial framebuffer escaped");
        commit(); expect_frame(12,611,10,409);

        // Two different timing packets pending before any output VS must
        // retain both epochs. A latest-value toggle would lose an even count.
        saved_retimes=retimes;
        @(negedge cs); idle=0; width=800; height=600;
        @(negedge cs); idle=1;
        wait(dut.result_q.hdisp==800 && !dut.frame_ready);
        @(negedge cs); idle=0; width=1024; height=768;
        @(negedge cs); idle=1;
        settle(); frame();
        if(hd!=800 || vd!=600 || retimes!=saved_retimes+1) $fatal(1,"First raster epoch lost");
        settle(); frame(); expect_frame(12,611,10,409);
        if(retimes!=saved_retimes+2) $fatal(1,"Second raster epoch lost");

        // Stop either side with a transfer outstanding; the latest value must
        // eventually arrive, with no reset of only one end of the handshake.
        @(negedge cv); run_video=0;
        @(negedge cs); idle=0; lhmin=20; lhmax=619; base=32'h27001234;
        @(negedge cs); idle=1;
        repeat(200) @(posedge cs);
        @(negedge cs); idle=0; lhmin=30; lhmax=629; base=32'h28005678;
        @(negedge cs); idle=1;
        run_video=1;
        repeat(3) begin settle(); frame(); end
        expect_frame(30,629,10,409);
        @(negedge co); run_hdmi=0;
        @(negedge cs); idle=0; lfb=0; fb_en=0; width=800; height=600;
        @(negedge cs); idle=1;
        settle();
        run_hdmi=1;
        repeat(3) begin settle(); frame(); end
        expect_frame(0,799,0,599);

        // Disable on a frame boundary, then re-enable without needing VS.
        @(negedge cs); idle=0; en=0;
        commit(); expect_frame(0,799,0,599);
        @(negedge cs); idle=0; en=1; width=640; height=480;
        @(negedge cs); idle=1;
        settle(); expect_frame(0,639,0,479);
        $display("AT_SCALER_CONFIG_PASS checks=%0d partial_uio=1 aspect=1 repetition=1 framebuffer=1 stopped_clocks=2 bootstrap=1 raster_epochs=2",checks);
        $finish;
    end
    initial begin #10000000; $fatal(1,"Timeout"); end
endmodule
