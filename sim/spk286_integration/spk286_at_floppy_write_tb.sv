`timescale 1ns/1ps

// Composed WRITE DATA regression: real DMA, serialized memory port, production
// code/data buffers, posted-write boundary and FDC/FIFO. Only physical SDRAM
// and the host image file are modeled. The machine's payload adapter is copied
// verbatim into a generated module by test_at_floppy_write.py.
module spk286_at_floppy_write_tb;
    logic clk = 0;
    always #10 clk = !clk;
    logic reset = 1;
    logic request_valid = 0, request_write = 0;
    logic [23:0] request_address = 0;
    logic [1:0] request_lanes = 0;
    logic [15:0] request_data = 0;
    wire dma_config_accept, dma_config_ready, fdc_accept, fdc_ready;
    wire [15:0] dma_config_data, fdc_data;
    wire dma_config_read_valid, fdc_read_valid;
    wire dma_bus_request, dma_transfer_valid, dma_transfer_complete;
    wire dma_terminal_count, dma_write_memory, dma_read_memory;
    wire [2:0] dma_active_channel;
    wire [23:0] dma_address;
    wire [1:0] dma_lanes;
    wire [15:0] dma_out, fdc_dma_out, dma_memory_data_in, endpoint_data;
    wire [7:0] dma_request;
    wire dma_endpoint_accept, dma_endpoint_ready, dma_memory_accept, dma_memory_ready;
    wire irq6, dma_error, fdc_error, port_error, posted_error;
    logic dma_memory_accept_q = 0;
    wire dma_memory_response_valid = dma_memory_ready && dma_memory_accept_q;
    logic [15:0] mgmt_address = 0, mgmt_writedata = 0;
    logic mgmt_write = 0, mgmt_read = 0;
    wire [15:0] mgmt_readdata;
    wire [1:0] floppy_request, floppy_present;
    integer case_id = 0, completed = 0, tc_count = 0, fifo_bytes = 0;
    integer backend_reads = 0, backend_writes = 0;
    integer expected_start = 0, expected_step = 1;
    logic [15:0] ram [0:4095];
    logic [7:0] image [0:511];
    logic probe_reset=1, probe_valid=0, probe_read=0, probe_response=0, probe_complete=0;
    logic [2:0] probe_channel=0;
    logic [1:0] probe_lanes=0;
    logic [15:0] probe_data=0;
    wire [15:0] probe_endpoint;
    spk286_at_dma_read_payload_adapter u_payload_unit (
        .clk, .reset(probe_reset), .dma_transfer_valid(probe_valid),
        .dma_active_channel(probe_channel), .dma_transfer_byte_enable(probe_lanes),
        .dma_transfer_read_from_memory(probe_read), .dma_memory_response_valid(probe_response),
        .dma_transfer_complete(probe_complete), .dma_memory_data_in(probe_data),
        .dma_endpoint_data(probe_endpoint)
    );

    always_ff @(posedge clk) begin
        if (reset) dma_memory_accept_q <= 0;
        else if (!dma_transfer_valid) dma_memory_accept_q <= 0;
        else if (dma_memory_accept) dma_memory_accept_q <= 1;
    end
    spk286_at_dma_read_payload_adapter u_payload (
        .clk, .reset, .dma_active_channel, .dma_transfer_valid,
        .dma_transfer_byte_enable(dma_lanes), .dma_transfer_read_from_memory(dma_read_memory),
        .dma_memory_data_in, .dma_memory_response_valid, .dma_transfer_complete,
        .dma_endpoint_data(endpoint_data)
    );
    spk286_at_dma u_dma (
        .clk, .reset, .request_valid, .request_command_valid(request_valid),
        .request_write, .request_io(1'b1), .request_address,
        .request_byte_enable(request_lanes), .request_data_out(request_data),
        .request_accept(dma_config_accept), .request_ready(dma_config_ready),
        .request_read_data(dma_config_data), .request_read_data_valid(dma_config_read_valid),
        .dma_request, .dma_grant(dma_bus_request),
        .transfer_accept(dma_endpoint_accept),
        .transfer_ready(dma_endpoint_ready && dma_memory_response_valid),
        .transfer_data_in(dma_read_memory ? dma_memory_data_in : fdc_dma_out),
        .dma_bus_request, .dma_transfer_valid, .dma_active_channel,
        .dma_transfer_address(dma_address), .dma_transfer_byte_enable(dma_lanes),
        .dma_transfer_write_to_memory(dma_write_memory),
        .dma_transfer_read_from_memory(dma_read_memory),
        .dma_transfer_io_to_memory(), .dma_transfer_memory_to_io(),
        .dma_transfer_data_out(dma_out), .dma_transfer_complete, .dma_terminal_count,
        .dma_request_state(), .dma_acknowledge(), .cascade_request(), .protocol_error(dma_error)
    );
    spk286_at_fdc #(.RETAINED_FDC_WRITE(1'b1)) u_fdc (
        .clk, .reset, .request_valid, .request_command_valid(request_valid),
        .request_write, .request_io(1'b1), .request_address,
        .request_byte_enable(request_lanes), .request_data_out(request_data),
        .retained_io_command(request_valid), .retained_io_address(request_address),
        .retained_io_write(request_write), .retained_io_byte_enable(request_lanes),
        .retained_io_data_out(request_data), .request_accept(fdc_accept),
        .request_ready(fdc_ready), .request_read_data(fdc_data),
        .request_read_data_valid(fdc_read_valid), .dma_transfer_valid,
        .dma_transfer_complete, .dma_terminal_count, .dma_active_channel,
        .dma_transfer_data_in(endpoint_data), .dma_transfer_accept(dma_endpoint_accept),
        .dma_transfer_ready(dma_endpoint_ready), .dma_transfer_data_out(fdc_dma_out),
        .dma_request, .irq6, .mgmt_address, .mgmt_writedata, .mgmt_write,
        .mgmt_read, .mgmt_readdata, .floppy_write_protect(2'b00),
        .floppy_present, .floppy_request, .side_effect_count(), .command_count(),
        .protocol_error(fdc_error)
    );

    // These interfaces are the production PCAT order: memory_port -> P03 ->
    // data buffer -> posted write buffer -> physical RAM endpoint.
`define CHAIN_WIRES(N) \
    wire N``_valid, N``_command, N``_write, N``_refresh, N``_code, N``_burst; \
    wire N``_accept, N``_ready, N``_read_valid; \
    wire [1:0] N``_owner, N``_lanes; \
    wire [3:0] N``_class; \
    wire [24:0] N``_address; \
    wire [15:0] N``_data, N``_read_data;
    `CHAIN_WIRES(a)
    `CHAIN_WIRES(b)
    `CHAIN_WIRES(c)
    `CHAIN_WIRES(d)
`undef CHAIN_WIRES
    spk286_at_mister_memory_port u_port (
        .clk, .reset, .cancel_cpu(1'b0), .cpu_valid(1'b0), .cpu_command_valid(1'b0),
        .cpu_write(1'b0), .cpu_code_fetch(1'b0), .cpu_cycle_class(4'd0),
        .cpu_address(25'd0), .cpu_byte_enable(2'b00), .cpu_data_out(16'd0),
        .cpu_accept(), .cpu_ready(), .cpu_read_data(), .cpu_read_data_valid(),
        .loader_valid(1'b0), .loader_write(1'b0), .loader_address(24'd0),
        .loader_byte_enable(2'b00), .loader_data_out(16'd0),
        .loader_accept(), .loader_ready(), .loader_read_data(),
        .dma_valid(dma_transfer_valid), .dma_write(dma_write_memory),
        .dma_address({1'b0,dma_address}), .dma_byte_enable(dma_lanes),
        .dma_data_out(dma_out), .dma_accept(dma_memory_accept),
        .dma_ready(dma_memory_ready), .dma_read_data(dma_memory_data_in),
        .refresh_valid(1'b0), .refresh_address(24'd0), .refresh_accept(), .refresh_ready(),
        .backend_valid(a_valid), .backend_command_valid(a_command), .backend_owner(a_owner),
        .backend_write(a_write), .backend_refresh(a_refresh), .backend_code_fetch(a_code),
        .backend_cycle_class(a_class), .backend_address(a_address),
        .backend_byte_enable(a_lanes), .backend_data_out(a_data),
        .backend_accept(a_accept), .backend_ready(a_ready), .backend_read_data(a_read_data),
        .backend_read_data_valid(a_read_valid), .debug_state(), .protocol_error(port_error)
    );
`define IN_PORTS(N) \
        .in_valid(N``_valid), .in_command_valid(N``_command), .in_owner(N``_owner), \
        .in_write(N``_write), .in_refresh(N``_refresh), .in_code_fetch(N``_code), \
        .in_cycle_class(N``_class), .in_address(N``_address), .in_byte_enable(N``_lanes), \
        .in_data_out(N``_data), .in_accept(N``_accept), .in_ready(N``_ready), \
        .in_read_data(N``_read_data), .in_read_data_valid(N``_read_valid)
`define OUT_PORTS(N) \
        .out_valid(N``_valid), .out_command_valid(N``_command), .out_owner(N``_owner), \
        .out_write(N``_write), .out_refresh(N``_refresh), .out_code_fetch(N``_code), \
        .out_burst(N``_burst), .out_cycle_class(N``_class), .out_address(N``_address), \
        .out_byte_enable(N``_lanes), .out_data_out(N``_data), .out_accept(N``_accept), \
        .out_ready(N``_ready), .out_read_data(N``_read_data), .out_read_data_valid(N``_read_valid)
    spk286_at_sdram_read_buffer #(.LINE_COUNT(512)) u_code (
        .clk, .reset, .cancel_cpu(1'b0), .enable(1'b1), `IN_PORTS(a), `OUT_PORTS(b),
        .debug_hit_count(), .debug_miss_count(), .debug_fill_count(),
        .debug_physical_read_count(), .debug_invalidation_count(), .debug_state()
    );
    spk286_at_sdram_data_buffer u_data (
        .clk, .reset, .cancel_cpu(1'b0), .enable(1'b1), .in_burst(b_burst),
        `IN_PORTS(b), `OUT_PORTS(c), .debug_hit_count(), .debug_miss_count(),
        .debug_fill_count(), .debug_write_update_count(), .debug_state()
    );
    spk286_at_posted_write_buffer u_posted (
        .clk, .reset, .cancel_cpu(1'b0), .cpu_lock(1'b0), .in_burst(c_burst),
        `IN_PORTS(c), `OUT_PORTS(d), .pending_write(), .idle(),
        .protocol_error(posted_error), .debug_post_count(), .debug_drain_count(),
        .debug_stall_count()
    );
`undef IN_PORTS
`undef OUT_PORTS
    logic physical_active = 0;
    integer physical_wait = 0;
    logic [24:0] physical_address = 0;
    logic [1:0] physical_lanes = 0;
    logic [15:0] physical_data = 0;
    logic physical_write = 0;
    assign d_accept = d_valid && d_command && !physical_active;
    assign d_ready = physical_active && physical_wait == 0;
    assign d_read_valid = d_ready && !physical_write;
    // Deliberately discard data as soon as READY is retired. No undocumented
    // post-response data hold may be relied on by the FDC completion pulse.
    assign d_read_data = d_read_valid ? ram[physical_address[12:1]] : 16'hDEAD;
    always_ff @(posedge clk) begin
        if (reset) begin physical_active <= 0; physical_wait <= 0; end
        else if (d_accept) begin
            physical_active <= 1;
            physical_wait <= (case_id == 0) ? 0 : ((backend_reads+backend_writes) % 7);
            physical_address <= d_address;
            physical_lanes <= d_lanes;
            physical_data <= d_data;
            physical_write <= d_write;
        end else if (physical_active) begin
            if (physical_wait > 0) physical_wait <= physical_wait-1;
            else begin
                physical_active <= 0;
                if (physical_write) begin
                    if (physical_lanes[0]) ram[physical_address[12:1]][7:0] <= physical_data[7:0];
                    if (physical_lanes[1]) ram[physical_address[12:1]][15:8] <= physical_data[15:8];
                    backend_writes <= backend_writes+1;
                end else backend_reads <= backend_reads+1;
            end
        end
    end
    function automatic logic [7:0] pattern(input integer n, input integer seed);
        pattern = 8'((n * 73) ^ (n >> 1) ^ (seed * 29) ^ 8'hA7);
    endfunction
    always @(posedge clk) begin
        if (!reset && dma_transfer_complete) begin
            completed = completed+1;
            if (dma_terminal_count) tc_count = tc_count+1;
        end
        if (!reset && u_fdc.u_fdc.fifo_from_pc && u_fdc.u_fdc.fifo_pc_wr) begin
            if (fifo_bytes < 512 && u_fdc.u_fdc.dma_readdata !== pattern(fifo_bytes,case_id))
                $fatal(1,"FLOPPY_WRITE_PAYLOAD_MISMATCH case=%0d byte=%0d expected=%02x actual=%02x",
                       case_id,fifo_bytes,pattern(fifo_bytes,case_id),u_fdc.u_fdc.dma_readdata);
            fifo_bytes = fifo_bytes+1;
        end
    end

    task automatic io_access(input logic [15:0] port, input logic wr,
                             input logic [7:0] value, output logic [7:0] result);
        integer guard;
        begin
            @(negedge clk);
            request_valid=1; request_write=wr; request_address={8'd0,port};
            request_lanes=port[0] ? 2'b10 : 2'b01;
            request_data=port[0] ? {value,8'd0} : {8'd0,value};
            #1;
            if (!(dma_config_accept || fdc_accept)) $fatal(1,"IO not accepted port=%04x",port);
            @(posedge clk); @(negedge clk); request_valid=0;
            guard=0;
            while (!(dma_config_ready || fdc_ready) && guard<30) begin
                @(negedge clk); guard=guard+1;
            end
            if (guard==30) $fatal(1,"IO missing response port=%04x",port);
            result = port[0] ? ((port < 16'h100) ? dma_config_data[15:8] : fdc_data[15:8]) :
                              ((port < 16'h100) ? dma_config_data[7:0] : fdc_data[7:0]);
            @(posedge clk); @(negedge clk); request_write=0;
        end
    endtask
    task automatic io_write(input logic [15:0] port,input logic [7:0] value);
        logic [7:0] ignored;
        io_access(port,1,value,ignored);
    endtask
    task automatic fifo_command(input logic [7:0] value);
        logic [7:0] status_byte; integer guard;
        begin
            guard=0;
            io_access(16'h3F4,0,0,status_byte);
            while ((!status_byte[7] || status_byte[6]) && guard<100) begin
                io_access(16'h3F4,0,0,status_byte); guard=guard+1;
            end
            if (guard==100) $fatal(1,"FDC command phase timeout");
            io_write(16'h3F5,value);
        end
    endtask
    task automatic mgmt_put(input logic [3:0] address,input logic [15:0] value);
        begin
            @(negedge clk); mgmt_address={12'hF20,address}; mgmt_writedata=value; mgmt_write=1;
            @(posedge clk); @(negedge clk); mgmt_write=0;
        end
    endtask
    task automatic mgmt_get(input logic [3:0] address,output logic [15:0] value);
        begin
            @(negedge clk); mgmt_address={12'hF20,address}; mgmt_read=1;
            @(posedge clk); #1; value=mgmt_readdata;
            @(negedge clk); mgmt_read=0;
            // fifo_readdata is registered independently of mgmt_read.
            @(posedge clk); @(negedge clk);
        end
    endtask
    task automatic program_dma(input integer start,input logic [7:0] mode);
        begin
            io_write(16'h0A,8'h06); io_write(16'h0C,0);
            io_write(16'h04,8'(start)); io_write(16'h04,8'(start>>8));
            io_write(16'h05,8'hFF); io_write(16'h05,8'h01);
            io_write(16'h81,8'h01); io_write(16'h0B,mode); io_write(16'h0A,8'h02);
        end
    endtask
    task automatic sector_command(input logic wr,input integer sector_number);
        begin
            fifo_command(wr ? 8'h45 : 8'h46); fifo_command(8'h04);
            fifo_command(8'h01); fifo_command(8'h01); fifo_command(8'(sector_number));
            fifo_command(8'h02); fifo_command(8'h0F); fifo_command(8'h2A); fifo_command(8'hFF);
        end
    endtask
    task automatic await_request(input logic [1:0] wanted);
        integer guard;
        begin
            guard=0;
            while(floppy_request != wanted && guard<30000) begin @(negedge clk); guard=guard+1; end
            if (floppy_request != wanted) $fatal(1,"FDC host request timeout wanted=%b actual=%b",wanted,floppy_request);
        end
    endtask
    task automatic result_phase;
        integer guard,j; logic [7:0] result_byte;
        begin
            guard=0;
            while(!irq6 && guard<10000) begin @(negedge clk); guard=guard+1; end
            if (!irq6) $fatal(1,"FDC missing IRQ6");
            for(j=0;j<7;j=j+1) begin
                io_access(16'h3F5,0,0,result_byte);
                if(j==0 && result_byte[7:6] != 0) $fatal(1,"FDC abnormal ST0=%02x",result_byte);
                if((j==1 || j==2) && result_byte != 0) $fatal(1,"FDC abnormal ST%0d=%02x",j,result_byte);
            end
            if(irq6) $fatal(1,"FDC result failed to clear IRQ6");
        end
    endtask
    task automatic payload_unit_checks;
        begin
            // Channel 1/Sound Blaster consumes the live response before DMA's
            // registered completion. Retention must preserve that sampling edge.
            @(negedge clk); probe_reset=0; probe_valid=1; probe_read=1;
            probe_channel=1; probe_lanes=2'b10; probe_data=16'hE7A5;
            probe_response=1; probe_complete=0; #1;
            if(probe_endpoint !== 16'h00E7) $fatal(1,"PAYLOAD_UNIT_CHANNEL1_LIVE_RESPONSE");
            @(posedge clk); @(negedge clk);
            probe_response=0; probe_complete=1; probe_lanes=2'b01; probe_data=16'hDEAD; #1;
            if(probe_endpoint !== 16'h00E7) $fatal(1,"PAYLOAD_UNIT_CHANNEL1_COMPLETION_RETAINED");
            // Secondary-DMA word channels retain all 16 bits without lane normalization.
            probe_channel=5; probe_lanes=2'b11; probe_data=16'h6CA1;
            probe_response=1; probe_complete=0; #1;
            if(probe_endpoint !== 16'h6CA1) $fatal(1,"PAYLOAD_UNIT_CHANNEL5_LIVE_WORD");
            @(posedge clk); @(negedge clk);
            probe_response=0; probe_complete=1; probe_data=16'hDEAD; #1;
            if(probe_endpoint !== 16'h6CA1) $fatal(1,"PAYLOAD_UNIT_CHANNEL5_RETAINED_WORD");
            // No transfer, no memory response, and device-to-memory direction
            // must each independently prevent capture of a new payload.
            probe_valid=0; probe_response=1; probe_complete=0; probe_data=16'h91F8;
            @(posedge clk); @(negedge clk); probe_complete=1; #1;
            if(probe_endpoint !== 16'h6CA1) $fatal(1,"PAYLOAD_UNIT_CAPTURE_WITHOUT_TRANSFER");
            probe_valid=1; probe_response=0; probe_complete=0; probe_data=16'h37D2;
            @(posedge clk); @(negedge clk); probe_complete=1; #1;
            if(probe_endpoint !== 16'h6CA1) $fatal(1,"PAYLOAD_UNIT_CAPTURE_WITHOUT_RESPONSE");
            probe_read=0; probe_response=1; probe_complete=0; probe_data=16'h4E63;
            @(posedge clk); @(negedge clk); probe_complete=1; #1;
            if(probe_endpoint !== 16'h4E63) $fatal(1,"PAYLOAD_UNIT_WRITE_DIRECTION_LIVE");
            probe_read=1; probe_response=0; #1;
            if(probe_endpoint !== 16'h6CA1) $fatal(1,"PAYLOAD_UNIT_CAPTURE_WRONG_DIRECTION");
            probe_reset=1;
            @(posedge clk); @(negedge clk); probe_reset=0; #1;
            if(probe_endpoint !== 16'h0000) $fatal(1,"PAYLOAD_UNIT_RESET_CLEAR");
            probe_complete=0; probe_valid=0;
            $display("FLOPPY_PAYLOAD_UNIT_PASS channel1_live=1 channel5_word=1 guard_valid=1 guard_response=1 guard_read=1 reset=1");
        end
    endtask
    integer i,k,address_index,start,step,reads_before,writes_before;
    logic [15:0] host_word;
    logic [7:0] ignored;
    initial begin
        for(i=0;i<4096;i=i+1) ram[i]=16'h5AA5;
        repeat(5) @(posedge clk);
        @(negedge clk); reset=0;
        mgmt_put(0,1); mgmt_put(1,0); mgmt_put(2,80);
        mgmt_put(3,15); mgmt_put(4,2400); mgmt_put(5,2);
        io_write(16'h3F2,8'h0C); io_write(16'h3F2,8'h08); io_write(16'h3F2,8'h0C);
        repeat(8) @(posedge clk);
        fifo_command(8'h08); io_access(16'h3F5,0,0,ignored); io_access(16'h3F5,0,0,ignored);
        fifo_command(8'h03); fifo_command(8'hCF); fifo_command(8'h02);
        io_write(16'h3F7,0); io_write(16'h3F2,8'h1C);
        for(k=0;k<4;k=k+1) begin
            case_id=k;
            start=(k==2) ? 16'h05FF : (k==1 || k==3) ? 16'h0201 : 16'h0200;
            step=(k==2) ? -1 : 1;
            for(i=0;i<512;i=i+1) begin
                address_index=start+step*i;
                if(address_index&1) ram[address_index>>1][15:8]=pattern(i,k);
                else ram[address_index>>1][7:0]=pattern(i,k);
            end
            completed=0; tc_count=0; fifo_bytes=0;
            reads_before=backend_reads; writes_before=backend_writes;
            program_dma(start,(k==2) ? 8'h6A : (k==3) ? 8'h5A : 8'h4A);
            sector_command(1,k+3); await_request(2'b10);
            if(completed!=512 || tc_count!=1 || fifo_bytes!=512)
                $fatal(1,"WRITE beat/TC/FIFO count case=%0d beats=%0d tc=%0d fifo=%0d",k,completed,tc_count,fifo_bytes);
            mgmt_get(0,host_word);
            if(host_word != 16'(47+k)) $fatal(1,"Wrong WRITE LBA=%0d expected=%0d",host_word,47+k);
            for(i=0;i<512;i=i+1) begin
                mgmt_get(15,host_word); image[i]=host_word[7:0];
                if(image[i] !== pattern(i,k)) $fatal(1,"HOST_WRITE_MISMATCH case=%0d byte=%0d expected=%02x actual=%02x",k,i,pattern(i,k),image[i]);
            end
            result_phase();
            if(backend_reads-reads_before!=512 || backend_writes!=writes_before)
                $fatal(1,"WRITE physical direction/count mismatch");
            if(k==3) begin
                if(u_dma.current_address_q[2] != 16'(start) || u_dma.current_count_q[2]!=16'h01FF || u_dma.mask_q[2])
                    $fatal(1,"DMA autoinit failed to reload address/count/unmasked");
                // Repeat without reprogramming the autoinit controller.
                completed=0; tc_count=0; fifo_bytes=0;
                sector_command(1,k+3); await_request(2'b10);
                if(completed!=512 || tc_count!=1) $fatal(1,"DMA autoinit second transfer count");
                mgmt_get(0,host_word);
                for(i=0;i<512;i=i+1) begin
                    mgmt_get(15,host_word);
                    if(host_word[7:0] !== image[i]) $fatal(1,"AUTOINIT_WRITE_MISMATCH byte=%0d",i);
                end
                result_phase();
            end
            // Host image content is fed back through READ DATA to a different
            // RAM region, independent of DOS caching and the original buffer.
            for(i=0;i<257;i=i+1) ram[16'h800+i]=16'hCCCC;
            completed=0; tc_count=0;
            program_dma(16'h1001,8'h46); sector_command(0,k+3); await_request(2'b01);
            mgmt_get(0,host_word);
            if(host_word!=16'(47+k)) $fatal(1,"Wrong READ LBA");
            for(i=0;i<512;i=i+1) mgmt_put(15,{8'd0,image[i]});
            result_phase();
            if(completed!=512 || tc_count!=1) $fatal(1,"READ beat/TC count mismatch");
            for(i=0;i<512;i=i+1) begin
                address_index=16'h1001+i;
                if((address_index&1) ? ram[address_index>>1][15:8] !== image[i] : ram[address_index>>1][7:0] !== image[i])
                    $fatal(1,"READBACK_MISMATCH case=%0d byte=%0d",k,i);
            end
            if(ram[16'h800][7:0]!=8'hCC || ram[16'h900][15:8]!=8'hCC)
                $fatal(1,"READBACK clobbered outside byte lanes");
            $display("FLOPPY_WRITE_CASE_PASS case=%0d start=%04x step=%0d lba=%0d bytes=512 readback=512 stalls=%0d",k,start,step,47+k,k!=0);
        end
        payload_unit_checks();
        if(dma_error || fdc_error || port_error || posted_error) $fatal(1,"Protocol error DMA/FDC/memory/posting");
        $display("AT_FLOPPY_WRITE_PASS cases=4 sectors_written=5 sectors_read=4 bytes_written=2560 bytes_read=2048 lanes=even,odd decrement=1 autoinit=1 withdrawn_response=1");
        $finish;
    end
    initial begin #10000000; $fatal(1,"FLOPPY write watchdog"); end
endmodule
