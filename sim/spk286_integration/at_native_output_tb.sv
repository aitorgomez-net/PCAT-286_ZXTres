`timescale 1ns/1ps
module at_native_output_tb;
    parameter real HDMI_HALF_NS=3.366, HDMI_PHASE_NS=0.0;
    reg sys=0, video=0, hdmi=0;
    reg run_video=1, run_hdmi=1;
    always #10 sys=~sys;
    always #8.730 if(run_video) video=~video;
    initial begin
        #(HDMI_PHASE_NS);
        forever #(HDMI_HALF_NS) if(run_hdmi) hdmi=~hdmi;
    end
    reg idle=1, direct=0, fb=0, csync=0;
    reg [26:0] vp=0, hp=0;
    reg hcs=0;
    wire sel;
    wire tx=sel ? video : hdmi;
    wire [26:0] out;
    at_hdmi_output dut (
        .clk_sys(sys),.clk_video(video),.clk_hdmi(hdmi),.clk_tx(tx),
        .src_idle(idle),.direct_video(direct),.vga_fb(fb),.csync(csync),
        .direct_pixel(vp),.scaled_pixel(hp),.scaled_csync(hcs),
        .select_direct(sel),.tx_pixel(out)
    );
    // Independent timestamped source histories define the expected latency:
    // three native video edges in direct mode, two HDMI edges in scaled mode.
    reg [26:0] vh0=0, vh1=0, vh2=0, hh0=0, hh1=0;
    reg expect_csync=0;
    integer vcount=0,hcount=0,vdone=0,hdone=0;
    always @(negedge video) begin
        vcount=vcount+1;
        vp={vcount[4],vcount[6],1'b1,8'h56,vcount[15:0]};
    end
    always @(negedge hdmi) begin
        hcount=hcount+1;
        hp={hcount[3],hcount[7],1'b1,8'hA9,hcount[15:0]};
        hcs=~hcount[3];
    end
    always @(posedge video) begin
        vh2=vh1; vh1=vh0; vh0=vp;
        #0.001;
        if(sel && !dut.reset_sync && !dut.switch_reset_q) begin
            // reset_sync may just have fallen: that edge still held the I/O reset.
            if(out!==0) begin
                if(out!==vh2) $fatal(1,"Direct pixel lost/mixed: got=%h expected=%h",out,vh2);
                vdone=vdone+1;
            end
        end
    end
    always @(posedge hdmi) begin
        hh1=hh0; hh0={expect_csync ? hcs : hp[26],hp[25:0]};
        #0.001;
        if(!sel && !dut.reset_sync && !dut.switch_reset_q && check_scaled) begin
            if(out!==0) begin
                if(out!==hh1) $fatal(1,"Scaled pixel lost/mixed: got=%h expected=%h",out,hh1);
                hdone=hdone+1;
            end
        end
    end
    reg check_scaled=1;
    // On every released TX edge the selected source must supply a pixel. This
    // also rejects extra edges from an unrelated input clock while running.
    always @(posedge tx) begin : tx_check
        reg was_reset;
        reg [26:0] expected;
        was_reset=dut.reset_sync;
        // The histories are updated on the source edge in other processes;
        // defer their read until those updates have completed.
        #0.002;
        expected=sel ? vh2 : hh1;
        if(!was_reset && (sel || check_scaled) && out!==expected)
            $fatal(1,"TX edge not aligned to its selected source got=%h expected=%h",out,expected);
    end
    always @(sel) if($time>0 && (!dut.switch_reset_q || !dut.reset_sync))
        $fatal(1,"Clock/data selection changed outside transmitter reset");
    always @(posedge tx) begin
        if(dut.switch_reset_q) begin
            #0.001;
            if(out!==0) $fatal(1,"Visible pixel during clock change");
        end
    end

    reg vs=0;
    reg [39:0] phase=0;
    reg [16:0] burst=0;
    reg pal=0,cvbs=0,yc=0,sub=0,acsync=0,aidle=1;
    wire [39:0] phase_v;
    wire [16:0] burst_v;
    wire pal_v,cvbs_v,yc_v,sub_v,csync_v;
    at_video_output_config config_dut (
        .clk_sys(sys),.clk_video(video),.src_idle(aidle),.video_vs(vs),
        .phase_inc(phase),.burst_range(burst),.pal(pal),.cvbs(cvbs),.yc(yc),
        .subcarrier_enable(sub),.csync(acsync),.phase_video(phase_v),
        .burst_video(burst_v),.pal_video(pal_v),.cvbs_video(cvbs_v),
        .yc_video(yc_v),.subcarrier_video(sub_v),.csync_video(csync_v)
    );
    wire [61:0] config_value={phase_v,burst_v,pal_v,cvbs_v,yc_v,sub_v,csync_v};
    reg [61:0] expected_config=0;
    task frame_boundary;
        @(negedge video); vs=1;
        repeat(4) @(negedge video);
        vs=0;
        repeat(4) @(negedge video);
    endtask
    task expect_config(input [61:0] value);
        if(config_value!==value) $fatal(1,"Partial/wrong analog config got=%h expected=%h",config_value,value);
    endtask
    // Check the real accumulator formula without resetting phase on an update.
    reg [39:0] accum=0;
    reg carrier=1;
    reg [39:0] model_accum=0;
    reg model_carrier=1;
    always @(posedge video) begin
        accum<=accum+phase_v;
        carrier<=~sub_v | accum[39];
        model_carrier=~sub_v | model_accum[39];
        model_accum=model_accum+phase_v;
        #0.001;
        if(accum!==model_accum || carrier!==model_carrier) $fatal(1,"Subcarrier phase discontinuity");
    end
    integer config_checks=0;
    initial begin
        #2000;
        expect_config(0);
        // A split 40-bit phase command must not leak intermediate writes, even
        // if there is a long bus pause and VS occurs during the transaction.
        @(negedge sys); aidle=0;
        phase[15:0]=16'hA531;
        #400; frame_boundary(); expect_config(0);
        phase[31:16]=16'h89CD;
        #600; frame_boundary(); expect_config(0);
        phase[39:32]=8'h12; burst=17'h12345; pal=1; cvbs=1; yc=1; sub=1; acsync=1;
        expected_config={phase,burst,pal,cvbs,yc,sub,acsync};
        #100;
        @(negedge sys); aidle=1;
        #600; expect_config(0);
        frame_boundary(); expect_config(expected_config); config_checks++;
        // Both clocks can pause independently with a packet in flight.
        @(negedge video); run_video=0;
        @(negedge sys); aidle=0; phase=40'h4567891234; sub=0; yc=0;
        #100; aidle=1;
        #1000; expect_config(expected_config);
        run_video=1;
        #600; expect_config(expected_config);
        frame_boundary();
        expected_config={phase,burst,pal,cvbs,yc,sub,acsync};
        expect_config(expected_config); config_checks++;
        // A short disable command preserves the untouched phase/burst fields.
        @(negedge sys); aidle=0; pal=0; cvbs=0; yc=0;
        #100; aidle=1;
        #600; frame_boundary();
        expected_config={phase,burst,pal,cvbs,yc,sub,acsync};
        expect_config(expected_config); config_checks++;
    end
    initial begin
        #2000;
        // Normal HDMI must start without any direct-video mode transition.
        if(sel || dut.switch_reset_q || dut.reset_sync || hdone < 10)
            $fatal(1,"Cold scaled startup did not release reset and transmit");
        // Partial UIO config cannot change the selected source.
        @(negedge sys); idle=0; direct=1;
        #1600;
        if(sel) $fatal(1,"Direct mode committed inside UIO");
        idle=1;
        #1800;
        if(!sel) $fatal(1,"Direct mode did not select native video clock");
        #2500;
        // Scaled framebuffer overrides direct mode, including CSync routing.
        check_scaled=0; csync=1; expect_csync=1;
        @(negedge sys); idle=0; fb=1;
        #100; idle=1;
        #1800; check_scaled=1;
        if(sel) $fatal(1,"Framebuffer must select HDMI PLL");
        #2000;
        // Return to direct while HDMI PLL is stopped. The native stream must
        // resume independently; the TX reset asserts without any clock edges.
        @(negedge hdmi); run_hdmi=0;
        @(negedge sys); fb=0;
        #1800;
        if(!sel || dut.reset_sync) $fatal(1,"Direct mode depends on stopped HDMI PLL");
        #1800;
        run_hdmi=1;
        #100;
        // Stop native video before switching back: source reset is asynchronous.
        @(negedge video); run_video=0;
        check_scaled=0;
        @(negedge sys); direct=0; csync=0; expect_csync=0;
        #1800; check_scaled=1;
        if(sel || dut.reset_sync) $fatal(1,"Scaled mode depends on stopped native clock");
        #1400; run_video=1;
        #600;
        if(vdone<100 || hdone<100 || config_checks!=3) $fatal(1,"Insufficient coverage %0d %0d %0d",vdone,hdone,config_checks);
        $display("AT_NATIVE_OUTPUT_PASS direct_pixels=%0d scaled_pixels=%0d config_transactions=%0d",vdone,hdone,config_checks);
        $finish;
    end
    initial begin #100000; $fatal(1,"Watchdog"); end
endmodule
