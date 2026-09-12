`timescale 1ns/1ps
module spk286_at_dma_registers_tb;
    logic clk=0, reset=1;
    always #5 clk=~clk;
    logic request_valid=0, request_command_valid=0, request_write=0;
    logic request_io=0;
    logic [23:0] request_address=0;
    logic [1:0] request_byte_enable=0;
    logic [15:0] request_data_out=0;
    wire request_accept, request_ready, request_read_data_valid;
    wire [15:0] request_read_data;
    logic [7:0] dma_request=0;
    logic dma_grant=0, transfer_accept=0, transfer_ready=0;
    wire dma_bus_request, dma_transfer_valid, dma_terminal_count;
    wire [23:0] dma_transfer_address;
    wire [2:0] dma_active_channel;
    wire [1:0] dma_transfer_byte_enable;
    wire protocol_error;
    spk286_at_dma dut (
        .clk, .reset, .request_valid, .request_command_valid, .request_write,
        .request_io, .request_address, .request_byte_enable, .request_data_out,
        .request_accept, .request_ready, .request_read_data, .request_read_data_valid,
        .dma_request, .dma_grant, .transfer_accept, .transfer_ready,
        .transfer_data_in(16'h1234), .dma_bus_request, .dma_transfer_valid,
        .dma_transfer_address, .dma_active_channel, .dma_transfer_byte_enable,
        .dma_terminal_count, .protocol_error,
        .dma_transfer_write_to_memory(), .dma_transfer_read_from_memory(),
        .dma_transfer_io_to_memory(), .dma_transfer_memory_to_io(),
        .dma_transfer_data_out(), .dma_transfer_complete(), .dma_request_state(),
        .dma_acknowledge(), .cascade_request()
    );
    integer accesses=0;
    task automatic access(input bit wr, input logic [15:0] port,
                           input logic [7:0] value, output logic [7:0] data);
        begin
            @(negedge clk);
            request_valid=1; request_command_valid=1; request_io=1;
            request_write=wr; request_address={8'h00,port};
            request_byte_enable=port[0] ? 2'b10 : 2'b01;
            request_data_out=port[0] ? {value,8'h00} : {8'h00,value};
            #1;
            if(!request_accept) $fatal(1,"DMA did not accept port=%h",port);
            @(negedge clk); request_command_valid=0;
            if(!request_ready || (!wr && !request_read_data_valid))
                $fatal(1,"DMA missing completion port=%h",port);
            data=port[0] ? request_read_data[15:8] : request_read_data[7:0];
            accesses=accesses+1;
            @(negedge clk); request_valid=0; request_io=0;
        end
    endtask
    task automatic wr(input logic [15:0] port, input logic [7:0] value);
        logic [7:0] discard;
        access(1,port,value,discard);
    endtask
    task automatic rd(input logic [15:0] port, input logic [7:0] expected);
        logic [7:0] data;
        begin
            access(0,port,0,data);
            if(data!==expected) $fatal(1,"DMA read port=%h expected=%h got=%h",port,expected,data);
        end
    endtask
    task automatic receive_beat(input logic [2:0] channel,
                                input logic [23:0] address,
                                input logic [1:0] lanes);
        integer guard;
        begin
            guard=0;
            while(!dma_transfer_valid) begin
                @(negedge clk); guard=guard+1;
                if(guard>30) $fatal(1,"DMA transfer missing channel=%d",channel);
            end
            if(dma_active_channel!==channel || dma_transfer_address!==address || dma_transfer_byte_enable!==lanes)
                $fatal(1,"DMA beat channel=%d address=%h lanes=%b",dma_active_channel,dma_transfer_address,dma_transfer_byte_enable);
            transfer_accept=1;
            @(negedge clk); transfer_accept=0; transfer_ready=1;
            @(negedge clk); transfer_ready=0;
        end
    endtask
    integer p, pat, channel;
    logic [15:0] port, page_port;
    initial begin
        repeat(4) @(negedge clk); reset=0;
        // Different values in every latch catch aliasing. Cover all bits and
        // all 16 ports, including the scratch registers used by IBM POST.
        for(pat=0;pat<256;pat=pat+1) begin
            for(p=0;p<16;p=p+1) wr(16'h80+16'(p),8'(pat^p));
            for(p=0;p<16;p=p+1) rd(16'h80+16'(p),8'(pat^p));
        end
        // Controller-local mask/reset/pointer commands must not touch the
        // other bank or masquerade as address/count accesses on DMA2.
        wr(16'h0f,8'h05); wr(16'hde,8'h0a);
        rd(16'h0f,8'h05); rd(16'hde,8'h0a);
        wr(16'hdc,0); rd(16'hde,0); rd(16'h0f,8'h05);
        wr(16'h0e,0); rd(16'h0f,0);
        wr(16'hda,0); rd(16'hde,8'h0f); rd(16'h0f,0);
        wr(16'h0d,0); rd(16'h0f,8'h0f);
        wr(16'h00,8'h34); wr(16'hc0,8'h78); // both pointers now high
        wr(16'hd8,0); wr(16'hc0,8'h56); wr(16'hc0,8'hab);
        wr(16'h00,8'h12); // DMA1 pointer was not reset by D8
        wr(16'h0c,0); wr(16'hd8,0);
        rd(16'h00,8'h34); rd(16'hc0,8'h56);
        rd(16'h00,8'h12); rd(16'hc0,8'hab);
        wr(16'hd0,8'h04); wr(16'hd4,8'h00);
        wr(16'hd6,8'hc0); wr(16'hd2,8'h04);
        wr(16'hd8,0); rd(16'hc0,8'h56); rd(16'hc0,8'hab);
        rd(16'hd0,8'h10); rd(16'hd0,8'h10); // request flag survives status read
        wr(16'hda,0); rd(16'hd0,0);
        wr(16'hd0,8'h04); wr(16'hd4,8'h01); wr(16'hd2,8'h05);
        if(dma_bus_request) $fatal(1,"disabled DMA2 requested ownership");
        wr(16'hd0,0);
        if(!dma_bus_request) $fatal(1,"enabled DMA2 ignored software request");
        wr(16'hda,0);
        // Verify actual page wiring and DMA2 word-to-byte addressing. Each
        // channel performs two beats and reports/clears its own TC status.
        for(channel=0;channel<8;channel=channel+1) if(channel!=4) begin
            wr(16'h0d,0); wr(16'hda,0);
            case(channel)
                0: page_port=16'h87;
                1: page_port=16'h83;
                2: page_port=16'h81;
                3: page_port=16'h82;
                5: page_port=16'h8b;
                6: page_port=16'h89;
                default: page_port=16'h8a;
            endcase
            wr(page_port,8'h2f);
            if(channel<4) begin
                port=16'(channel*2);
                wr(port,8'hfe); wr(port,8'h7f);
                wr(port+1,1); wr(port+1,0);
                wr(16'h0b,8'h84|8'(channel)); wr(16'h0a,8'(channel));
            end else begin
                port=16'hc0+16'((channel-4)*4);
                wr(port,8'hff); wr(port,8'h7f);
                wr(port+2,1); wr(port+2,0);
                wr(16'hd6,8'h84|8'(channel-4)); wr(16'hd4,8'(channel-4));
            end
            dma_request=8'(1<<channel); dma_grant=1;
            if(channel<4) begin
                receive_beat(3'(channel),24'h2f7ffe,2'b01);
                receive_beat(3'(channel),24'h2f7fff,2'b10);
            end else begin
                receive_beat(3'(channel),24'h2efffe,2'b11);
                receive_beat(3'(channel),24'h2f0000,2'b11);
            end
            if(!dma_terminal_count) $fatal(1,"missing TC");
            dma_request=0; dma_grant=0;
            rd(channel<4 ? 16'h08 : 16'hd0,8'(1<<(channel%4)));
            rd(channel<4 ? 16'h08 : 16'hd0,0);
        end
        if(protocol_error) $fatal(1,"unexpected DMA protocol fault");
        $display("AT_DMA_REGISTERS_PASS accesses=%0d channels=7 beats=14",accesses);
        $finish;
    end
    initial begin #10000000; $fatal(1,"DMA register watchdog"); end
endmodule
