`timescale 1ns/1ps
module at_cdc_snapshot_tb;
    reg src_clk=0, dst_clk=0, src_run=1, dst_run=1, send=0;
    integer src_half=7, dst_half=3;
    reg [63:0] data=0;
    wire ready, update;
    wire [63:0] received;
    reg [63:0] expected [0:4095];
    integer written=0, readn=0, samples=0;
    reg [63:0] held=0;
    reg busy_prev=0;
    always begin #(src_half); if(src_run) src_clk=~src_clk; end
    always begin #(dst_half); if(dst_run) dst_clk=~dst_clk; end
    at_cdc_snapshot #(.WIDTH(64)) dut(src_clk,send,data,ready,dst_clk,received,update);
    always @(posedge src_clk) begin
        if (busy_prev && dut.payload_q !== held) $fatal(1,"Payload changed while in flight");
        if(send && ready) begin
            expected[written]=data; written=written+1;
        end
        #0.001;
        held=dut.payload_q;
        busy_prev=!ready;
    end
    always @(posedge dst_clk) begin
        #0.002;
        if(update) begin
            if(readn>=written || received !== expected[readn]) $fatal(1,"Lost/torn/reordered snapshot %d",readn);
            readn=readn+1;
        end
    end
    always @(negedge src_clk) if(send) begin
        samples=samples+1;
        data={32'(samples),~32'(samples)};
    end
    initial begin
        #31; send=1;
        #2200; @(negedge dst_clk); dst_run=0;
        #713; dst_run=1;
        #2100; @(negedge src_clk); src_run=0;
        #521; src_run=1;
        #1400; src_half=2; dst_half=11;
        #3200; @(negedge src_clk); send=0;
        #200;
        if(readn != written || readn<70) $fatal(1,"Final delivery mismatch %d/%d",readn,written);
        $display("AT_CDC_SNAPSHOT_PASS accepted=%0d",readn); $finish;
    end
    initial begin #20000; $fatal(1,"Timeout"); end
endmodule
