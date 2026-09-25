`timescale 1ns/1ps
module at_video_options_cdc_tb;
    reg clk_sys=0, clk_video=0, run_video=1;
    always #10 clk_sys=~clk_sys;
    always #8.73 if(run_video) clk_video=~clk_video;
    reg clk_out=0;
    initial begin
        #4.365;
        forever begin #8.73; if(run_video) clk_out=~clk_out; end
    end
    reg src_idle=1, video_reset=1, vblank=0;
    reg [6:0] options=0;
    wire [1:0] scale;
    wire [2:0] display;
    wire [12:0] arx,ary;
    wire [30:0] visible={scale,display,arx,ary};
    reg fb_en=0;
    wire [1:0] reported_scanlines;
    integer checked=0;
    at_video_options_cdc dut(.*);
    // Production readback samples the related +90 degree video clock, then
    // crosses back to the independent 50 MHz HPS clock.
    at_scanlines_status readback (
        .clk_video(clk_out), .clk_sys(clk_sys),
        .scanlines({scale==2'd3,scale==2'd2}),
        .fb_en(fb_en), .status(reported_scanlines)
    );
    always @(posedge clk_sys) begin
        #0.001;
        if(reported_scanlines === 2'b11 || ^reported_scanlines === 1'bx)
            $fatal(1,"Invalid/torn scanline readback");
    end

    function [30:0] decoded(input [6:0] cfg);
        decoded={cfg[3:2],cfg[6:4],
                 cfg[1:0]==0 ? 13'd4 : (13'(cfg[1:0])-13'd1),
                 cfg[1:0]==0 ? 13'd3 : 13'd0};
    endfunction
    always @(posedge clk_video) begin : check_boundary
        reg [30:0] previous;
        reg may_change;
        previous=visible;
        may_change=video_reset || (vblank && !dut.vblank_q);
        #0.001;
        if(!may_change && visible !== previous)
            $fatal(1,"OSD options changed during active frame");
        if(^visible === 1'bx) $fatal(1,"Unknown OSD option");
    end
    task check(input [6:0] cfg);
        if(visible !== decoded(cfg))
            $fatal(1,"Wrong options: cfg=%h visible=%h expected=%h",cfg,visible,decoded(cfg));
        repeat(30) @(negedge clk_sys);
        if(reported_scanlines !== (fb_en ? 2'b00 : {cfg[3:2]==2'd3,cfg[3:2]==2'd2}))
            $fatal(1,"Wrong HPS scanline readback for options=%h: %h",cfg,reported_scanlines);
        checked++;
    endtask
    task boundary;
        @(negedge clk_video); vblank=1;
        repeat(3) @(negedge clk_video);
        vblank=0;
        repeat(3) @(negedge clk_video);
    endtask
    task settle;
        repeat(50) @(negedge clk_video);
    endtask
    task select_options(input [6:0] cfg);
        @(negedge clk_sys); src_idle=0; options=cfg;
        repeat(3) @(negedge clk_sys);
        src_idle=1;
        settle();
    endtask
    initial begin
        settle(); check(0); video_reset=0;
        // All aspect / scale / display combinations, with unrelated phases.
        for(integer i=0;i<128;i++) begin
            select_options(7'(i*37)); boundary(); check(7'(i*37));
        end
        // A field spanning HPS words must not expose intermediate values,
        // even if a vertical blank occurs between the words.
        @(negedge clk_sys); src_idle=0; options=7'h04;
        settle(); boundary(); check(7'(127*37));
        @(negedge clk_sys); options=7'h64;
        settle(); boundary(); check(7'(127*37));
        @(negedge clk_sys); src_idle=1;
        settle(); boundary(); check(7'h64);
        // A stopped destination holds the in-flight bus. Later selections
        // coalesce to the latest complete value when clocks return.
        @(negedge clk_video); run_video=0;
        @(negedge clk_sys); options=7'h11;
        repeat(20) @(negedge clk_sys);
        options=7'h42;
        repeat(20) @(negedge clk_sys);
        options=7'h73;
        repeat(20) @(negedge clk_sys);
        run_video=1; settle(); boundary(); check(7'h73);
        // A local video reset must neither reset one side of the handshake
        // nor permanently erase the unchanged source configuration.
        @(negedge clk_video); video_reset=1;
        select_options(7'h26); check(7'h26);
        @(negedge clk_video); video_reset=0;
        settle(); check(7'h26);
        @(negedge clk_sys); fb_en=1;
        select_options(7'h2e); boundary(); check(7'h2e);
        @(negedge clk_sys); fb_en=0;
        check(7'h2e);
        $display("AT_VIDEO_OPTIONS_CDC_PASS combinations=128 checks=%0d partial_transaction=1 stopped_clock=1 video_reset=1 scanlines_readback=1 framebuffer_override=1",checked);
        $finish;
    end
    initial begin #1000000; $fatal(1,"Video options timeout"); end
endmodule
