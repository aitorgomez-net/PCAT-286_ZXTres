`timescale 1ns/1ps
module spk286_target_handoff_tb;
    logic clk=0;
    always #5 clk=!clk;
    logic reset=1, historical_enable=1, cpu_boundary=0;
    logic cancel=0, preserve_cancel=0, start_interval=0, start_body=0;
    logic source_retire, requires_target_length=1, redirect_event=0;
    logic preview_complete=0, preview_fault=0;
    logic [3:0] preview_length=0;
    wire pending, preview_enable, target_length_ready, target_fault_estimated;
    wire [3:0] target_length_clocks;
    logic metadata_valid=1, metadata_freeze=0;
    logic [9:0] metadata_clocks=7, repeat_next_clocks=5;
    logic read_wait_event=0, alignment_event=0, functional_retired=0, repeat_checkpoint=0;
    wire active, body_active, retire_pending, head_permit, deadline_ready, retire_fire;
    wire [9:0] elapsed_clocks, scheduled_clocks;
    wire implementation_extension;
    integer checks=0, publications=0;
    spk286_target_handoff handoff(.*);
    spk286_instruction_schedule schedule(.execution_metadata_valid(metadata_valid),
        .execution_metadata_clocks(metadata_clocks),
        .execution_metadata_sum_bits(12'd0), .execution_metadata_carry_bits(12'd0),
        .execution_read_wait_event(read_wait_event), .*);
    assign source_retire=retire_fire;

    task automatic check(input logic condition,input string label);
        begin
            if(!condition) $fatal(1,"HANDOFF_ORACLE_FAILED %s age%0d budget%0d ready%0d",
                                 label,elapsed_clocks,scheduled_clocks,target_length_ready);
            checks=checks+1;
        end
    endtask
    task automatic edge_begin(input logic boundary);
        begin @(negedge clk); cpu_boundary=boundary; #1; end
    endtask
    task automatic edge_end;
        begin
            if(retire_fire) publications=publications+1;
            @(posedge clk); #1;
        end
    endtask
    task automatic tick(input logic boundary);
        begin edge_begin(boundary); edge_end(); end
    endtask
    task automatic clear;
        begin
            reset=1; historical_enable=1; cancel=0; start_interval=0; start_body=0;
            requires_target_length=1; redirect_event=0; preview_complete=0; preview_fault=0;
            preview_length=0; metadata_valid=1; metadata_freeze=0; metadata_clocks=7;
            functional_retired=0; repeat_checkpoint=0; read_wait_event=0; alignment_event=0;
            publications=0; tick(0); reset=0;
        end
    endtask
    task automatic start;
        begin
            edge_begin(1); start_interval=1; start_body=1; edge_end();
            start_interval=0; start_body=0;
            check(active&&body_active&&target_length_ready,"source interval starts with no stale redirect");
        end
    endtask
    task automatic redirect;
        begin
            edge_begin(0); redirect_event=1; #1;
            check(target_length_ready&&!functional_retired&&!retire_fire,
                  "redirect precedes raw END and changes only retained deadline state");
            edge_end(); redirect_event=0;
            check(pending&&preview_enable&&!target_length_ready,"redirect retains a pending preview token");
        end
    endtask
    task automatic complete(input integer length,input logic fault);
        begin
            edge_begin(0); preview_complete=1; preview_fault=fault; preview_length=4'(length);
            check(!retire_fire,"preview never fabric-publishes a source retirement"); edge_end();
            preview_complete=0; preview_fault=0;
            check(target_length_ready&&!preview_enable,"complete target remains qualified until source boundary");
            check(target_length_clocks==(fault?4'd0:4'(length)),"encoded bytes charged once to source");
            check(target_fault_estimated==fault,"invalid/unavailable target uses an explicit estimated policy");
        end
    endtask
    initial begin
        // Each full instruction length1..10 has identical source placement and
        // base. No successor instruction starts or supplies a second budget.
        for(integer len=1;len<=10;len=len+1) begin
            clear(); start(); redirect();
            functional_retired=1; metadata_freeze=1; tick(0);
            functional_retired=0; metadata_freeze=0;
            tick(1); complete(len,0);
            check(scheduled_clocks==10'(7+len),"source base plus complete encoding");
            // A repeated completion cannot replace a retained length.
            preview_length=1; preview_complete=1; tick(0); preview_complete=0;
            check(target_length_clocks==4'(len),"target terminal qualification is single use");
            for(integer age=2;age<7+len;age=age+1) begin
                edge_begin(1); check(!retire_fire,"no source publication before base plus length"); edge_end();
            end
            edge_begin(1); check(retire_fire,"exact base plus encoding source boundary"); edge_end();
            check(publications==1&&!pending&&!active,"single retirement clears source token");
        end

        // Late target data after the source's raw END must not strand the
        // scheduler with frozen incomplete metadata, or publish at base7.
        clear(); start(); redirect(); functional_retired=1; metadata_freeze=1; tick(0);
        functional_retired=0; metadata_freeze=0;
        for(integer age=1;age<=20;age=age+1) begin
            edge_begin(1); check(!retire_fire,"missing target bytes survive raw END and elapsed deadline"); edge_end();
        end
        complete(10,0); edge_begin(1); check(retire_fire,"late target uses max dependency and17-clock minimum"); edge_end();
        check(publications==1,"late source publication is not replayed");

        // Conversely, a fully qualified target cannot bypass unresolved
        // source stack/operand/READY dependencies.
        clear(); start(); redirect(); complete(3,0);
        for(integer age=1;age<=15;age=age+1) tick(1);
        check(!retire_pending&&implementation_extension,"source functional completion remains independent");
        functional_retired=1; edge_begin(1); check(retire_fire,"late real source dependency gates retirement"); edge_end();
        functional_retired=0; check(publications==1,"late raw dependency consumes one token");

        clear(); start(); redirect(); complete(2,0);
        alignment_event=1; tick(0); tick(0); alignment_event=0;
        functional_retired=1; tick(0); functional_retired=0;
        read_wait_event=1; tick(1); tick(1); read_wait_event=0;
        check(scheduled_clocks==13&&elapsed_clocks==0,
              "source odd references and productive READ wait remain separate from target bytes");
        for(integer age=1;age<13;age=age+1) begin
            edge_begin(1); check(!retire_fire,"odd corrections plus target allowance do not double-charge READ service"); edge_end();
        end
        edge_begin(1); check(retire_fire,"base7 plus odd4 plus length2 after independent READ waits"); edge_end();

        // Not-taken Jcond has no actual redirect. LOOP has an actual redirect
        // but source form eligibility is false; both retain their base only.
        clear(); start(); requires_target_length=1;
        functional_retired=1; tick(0); functional_retired=0;
        for(integer age=1;age<7;age=age+1) tick(1);
        edge_begin(1); check(retire_fire&&target_length_clocks==0&&!pending,"no taken redirect no allowance"); edge_end();
        clear(); metadata_clocks=8; start(); requires_target_length=0;
        redirect_event=1; tick(0); redirect_event=0;
        check(!pending&&target_length_ready&&!preview_enable,"LOOP redirect has no Intel target note");
        functional_retired=1; tick(0); functional_retired=0;
        for(integer age=1;age<8;age=age+1) tick(1);
        edge_begin(1); check(retire_fire&&scheduled_clocks==8,"LOOP remains eight clocks"); edge_end();

        // Unavailable or malformed successor length does not become a source
        // branch fault. The CPU caller retains the successor fault and IP.
        clear(); start(); redirect(); functional_retired=1; tick(0); functional_retired=0;
        complete(0,1);
        for(integer age=1;age<7;age=age+1) tick(1);
        edge_begin(1); check(retire_fire&&scheduled_clocks==7&&target_fault_estimated,"explicit unknown target fault policy retires source"); edge_end();

        // An illegal successful-preview contract (length0/11..15 without a
        // fault token) must not masquerade as a normal one-byte instruction.
        clear(); start(); redirect();
        preview_complete=1; preview_length=0; tick(0);
        check(!target_length_ready&&pending,"normal preview length0 is not qualified");
        for(integer len=11;len<=15;len=len+1) begin
            preview_length=4'(len); tick(0); check(!target_length_ready,"normal preview overlength is not qualified");
        end
        preview_complete=0; complete(0,1);

        clear(); start();
        preview_complete=1; preview_length=4; redirect(); preview_complete=0;
        check(pending&&!target_length_ready&&target_length_clocks==0&&preview_enable,
              "stale parser terminal cannot bind on a new source redirect edge");
        complete(3,0); check(target_length_clocks==3,"fresh target encoding qualifies after new redirect");

        clear(); start(); redirect(); cancel=1; tick(0); cancel=0;
        preview_complete=1; preview_length=5; tick(0); preview_complete=0;
        check(!pending&&target_length_ready&&target_length_clocks==0,"cancel drops stale redirect and late response");
        clear(); start(); redirect(); reset=1; tick(0); reset=0;
        preview_complete=1; preview_length=5; tick(0); preview_complete=0;
        check(!pending&&target_length_ready,"reset invalidates handoff epoch");
        clear(); start(); redirect(); complete(2,0);
        start_interval=1; tick(0); start_interval=0;
        check(!pending&&target_length_clocks==0,"new source admission never inherits predecessor bytes");

        clear(); start(); redirect(); complete(4,0); historical_enable=0; #1;
        check(target_length_ready&&target_length_clocks==0&&!pending&&!preview_enable,
              "MAX immediately masks an existing historical handoff token");
        for(integer bits=0;bits<32;bits=bits+1) begin
            edge_begin(bits[0]); redirect_event=bits[1]; preview_complete=bits[2];
            preview_fault=bits[3]; functional_retired=bits[4]; preview_length=4'(bits);
            #1; check(target_length_ready&&target_length_clocks==0&&!pending&&!preview_enable,
                      "MAX bypasses all target timing/storage state");
            check(retire_fire==functional_retired&&head_permit,"MAX original raw publication and head permit"); edge_end();
        end
        $display("TARGET_HANDOFF_PASS checks=%0d",checks); $finish;
    end
endmodule
