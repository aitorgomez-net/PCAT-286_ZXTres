`timescale 1ns/1ps
// Focused regression for EGA bus selection. Uses the production AT adapter,
// asynchronous clocks, real register writes and its ordinary VRAM frontend.
module spk286_at_ega_decode_tb;
    logic clk = 0, clk_video = 0, reset = 1, video_reset = 1;
    always #10 clk = ~clk;
    always #17.462 clk_video = ~clk_video;
    logic valid = 0, command_valid = 0, wr = 0, io = 0;
    logic [23:0] address = 0;
    logic [1:0] lanes = 1;
    logic [15:0] write_data = 0;
    wire accept, ready, read_valid;
    wire [15:0] read_data;
    logic [7:0] value;
    integer checks = 0;
    spk286_at_video_adapter dut (
        .clk(clk), .reset(reset), .video_reset_in(video_reset),
        .clk_video(clk_video), .prebios_video(1'b0), .splashscreen(1'b0),
        .ega_monitor_profile(2'd0), .vga_enabled(1'b0), .vga_mode13_native(1'b0),
        .crt_h_offset(4'd6), .crt_v_offset(3'd4),
        .vsync_width_osd(3'd0), .hsync_width_osd(3'd0),
        .request_valid(valid), .request_command_valid(command_valid),
        .request_write(wr), .request_io(io), .request_address(address),
        .request_byte_enable(lanes), .request_data_out(write_data),
        .request_accept(accept), .request_ready(ready),
        .request_read_data(read_data), .request_read_data_valid(read_valid)
    );
    task automatic access_byte(input bit write_cycle, io_cycle,
                               input logic [23:0] addr, input logic [7:0] data_byte);
        integer waited;
        @(negedge clk);
        valid=1; command_valid=1; wr=write_cycle; io=io_cycle; address=addr;
        lanes=addr[0] ? 2'b10 : 2'b01;
        write_data=addr[0] ? {data_byte,8'h00} : {8'h00,data_byte};
        #1;
        if (!accept) $fatal(1,"Request not accepted at %06h",addr);
        @(negedge clk); command_valid=0; waited=0;
        while (!ready && waited<256) begin @(negedge clk); waited++; end
        if (!ready || (!write_cycle && !read_valid)) $fatal(1,"Incomplete access at %06h",addr);
        value=addr[0] ? read_data[15:8] : read_data[7:0];
        @(negedge clk); valid=0;
        repeat(2) @(negedge clk);
    endtask
    task automatic outb(input logic [15:0] port, input logic [7:0] data_byte);
        access_byte(1,1,{8'd0,port},data_byte);
    endtask
    task automatic indexed(input logic [15:0] port, input logic [7:0] index, data_byte);
        outb(port,index); outb(port+1,data_byte);
    endtask
    task automatic expect_read(input bit io_cycle, input logic [23:0] addr, input logic [7:0] expected);
        access_byte(0,io_cycle,addr,0); checks++;
        if (value !== expected) $fatal(1,"Read %06h=%02h expected %02h",addr,value,expected);
    endtask
    function automatic [31:0] latches();
        return {dut.u_vram.u_ega_vram.latch_plane3,dut.u_vram.u_ega_vram.latch_plane2,
                dut.u_vram.u_ega_vram.latch_plane1,dut.u_vram.u_ega_vram.latch_plane0};
    endfunction
    logic [23:0] first_addr, last_addr, outside_addr;
    logic [31:0] saved_latches;
    logic hit;
    initial begin
        repeat(20) @(negedge clk); reset=0; video_reset=0;
        repeat(20) @(negedge clk);
        outb('h3c2,'h03);
        indexed('h3c4,2,1); indexed('h3c4,4,6);
        indexed('h3ce,0,0); indexed('h3ce,1,0); indexed('h3ce,3,0);
        indexed('h3ce,4,0); indexed('h3ce,5,0); indexed('h3ce,8,'hff);
        for(integer map=0;map<4;map++) begin
            indexed('h3ce,6,8'((map<<2)|1));
            // Deliberately no artificial delay after the I/O handshake.
            case(map)
                0: begin first_addr='ha0000; last_addr='hbffff; end
                1: begin first_addr='ha0000; last_addr='haffff; end
                2: begin first_addr='hb0000; last_addr='hb7fff; end
                3: begin first_addr='hb8000; last_addr='hbffff; end
            endcase
            access_byte(1,0,first_addr,'h5a); expect_read(0,first_addr,'h5a);
            access_byte(1,0,last_addr,'hc3); expect_read(0,last_addr,'hc3);
            for(integer quarter=0;quarter<4;quarter++) begin
                outside_addr=24'h0a0000+24'(quarter*'h8000);
                hit=(map==0) || (map==1 && quarter<2) || (map==2 && quarter==2) || (map==3 && quarter==3);
                if(!hit) begin
                    expect_read(0,first_addr,'h5a); saved_latches=latches();
                    expect_read(0,outside_addr,'hff);
                    if(latches() !== saved_latches) $fatal(1,"Outside read changed latches");
                    access_byte(1,0,outside_addr,'ha5);
                    if(latches() !== saved_latches) $fatal(1,"Outside write changed latches");
                    expect_read(0,first_addr,'h5a);
                    expect_read(0,outside_addr+'h7fff,'hff);
                    access_byte(1,0,outside_addr+'h7fff,'ha6);
                    expect_read(0,last_addr,'hc3);
                end
            end
        end
        // Misc Output RAM disable rejects selected addresses too.
        expect_read(0,'hb8000,'h5a); saved_latches=latches();
        outb('h3c2,'h01);
        expect_read(0,'hb8000,'hff); access_byte(1,0,'hb8000,'h99);
        if(latches() !== saved_latches) $fatal(1,"Disabled RAM changed latches");
        outb('h3c2,'h03); expect_read(0,'hb8000,'h5a);
        // IBM EGA write-only register groups must not disclose stored values.
        foreach_port_reads();
        indexed('h3d4,'h00,'h55); expect_read(1,'h3d5,'hff);
        indexed('h3d4,'h0c,'h12); expect_read(1,'h3d5,'h12);
        indexed('h3d4,'h0d,'h34); expect_read(1,'h3d5,'h34);
        indexed('h3d4,'h0e,'h23); expect_read(1,'h3d5,'h23);
        indexed('h3d4,'h0f,'h45); expect_read(1,'h3d5,'h45);
        indexed('h3d4,'h10,'h67); expect_read(1,'h3d5,0);
        indexed('h3d4,'h11,'h2b); expect_read(1,'h3d5,0);
        // An inactive status port must not reset the attribute flip-flop.
        access_byte(0,1,'h3da,0); outb('h3c0,'h12);
        if(dut.u_ega.ega_attr.address_phase !== 0) $fatal(1,"ATC was not in data phase");
        expect_read(1,'h3ba,'hff);
        if(dut.u_ega.ega_attr.address_phase !== 0) $fatal(1,"Inactive status reset ATC");
        access_byte(0,1,'h3da,0);
        if(value=='hff || dut.u_ega.ega_attr.address_phase !== 1) $fatal(1,"Active status failed");
        outb('h3c2,'h02);
        expect_read(1,'h3da,'hff); expect_read(1,'h3d5,'hff);
        outb('h3b4,'h0c); expect_read(1,'h3b5,'h12);
        access_byte(0,1,'h3ba,0); if(value=='hff) $fatal(1,"Mono status missing");
        // CPU-only reset must preserve the decode fields of the live EGA.
        reset=1; repeat(8) @(negedge clk); reset=0; repeat(8) @(negedge clk);
        if(dut.ega_mem_map_host_q !== 3 || dut.ega_gfx_index_host_q !== 6 ||
           dut.ega_ram_enable_host_q !== 1) $fatal(1,"CPU reset changed live EGA decode");
        video_reset=1; repeat(8) @(negedge clk); video_reset=0; repeat(8) @(negedge clk);
        if(dut.ega_mem_map_host_q !== 0 || dut.ega_gfx_index_host_q !== 0 ||
           dut.ega_ram_enable_host_q !== 1) $fatal(1,"Video reset missed decode defaults");
        $display("EGA_DECODE_PASS checks=%0d maps=4 boundaries=1 latches=1 ram_disable=1 ports=1 reset=1",checks);
        $finish;
    end
    task automatic foreach_port_reads;
        expect_read(1,'h3c0,'hff); expect_read(1,'h3c1,'hff);
        expect_read(1,'h3c4,'hff); expect_read(1,'h3c5,'hff);
        expect_read(1,'h3cc,'hff); expect_read(1,'h3cd,'hff);
        expect_read(1,'h3ce,'hff); expect_read(1,'h3cf,'hff);
        expect_read(1,'h3c7,'hff); expect_read(1,'h3c8,'hff);
        expect_read(1,'h3c9,'hff); expect_read(1,'h3d4,'hff);
        expect_read(1,'h3b5,'hff);
    endtask
    initial begin #2000000; $fatal(1,"Global timeout"); end
endmodule
