`timescale 1ns/1ps
module spk286_target_replay_tb;
    logic clk=0;
    always #5 clk=!clk;
    logic reset=1, cancel=0, start=0, capture=0, consume=0;
    logic [7:0] capture_data=0;
    wire valid;
    wire [7:0] data;
    wire [3:0] count;
    integer checks=0;
    spk286_target_replay dut(.*);
    task automatic check(input logic condition,input string label);
        begin
            if(!condition) $fatal(1,"REPLAY_ORACLE_FAILED %s count%0d data%02h",label,count,data);
            checks=checks+1;
        end
    endtask
    task automatic edge_begin;
        begin @(negedge clk); #1; end
    endtask
    task automatic edge_end;
        begin @(posedge clk); #1; end
    endtask
    task automatic tick;
        begin edge_begin(); edge_end(); end
    endtask
    task automatic fresh;
        begin
            edge_begin(); start=1; capture=0; consume=0; edge_end(); start=0;
            check(!valid&&count==0&&data==0,"new preview epoch has no stale valid storage");
        end
    endtask
    initial begin
        tick(); reset=0;
        for(integer len=1;len<=10;len=len+1) begin
            fresh();
            for(integer byte_index=0;byte_index<len;byte_index=byte_index+1) begin
                edge_begin(); capture=1; capture_data=8'(len*16+byte_index); edge_end();
                check(valid&&count==4'(byte_index+1)&&data==8'(len*16),
                      "captured target preserves encoding order and exact occupancy");
            end
            capture=0;
            for(integer hold_cycle=0;hold_cycle<3;hold_cycle=hold_cycle+1) begin
                tick(); check(valid&&count==4'(len)&&data==8'(len*16),"held replay cannot pop or fabricate bytes");
            end
            for(integer byte_index=0;byte_index<len;byte_index=byte_index+1) begin
                edge_begin(); consume=1;
                check(valid&&data==8'(len*16+byte_index),"each staged byte is delivered exactly once");
                edge_end(); check(count==4'(len-byte_index-1),"ordinary consume advances one retained byte");
            end
            consume=0; check(!valid&&data==0,"last replay byte clears validity");
            consume=1; tick(); consume=0;
            check(!valid&&count==0&&data==0,"empty consume cannot underflow into stale storage");
        end

        fresh();
        for(integer byte_index=0;byte_index<10;byte_index=byte_index+1) begin
            edge_begin(); capture=1; capture_data=8'(byte_index+1); edge_end();
        end
        capture_data=8'hEE; tick(); capture=0;
        check(count==10&&data==1,"capture beyond ten-byte capacity cannot overrun storage");
        for(integer byte_index=0;byte_index<10;byte_index=byte_index+1) begin
            edge_begin(); consume=1; check(data==8'(byte_index+1),"overrun attempt leaves original bytes intact"); edge_end();
        end
        consume=0;

        fresh(); capture=1; capture_data=8'hA5; tick(); capture=0;
        edge_begin(); start=1; consume=1; capture=1; capture_data=8'hFF; edge_end();
        start=0; consume=0; capture=0;
        check(!valid&&count==0&&data==0,"last old byte with new epoch never leaks or captures stale response");
        capture=1; capture_data=8'h5A; tick(); capture=0;
        check(valid&&count==1&&data==8'h5A,"fresh epoch starts at slot zero");
        cancel=1; consume=1; capture=1; capture_data=8'hFF; tick();
        cancel=0; consume=0; capture=0;
        check(!valid&&count==0&&data==0,"cancel wins over both capture and consume");
        capture=1; capture_data=8'hAB; tick(); capture=0;
        reset=1; tick(); reset=0;
        check(!valid&&count==0&&data==0,"reset wipes validity without exposing uncleared data bits");

        // Empty simultaneous capture/consume retains the newly accepted byte
        // rather than acknowledging a byte that was not valid before the edge.
        fresh(); capture=1; consume=1; capture_data=8'h11; tick(); capture=0; consume=0;
        check(valid&&count==1&&data==8'h11,"empty simultaneous handshake preserves new byte");
        edge_begin(); capture=1; consume=1; capture_data=8'h22; edge_end(); capture=0; consume=0;
        check(valid&&count==1&&data==8'h22,"simultaneous valid transfer preserves successor order");
        consume=1; tick(); consume=0; check(!valid&&count==0,"simultaneous stream terminates once");
        $display("TARGET_REPLAY_PASS checks=%0d",checks); $finish;
    end
endmodule
