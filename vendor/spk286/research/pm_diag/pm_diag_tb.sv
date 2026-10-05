`timescale 1ns/1ps
// CPU-only executable harness. No chipset, BIOS, DOS, or architectural state
// injection: a reset-vector trampoline starts the assembled COM-origin image.
module pm_diag_tb;
    `include "spk286_signals.svh"
    byte unsigned memory [0:1048575];
    byte unsigned reset_code [0:15];
    integer cycles = 0, limit = 2000000, load_segment = 'h1000;
    integer fd, count, screen_fd;
    string image_path, screen_path;
    logic [15:0] halt_cs, halt_ip;
    spk286 dut (.*);

    function automatic [7:0] read_byte(input integer a);
        if (a >= 'hfffff0 && a <= 'hffffff) read_byte = reset_code[a-'hfffff0];
        else if (a >= 0 && a < 1048576) read_byte = memory[a];
        else read_byte = 8'hff;
    endfunction

    task automatic tick;
        integer a;
        begin
            #1;
            ready = bus_valid && ((cycles % 4) != 1);
            a = {8'h00,address};
            data_in = 0;
            if (bus_valid && !bus_write && (bus_status==4'h5 || bus_status==4'hd)) begin
                if (address[0]) data_in = {read_byte(a),8'h00};
                else if (bus_bhe_n) data_in = {8'h00,read_byte(a)};
                else data_in = {read_byte(a+1),read_byte(a)};
            end
            if (bus_valid && ready && bus_write) begin
                if (bus_status==4'h6) begin
                    if (a >= 1048575) $fatal(1,"Out-of-harness write %h",address);
                    if (address[0]) memory[a] = data_out[15:8];
                    else begin
                        memory[a] = data_out[7:0];
                        if (!bus_bhe_n) memory[a+1] = data_out[15:8];
                    end
                end else if (bus_status==4'ha && a=='he9) begin
                    $write("%c",data_out[15:8]);
                end
            end
            #4; clk=1; #5; clk=0; #1;
            cycles=cycles+1;
        end
    endtask

    initial begin
        if (!$value$plusargs("IMAGE=%s",image_path)) $fatal(1,"IMAGE required");
        if (!$value$plusargs("SCREEN=%s",screen_path)) screen_path="build/pm-diag-screen.txt";
        if ($value$plusargs("LOAD_SEG=%h",load_segment)) begin end
        if ($value$plusargs("LIMIT=%d",limit)) begin end
        if (load_segment < 'h1000 || load_segment > 'h8000) $fatal(1,"Unsafe test load segment");
        for (integer i=0; i<1048576; i=i+1) memory[i]=0;
        for (integer i=0; i<16; i=i+1) reset_code[i]=8'h90;
        memory['h449]=3; // Text-aperture hint only; no video hardware modeled.
        fd=$fopen(image_path,"rb");
        if (fd==0) $fatal(1,"Cannot open image %s",image_path);
        count=$fread(memory,fd,load_segment*16+'h100,'hef00);
        $fclose(fd);
        if (count < 100 || count >= 'hef00) $fatal(1,"Invalid executable size %0d",count);
        // CLI; MOV AX,segment; MOV SS,AX; MOV SP,FFFE; JMP segment:0100.
        reset_code[0]='hfa; reset_code[1]='hb8;
        reset_code[2]=load_segment[7:0]; reset_code[3]=load_segment[15:8];
        reset_code[4]='h8e; reset_code[5]='hd0; reset_code[6]='hbc;
        reset_code[7]='hfe; reset_code[8]='hff; reset_code[9]='hea;
        reset_code[10]=0; reset_code[11]=1;
        reset_code[12]=load_segment[7:0]; reset_code[13]=load_segment[15:8];
        tick(); reset=0; execute_enable=1;
        while (!halted && !shutdown && !unsupported_opcode && !microcode_fault && cycles<limit) tick();
        $display("\nHARNESS cycles=%0d halt=%b shutdown=%b unsupported=%b microcode=%b CS:IP=%h:%h MSW=%h",
            cycles,halted,shutdown,unsupported_opcode,microcode_fault,debug_cs,debug_ip,debug_protected_msw);
        $display("HARNESS GDT=%h/%h IDT=%h/%h base=%h event=%h error=%h",
            debug_gdtr_base,debug_gdtr_limit,debug_idtr_base,debug_idtr_limit,
            debug_cs_base,debug_event_vector,dut.event_error_code);
        if (!halted || shutdown || unsupported_opcode || microcode_fault || cycles>=limit)
            $fatal(1,"Executable failed to reach terminal HLT");
        halt_cs=debug_cs; halt_ip=debug_ip;
        repeat (256) tick();
        if (!halted || debug_cs!=halt_cs || debug_ip!=halt_ip) $fatal(1,"Unstable terminal HLT");
        screen_fd=$fopen(screen_path,"w");
        if (screen_fd==0) $fatal(1,"Cannot write screen dump");
        for (integer row=0; row<25; row=row+1) begin
            for (integer col=0; col<80; col=col+1)
                $fwrite(screen_fd,"%c",memory['hb8000+row*160+col*2]);
            $fwrite(screen_fd,"\n");
        end
        $fclose(screen_fd);
        $display("HARNESS_STABLE_HALT_PASS load_segment=%h",load_segment[15:0]);
        $finish;
    end
endmodule
