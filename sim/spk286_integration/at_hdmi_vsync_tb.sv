`timescale 1ns/1ps
module at_hdmi_vsync_tb;
    reg clk_sys=0, clk_hdmi=0, run_sys=1, run_hdmi=1, vs=0;
    always #10 if(run_sys) clk_sys=~clk_sys;
    always #3.367 if(run_hdmi) clk_hdmi=~clk_hdmi;
    wire rise;
    integer edges=0, expected=0;
    reg vs_wait=0, cfg_ready=1, cfg_set=0, cfg_got=0;
    at_hdmi_vsync dut(.clk_sys(clk_sys),.vs(vs),.rise(rise));
    always @(posedge clk_sys) begin
        if(rise) begin edges<=edges+1; vs_wait<=0; end
        if(!cfg_ready || !cfg_set) cfg_got<=cfg_set;
        else if(rise) cfg_got<=cfg_set;
    end
    always @(posedge clk_sys) begin : pipeline_check
        reg meta, sync;
        meta=dut.vs_meta; sync=dut.vs_sync;
        #0.001;
        if(dut.vs_sync!==meta || dut.vs_seen!==sync || rise!==(meta & ~sync))
            $fatal(1,"VS edge bypasses the second synchronizer stage");
    end
    task drain;
        repeat(8) @(negedge clk_sys);
        if(edges!=expected) $fatal(1,"VS edges expected=%0d got=%0d",expected,edges);
    endtask
    task pulse(input integer cycles);
        @(negedge clk_hdmi); vs=1; expected++;
        repeat(cycles) @(negedge clk_hdmi);
        vs=0; drain();
    endtask
    initial begin
        drain();
        for(integer i=0;i<80;i++) pulse(13+i%29);
        // Arm both consumers after a high level has already been received.
        // They must wait for the next edge, not acknowledge the current level.
        @(negedge clk_hdmi); vs=1; expected++; drain();
        @(negedge clk_sys); vs_wait=1; cfg_set=1;
        drain();
        if(!vs_wait || cfg_got) $fatal(1,"Consumer accepted an old VS level");
        @(negedge clk_hdmi); vs=0; drain(); pulse(31);
        if(vs_wait || !cfg_got) $fatal(1,"Consumer missed the next VS edge");
        // Reconfiguration bypass and deassertion retain their old semantics.
        @(negedge clk_sys); cfg_set=0; drain();
        if(cfg_got) $fatal(1,"Configuration acknowledgement did not clear");
        @(negedge clk_sys); cfg_ready=0; cfg_set=1; drain();
        if(!cfg_got) $fatal(1,"Initial PLL configuration deadlocked without VS");
        // A paused HDMI clock must not repeatedly acknowledge a held VS.
        @(negedge clk_hdmi); vs=1; expected++; run_hdmi=0;
        drain(); repeat(20) @(negedge clk_sys); drain(); run_hdmi=1;
        @(negedge clk_hdmi); vs=0; drain();
        // The receiver can stop while the source level is held, then resume.
        @(negedge clk_sys); run_sys=0;
        @(negedge clk_hdmi); vs=1; expected++;
        repeat(30) @(negedge clk_hdmi); run_sys=1; drain();
        @(negedge clk_hdmi); vs=0; drain();
        $display("AT_HDMI_VSYNC_PASS edges=%0d late_arm=1 pll_bootstrap=1 source_pause=1 receiver_pause=1",edges);
        $finish;
    end
    initial begin #100000; $fatal(1,"HDMI VS test timeout"); end
endmodule
