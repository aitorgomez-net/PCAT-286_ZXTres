`timescale 1ns/1ps

// Composed CPU-to-AT boundary test.  The memory model is intentionally small:
// it provides the externally loaded 64 KiB system ROM, sparse conventional
// memory and the same handshake used by a future MiSTer SDRAM owner.
module spk286_at_bios_first_fetch_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    always #10 clk = ~clk; // Production AT 50 MHz
    logic clk_video = 1'b0;
    always #17.45 clk_video = ~clk_video;

    logic execute_enable = 1'b1;
    logic cpu_boot_reset = 1;
    logic counter_clock = 1'b0;
    logic refresh_enable = 1'b1;
    logic pit_clock_active = 1'b0;
    integer pit_clock_rising_edges = 0;
    always_ff @(posedge clk) begin
        if (reset) begin
            counter_clock <= 1'b0;
            pit_clock_active <= 1'b0;
            pit_clock_rising_edges <= 0;
        end else if (!pit_clock_active) begin
            counter_clock <= 1'b0;
        end else if (pit_clock_rising_edges < 32) begin
            counter_clock <= ~counter_clock;
            if (!counter_clock)
                pit_clock_rising_edges <= pit_clock_rising_edges + 1;
        end else begin
            counter_clock <= 1'b0;
        end
    end

    logic keyboard_byte_valid = 1'b0;
    logic [7:0] keyboard_byte = 8'h00;
    logic periodic_tick = 1'b0;
    logic second_tick = 1'b0;
    logic parity_event = 1'b0;
    logic channel_check_event = 1'b0;
    logic external_nmi_event = 1'b0;

    wire memory_request_valid;
    wire memory_command_valid;
    wire memory_write;
    wire memory_code_fetch;
    wire [3:0] memory_cycle_class;
    wire [23:0] memory_address;
    wire [1:0] memory_byte_enable;
    wire [15:0] memory_data_out;
    wire memory_accept;
    wire memory_ready;
    logic [15:0] memory_read_data;
    wire memory_read_data_valid;

    wire dma_memory_valid;
    wire dma_memory_write;
    wire dma_memory_read;
    wire [23:0] dma_memory_address;
    wire [1:0] dma_memory_byte_enable;
    wire [15:0] dma_memory_data_out;
    wire dma_memory_accept;
    wire dma_memory_ready;
    logic [15:0] dma_memory_data_in;

    wire refresh_memory_valid;
    wire [23:0] refresh_memory_address;
    wire refresh_memory_accept;
    wire refresh_memory_ready;

    wire        backend_valid;
    wire        backend_command_valid;
    wire [1:0]  backend_owner;
    wire        backend_write;
    wire        backend_refresh;
    wire        backend_code_fetch;
    wire [3:0]  backend_cycle_class;
    wire [23:0] backend_address;
    wire [1:0]  backend_byte_enable;
    wire [15:0] backend_data_out;
    wire        backend_accept;
    wire        backend_ready;
    logic [15:0] backend_read_data;
    wire        backend_read_data_valid;
    wire        memory_port_protocol_error;
    wire        sdram_owner_protocol_error;

    wire [12:0] sdram_address;
    wire        sdram_cke;
    wire        sdram_cs;
    wire        sdram_ras;
    wire        sdram_cas;
    wire        sdram_we;
    wire [1:0]  sdram_ba;
    logic [15:0] sdram_dq_in;
    wire [15:0] sdram_dq_out;
    wire        sdram_dq_io;
    wire        sdram_ldqm;
    wire        sdram_udqm;

    wire keyboard_output_valid;
    wire [7:0] keyboard_output_byte;
    wire a20_enable;
    wire cpu_reset_request;
    wire intr;
    wire nmi;
    wire [15:0] irq_request;
    wire nmi_mask;
    wire [3:0] selected_device;
    wire unmapped_request;
    wire ata_selected;
    wire floppy_selected;
    wire video_io_selected;
    wire video_memory_selected;
    wire cpu_hold_request;
    wire cpu_hlda;
    wire bus_owner_valid;
    wire [2:0] bus_owner;
    wire dma_grant;
    wire refresh_grant;
    wire bridge_idle;
    wire cpu_ready;
    wire [23:0] cpu_address;
    wire [15:0] cpu_data_out;
    wire [15:0] cpu_data_in;
    wire cpu_data_oe;
    wire cpu_bus_valid;
    wire cpu_bus_write;
    wire cpu_bus_bhe_n;
    wire [3:0] cpu_bus_status;
    wire cpu_bus_lock;
    wire cpu_halted;
    wire cpu_shutdown;
    wire cpu_fault;
    wire [7:0] debug_event_vector;
    wire [7:0] debug_opcode;
    wire [15:0] debug_cs;
    wire [15:0] debug_ip;
    wire [3:0] debug_bus_state;
    wire [15:0] refresh_count;
    wire [15:0] dma_side_effect_count;
    wire [15:0] device_side_effect_count;
    wire protocol_error;

    logic [7:0] rom [0:65535];
    integer index;
    integer rom_file;
    integer loaded_bytes;
    reg [8*512-1:0] rom_path;

    integer accepted_memory_beats = 0;
    integer accepted_io_writes = 0;
    integer refresh_beats = 0;
    integer irq0_edges = 0;
    integer port80_writes = 0;
    integer port81_writes = 0;
    integer pit_data_writes = 0;
    integer first_bios_read_count = 0;
    logic [7:0] port80_sequence [0:3];
    logic saw_native_reset_fetch = 1'b0;
    logic saw_native_reset_response = 1'b0;
    logic saw_native_reset_data = 1'b0;
    logic saw_low_rom_fetch = 1'b0;

    // The physical store is loaded only through HPS. It has no BIOS mapping.
    wire [1:0] pin_dq_valid;
    integer pin_reads, pin_writes;
    wire physical_idle;
    logic sdram_initialized = 0;
    always @(posedge clk) begin
        if (reset) sdram_initialized <= 0;
        else if (physical_idle) sdram_initialized <= 1;
    end
    spk286_sdram_pin_model #(.MEM_WORDS(1<<20)) pins (
        .clk(clk), .reset(reset), .address(sdram_address), .cke(sdram_cke),
        .cs_n(sdram_cs), .ras_n(sdram_ras), .cas_n(sdram_cas), .we_n(sdram_we),
        .ba(sdram_ba), .dq_from_controller(sdram_dq_out),
        .controller_dq_oe(!sdram_dq_io), .dqm({sdram_udqm,sdram_ldqm}),
        .dq_to_controller(sdram_dq_in), .dq_valid(pin_dq_valid),
        .read_count(pin_reads), .write_count(pin_writes)
    );
    logic ioctl_download=0, ioctl_wr=0;
    logic [24:0] ioctl_addr=0;
    logic [15:0] ioctl_data=0;
    wire ioctl_wait, loader_valid, loader_write, loader_accept, loader_ready;
    wire [23:0] loader_address;
    wire [1:0] loader_be;
    wire [15:0] loader_data;
    wire main_rom_loaded, loader_error;
    spk286_at_hps_rom_loader loader (
        .clk(clk), .reset(reset), .sdram_initialized(sdram_initialized),
        .ioctl_download(ioctl_download), .ioctl_index(8'd0), .ioctl_wr(ioctl_wr),
        .ioctl_addr(ioctl_addr), .ioctl_data(ioctl_data), .ioctl_wait(ioctl_wait),
        .loader_valid(loader_valid), .loader_write(loader_write),
        .loader_address(loader_address), .loader_byte_enable(loader_be),
        .loader_data_out(loader_data), .loader_accept(loader_accept),
        .loader_ready(loader_ready), .main_rom_loaded(main_rom_loaded),
        .protocol_error(loader_error), .bios_protect_flag(), .ega_rom_loaded(),
        .xtide_rom_loaded(), .load_active()
    );
    task automatic download_bios;
        integer offset, guard;
        begin
            @(negedge clk); ioctl_download=1;
            for(offset=0;offset<65536;offset=offset+2) begin
                guard=0;
                while(ioctl_wait) begin
                    @(negedge clk); guard=guard+1;
                    if(guard>1000) $fatal(1,"HPS loader wait timeout");
                end
                ioctl_addr=25'(offset); ioctl_data={rom[offset+1],rom[offset]}; ioctl_wr=1;
                @(negedge clk); ioctl_wr=0;
                repeat(offset%3+1) @(negedge clk);
            end
            ioctl_download=0;
            wait(!ioctl_wait && main_rom_loaded && physical_idle);
            @(negedge clk);
            if(pin_writes!=32768) $fatal(1,"HPS writes %0d !=32768",pin_writes);
            $display("AT_HPS_PHYSICAL_LOAD_PASS words=%0d vector=%02h%02h",pin_writes,rom[16'hfff1],rom[16'hfff0]);
        end
    endtask
    integer fetch_returns=0, cpu_fetch_returns=0;
    logic saw_opcode=0;
    logic [23:0] captured_word_address;
    wire [23:0] cs_base;
    wire [127:0] boot_words;
    wire boot_valid;
    wire [5:0] boot_count;
    spk286_at_boot_trace boot_trace (
        .clk(clk), .reset(reset | cpu_boot_reset),
        .cpu_valid(cpu_bus_valid), .cpu_write(cpu_bus_write), .cpu_status(cpu_bus_status),
        .cpu_address(cpu_address), .cpu_ready(cpu_ready), .cpu_data_in(cpu_data_in),
        .cpu_halted(cpu_halted), .cpu_cs(debug_cs), .cpu_ip(debug_ip),
        .cpu_cs_base(cs_base), .cpu_opcode(debug_opcode),
        .backend_valid(backend_valid), .backend_command_valid(backend_command_valid),
        .backend_code(backend_code_fetch), .backend_write(backend_write),
        .backend_accept(backend_accept), .backend_ready(backend_ready),
        .backend_read_valid(backend_read_data_valid), .backend_address(backend_address),
        .backend_byte_enable(backend_byte_enable), .backend_read_data(backend_read_data),
        .kf_address(sdram_owner.debug_kf_address), .kf_data(sdram_owner.debug_kf_data_out),
        .kf_read_request(sdram_owner.debug_kf_read_request), .kf_read_flag(sdram_owner.debug_kf_read_flag),
        .owner_state(sdram_owner.debug_owner_state),
        .sdram_read_command(!sdram_cs && sdram_ras && !sdram_cas && sdram_we),
        .sdram_dqm({sdram_udqm,sdram_ldqm}), .select_index(5'd0), .select_detail(1'b0),
        .selected_words(boot_words), .selected_valid(boot_valid), .capture_count(boot_count),
        .full(), .capture_pending()
    );
    always @(posedge clk) begin
        if(!reset && sdram_owner.u_KFSDRAM.read_flag_comb && pin_dq_valid!==2'b11)
            $fatal(1,"KF samples invalid DQ addr=%h valid=%b",sdram_owner.kf_address,pin_dq_valid);
        if(!cpu_boot_reset) begin
            if(dut.u_cpu.cpu.msw_q[0]) $fatal(1,"PE set during first-fetch test");
            if(backend_accept && backend_code_fetch) captured_word_address<=sdram_owner.kf_address;
            if(backend_ready && backend_code_fetch && backend_owner==0) begin
                if(!backend_read_data_valid) $fatal(1,"fetch without VLD");
                if((backend_address>=24'hfff000) || (backend_address>=24'h0f0000 && backend_address<=24'h0fffff)) begin
                    if(backend_byte_enable[0] && backend_read_data[7:0]!==rom[{backend_address[15:1],1'b0}])
                        $fatal(1,"BIOS low lane addr=%h got=%h",backend_address,backend_read_data);
                    if(backend_byte_enable[1] && backend_read_data[15:8]!==rom[{backend_address[15:1],1'b1}])
                        $fatal(1,"BIOS high lane addr=%h got=%h",backend_address,backend_read_data);
                end else $fatal(1,"early fetch outside ROM addr=%h",backend_address);
                if(fetch_returns<32) $display("FETCH[%0d] cpu=%06h word=%06h data=%04h be=%b dqm=%b req=%b valid=%b ready=%b csip=%04h:%04h base=%06h op=%02h rst=%b hlt=%b owner=%b kf=%0d",
                    fetch_returns,backend_address,captured_word_address,backend_read_data,backend_byte_enable,
                    {sdram_udqm,sdram_ldqm},backend_valid,backend_read_data_valid,backend_ready,
                    debug_cs,debug_ip,cs_base,debug_opcode,cpu_boot_reset,cpu_halted,sdram_owner.active_q,sdram_owner.u_KFSDRAM.state);
                fetch_returns<=fetch_returns+1;
            end
            if(cpu_bus_valid && cpu_ready && cpu_bus_status==4'hd) begin
                if(cpu_fetch_returns==0 && cpu_data_in[7:0]!==rom[16'hfff0]) $fatal(1,"CPU first opcode data=%h",cpu_data_in);
                if(!cpu_address[0] && cpu_data_in[7:0]!==rom[{cpu_address[15:1],1'b0}])
                    $fatal(1,"CPU low byte mismatch addr=%h data=%h",cpu_address,cpu_data_in);
                if(!cpu_bus_bhe_n && cpu_data_in[15:8]!==rom[{cpu_address[15:1],1'b1}])
                    $fatal(1,"CPU high byte mismatch addr=%h data=%h",cpu_address,cpu_data_in);
                cpu_fetch_returns<=cpu_fetch_returns+1;
            end
            if(debug_opcode==rom[16'hfff0]) saw_opcode<=1;
        end else if(!reset && cpu_bus_valid) $fatal(1,"CPU active during download");
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            accepted_memory_beats <= 0;
            accepted_io_writes <= 0;
            refresh_beats <= 0;
            irq0_edges <= 0;
            port80_writes <= 0;
            port81_writes <= 0;
            pit_data_writes <= 0;
            saw_native_reset_fetch <= 1'b0;
            saw_native_reset_response <= 1'b0;
            saw_native_reset_data <= 1'b0;
            saw_low_rom_fetch <= 1'b0;
            first_bios_read_count <= 0;
        end else begin
            if (backend_accept && (backend_owner == 2'd0)) begin
                accepted_memory_beats <= accepted_memory_beats + 1;
                if (backend_address == 24'hFFFFF0)
                    saw_native_reset_fetch <= 1'b1;
                if ((backend_address >= 24'h0F0000) &&
                    (backend_address <= 24'h0FFFFF))
                    saw_low_rom_fetch <= 1'b1;
            end

            // Capture the first returned CPU reads, not only accepted
            // commands.  This makes the test fail if the SDRAM address is
            // right but the returned word/lane/valid timing is wrong.
            if (backend_ready && (backend_owner == 2'd0) && !backend_write &&
                (first_bios_read_count < 32)) begin
                if (first_bios_read_count == 0)
                    $display("AT_FIRST_READ addr=%06h be=%b data=%04h valid=%b",
                             backend_address, backend_byte_enable,
                             backend_read_data, backend_read_data_valid);
                first_bios_read_count <= first_bios_read_count + 1;
                if (backend_address == 24'hFFFFF0) begin
                    saw_native_reset_response <= 1'b1;
                    if (backend_read_data_valid &&
                        (((backend_byte_enable == 2'b01) &&
                          (backend_read_data[7:0] == rom[16'hFFF0])) ||
                         ((backend_byte_enable == 2'b10) &&
                          (backend_read_data[15:8] == rom[16'hFFF0])) ||
                         ((backend_byte_enable == 2'b11) &&
                          (backend_read_data == {rom[16'hFFF1], rom[16'hFFF0]}))))
                        saw_native_reset_data <= 1'b1;
                end
            end

            if (backend_accept && (backend_owner == 2'd2))
                refresh_beats <= refresh_beats + 1;
            if (irq_request[0] && !intr)
                irq0_edges <= irq0_edges + 1;

            if (cpu_ready && cpu_bus_valid && cpu_bus_write &&
                (cpu_bus_status == 4'hA)) begin
                accepted_io_writes <= accepted_io_writes + 1;
                if (cpu_address[15:0] == 16'h0080) begin
                    if (port80_writes < 4)
                        port80_sequence[port80_writes] <= cpu_data_out[7:0];
                    port80_writes <= port80_writes + 1;
                end
                if (cpu_address[15:0] == 16'h0081)
                    port81_writes <= port81_writes + 1;
                if (cpu_address[15:0] == 16'h0040) begin
                    pit_data_writes <= pit_data_writes + 1;
                    if (pit_data_writes == 1)
                        pit_clock_active <= 1'b1;
                end
            end
        end
    end

    initial begin
        if (!$value$plusargs("ROM=%s", rom_path))
            rom_path = "tests/firmware/pcat286_event_diag.rom";
        rom_file = $fopen(rom_path, "rb");
        if (rom_file == 0)
            $fatal(1, "cannot open AT system ROM: %0s", rom_path);
        loaded_bytes = $fread(rom, rom_file, 0, 65536);
        $fclose(rom_file);
        if (loaded_bytes != 65536)
            $fatal(1, "AT system ROM must be exactly 65536 bytes, got %0d",
                   loaded_bytes);
        for (index = 0; index < 4; index = index + 1)
            port80_sequence[index] = 8'h00;
    end

    // Exercise the real machine through the same serialized memory boundary
    // that the future MiSTer SDRAM/HPS owner will use.
    spk286_at_mister_memory_port memory_port (
        .clk(clk), .reset(reset),
        .cancel_cpu(cpu_boot_reset),
        .cpu_valid(memory_request_valid),
        .cpu_command_valid(memory_command_valid),
        .cpu_write(memory_write),
        .cpu_code_fetch(memory_code_fetch),
        .cpu_cycle_class(memory_cycle_class),
        .cpu_address(memory_address),
        .cpu_byte_enable(memory_byte_enable),
        .cpu_data_out(memory_data_out),
        .cpu_accept(memory_accept), .cpu_ready(memory_ready),
        .cpu_read_data(memory_read_data),
        .cpu_read_data_valid(memory_read_data_valid),
        .loader_valid(loader_valid), .loader_write(loader_write),
        .loader_address(loader_address), .loader_byte_enable(loader_be),
        .loader_data_out(loader_data), .loader_accept(loader_accept), .loader_ready(loader_ready),
        .loader_read_data(),
        .dma_valid(dma_memory_valid), .dma_write(dma_memory_write),
        .dma_address(dma_memory_address),
        .dma_byte_enable(dma_memory_byte_enable),
        .dma_data_out(dma_memory_data_out),
        .dma_accept(dma_memory_accept), .dma_ready(dma_memory_ready),
        .dma_read_data(dma_memory_data_in),
        .refresh_valid(refresh_memory_valid),
        .refresh_address(refresh_memory_address),
        .refresh_accept(refresh_memory_accept),
        .refresh_ready(refresh_memory_ready),
        .backend_valid(backend_valid),
        .backend_command_valid(backend_command_valid),
        .backend_owner(backend_owner), .backend_write(backend_write),
        .backend_refresh(backend_refresh),
        .backend_code_fetch(backend_code_fetch),
        .backend_cycle_class(backend_cycle_class),
        .backend_address(backend_address),
        .backend_byte_enable(backend_byte_enable),
        .backend_data_out(backend_data_out),
        .backend_accept(backend_accept), .backend_ready(backend_ready),
        .backend_read_data(backend_read_data),
        .backend_read_data_valid(backend_read_data_valid),
        .protocol_error(memory_port_protocol_error)
    );

    spk286_at_mister_sdram_owner #(
        .SDRAM_INIT_WAIT(16'd32)
    ) sdram_owner (
        .clk(clk), .reset(reset),
        .request_valid(backend_valid),
        .request_command_valid(backend_command_valid),
        .request_owner_refresh(backend_refresh),
        .request_write(backend_write),
        .request_code_fetch(backend_code_fetch),
        .request_cycle_class(backend_cycle_class),
        .request_address(backend_address),
        .request_byte_enable(backend_byte_enable),
        .request_data_out(backend_data_out),
        .request_accept(backend_accept), .request_ready(backend_ready),
        .request_read_data(backend_read_data),
        .request_read_data_valid(backend_read_data_valid),
        .physical_idle(physical_idle), .protocol_error(sdram_owner_protocol_error),
        .sdram_address(sdram_address), .sdram_cke(sdram_cke),
        .sdram_cs(sdram_cs), .sdram_ras(sdram_ras),
        .sdram_cas(sdram_cas), .sdram_we(sdram_we),
        .sdram_ba(sdram_ba), .sdram_dq_in(sdram_dq_in),
        .sdram_dq_out(sdram_dq_out), .sdram_dq_io(sdram_dq_io),
        .sdram_ldqm(sdram_ldqm), .sdram_udqm(sdram_udqm)
    );

    spk286_at_machine dut (
        .clk(clk), .reset(reset | cpu_boot_reset), .cpu_reset(reset | cpu_boot_reset), .clk_video(clk_video), .splashscreen(1'b0),
        .execute_enable(execute_enable),
        .counter_clock(counter_clock), .refresh_enable(refresh_enable),
        .keyboard_byte_valid(keyboard_byte_valid), .keyboard_byte(keyboard_byte),
        .periodic_tick(periodic_tick), .second_tick(second_tick),
        .parity_event(parity_event), .channel_check_event(channel_check_event),
        .external_nmi_event(external_nmi_event),
        .memory_request_valid(memory_request_valid),
        .memory_command_valid(memory_command_valid),
        .memory_write(memory_write), .memory_code_fetch(memory_code_fetch),
        .memory_cycle_class(memory_cycle_class), .memory_address(memory_address),
        .memory_byte_enable(memory_byte_enable), .memory_data_out(memory_data_out),
        .memory_accept(memory_accept), .memory_ready(memory_ready),
        .memory_read_data(memory_read_data),
        .memory_read_data_valid(memory_read_data_valid),
        .dma_memory_valid(dma_memory_valid), .dma_memory_write(dma_memory_write),
        .dma_memory_read(dma_memory_read),
        .dma_memory_address(dma_memory_address),
        .dma_memory_byte_enable(dma_memory_byte_enable),
        .dma_memory_data_out(dma_memory_data_out),
        .dma_memory_accept(dma_memory_accept), .dma_memory_ready(dma_memory_ready),
        .dma_memory_data_in(dma_memory_data_in),
        .refresh_memory_valid(refresh_memory_valid),
        .refresh_memory_address(refresh_memory_address),
        .refresh_memory_accept(refresh_memory_accept),
        .refresh_memory_ready(refresh_memory_ready),
        .keyboard_output_valid(keyboard_output_valid),
        .keyboard_output_byte(keyboard_output_byte), .a20_enable(a20_enable),
        .cpu_reset_request(cpu_reset_request), .intr(intr), .nmi(nmi),
        .irq_request(irq_request), .nmi_mask(nmi_mask),
        .selected_device(selected_device), .unmapped_request(unmapped_request),
        .ata_selected(ata_selected), .floppy_selected(floppy_selected),
        .video_io_selected(video_io_selected),
        .video_memory_selected(video_memory_selected),
        .cpu_hold_request(cpu_hold_request), .cpu_hlda(cpu_hlda),
        .bus_owner_valid(bus_owner_valid), .bus_owner(bus_owner),
        .dma_grant(dma_grant), .refresh_grant(refresh_grant),
        .bridge_idle(bridge_idle), .cpu_ready(cpu_ready),
        .cpu_address(cpu_address), .cpu_data_out(cpu_data_out),
        .cpu_data_in(cpu_data_in), .cpu_data_oe(cpu_data_oe),
        .cpu_bus_valid(cpu_bus_valid), .cpu_bus_write(cpu_bus_write),
        .cpu_bus_bhe_n(cpu_bus_bhe_n), .cpu_bus_status(cpu_bus_status),
        .cpu_bus_lock(cpu_bus_lock), .cpu_halted(cpu_halted),
        .cpu_shutdown(cpu_shutdown), .cpu_fault(cpu_fault),
        .debug_event_vector(debug_event_vector), .debug_opcode(debug_opcode),
        .debug_cs(debug_cs), .debug_ip(debug_ip), .debug_cs_base(cs_base),
        .debug_bus_state(debug_bus_state), .refresh_count(refresh_count),
        .dma_side_effect_count(dma_side_effect_count),
        .device_side_effect_count(device_side_effect_count),
        .protocol_error(protocol_error)
    );

    initial begin : run
        integer cycles;
        reg [8*512-1:0] wave_path;
        repeat(8) @(negedge clk); reset=0;
        wait(sdram_initialized); download_bios();
        if(debug_cs!==16'hf000 || debug_ip!==16'hfff0 || cs_base!==24'hff0000)
            $fatal(1,"bad reset %h:%h base=%h",debug_cs,debug_ip,cs_base);
        if($value$plusargs("WAVE=%s",wave_path)) begin
            $dumpfile(wave_path); $dumpvars(0,spk286_at_bios_first_fetch_tb);
        end
        cpu_boot_reset=0;
        for(cycles=0;cycles<200000;cycles=cycles+1) begin
            @(negedge clk);
            if(cpu_fault || protocol_error || memory_port_protocol_error || sdram_owner_protocol_error || loader_error || cpu_shutdown)
                $fatal(1,"first fetch fault cycle=%0d csip=%h:%h op=%h",cycles,debug_cs,debug_ip,debug_opcode);
            if(fetch_returns>=32 && cpu_fetch_returns>=16 && saw_opcode && saw_low_rom_fetch) begin
                if(!boot_valid || boot_count<16 || boot_words[23:0]!==24'hfffff0 ||
                   boot_words[55:32]!==24'h07fff8 || boot_words[95:64]!==32'hf000fff0 ||
                   boot_words[127:112]!=={rom[16'hfff1],rom[16'hfff0]})
                    $fatal(1,"boot trace real CPU/backend association failed: count=%0d words=%h",boot_count,boot_words);
                $display("AT_BOOT_TRACE_INTEGRATION_PASS count=%0d entry0=%032h",boot_count,boot_words);
                $display("AT_BIOS_FIRST_FETCH_PASS fetches=%0d cpu_responses=%0d opcode=%02h cycles=%0d",fetch_returns,cpu_fetch_returns,rom[16'hfff0],cycles);
                $finish;
            end
        end
        $fatal(1,"watchdog reads=%0d cpu=%0d csip=%h:%h hlt=%b",fetch_returns,cpu_fetch_returns,debug_cs,debug_ip,cpu_halted);
    end
    initial begin
        #100000000; $fatal(1,"HPS/SDRAM startup watchdog");
    end
endmodule
