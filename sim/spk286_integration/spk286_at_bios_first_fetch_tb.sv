`timescale 1ns/1ps

// Production CPU, HPS loader, AT bridge, KFSDRAM and physical SDRAM pin model.
// By default verify first BIOS fetches. Optional LANDMARK_CASE values select
// isolated DMA routines (1/2), original-entry investigation (3), and original
// parity/memory/PIT/refresh-status routines (4..9), NMI (10), RAM header (11),
// distinct DS/ES (12), and original POST through RAM (15), PM-skip CPU/RAM
// continuations (16/17), ROM checksums (18),
// the original 8042 controller/scan-lines routines (19/20), and the original
// floppy-adapter/read routines (21/22).
// Cases other than 0/3/15 set
// a test-only entry/setup in the private ROM buffer, never in the user ROM.
module spk286_at_bios_first_fetch_tb #(
    parameter bit CPU_DIV2_TEST = 1'b0
);
    logic clk = 1'b0;
    logic clk_cpu_div = 1'b0;
    logic reset = 1'b1;
    always #10 clk = ~clk; // Production AT 50 MHz
    always @(posedge clk or posedge reset) begin
        if (reset)
            clk_cpu_div <= 1'b0;
        else
            clk_cpu_div <= ~clk_cpu_div;
    end
    logic clk_video = 1'b0;
    always #17.45 clk_video = ~clk_video;

    // Optional isolated Landmark routines. The on-disk user ROM is never
    // changed; only the test fixture reset jump selects a diagnostic entry.
    // This exercises its exact instruction bytes, not a claimed full POST.
    integer landmark_case = 0;
    integer io_completed = 0;
    integer checksum_pass_count = 0;
    integer floppy_pass_count = 0;
    integer floppy_dma_beats = 0;
    integer floppy_irq_edges = 0;
    logic floppy_irq_previous = 1'b0;
    integer source_lane_sum [0:1];
    integer fixture_lane_sum;
    logic [55:0] skip_mono = 0, skip_color = 0;
    wire [15:0] skip_screen_offset = landmark_case==17 ? 16'h0448 : 16'h0866;
    // Status text is checked on completed video writes, independently of ROM IP.
    localparam [55:0] SKIPPED_TEXT = 56'h44455050494B53;
    logic [15:0] routine_entry;
    logic [7:0] last_port61;
    integer ram_reads=0, ram_writes=0;
    logic ram_test_active=0;
    logic [23:0] oracle_base=0;
    function automatic [7:0] memory_pattern(input integer beat);
        case(beat / 16384)
            0: memory_pattern=8'hff;
            1: memory_pattern=8'h01;
            2: memory_pattern=8'h55;
            3: memory_pattern=8'haa;
            4: memory_pattern=8'h00;
            default: memory_pattern=8'hxx;
        endcase
    endfunction
    integer nmi_pulses=0, nmi_markers=0, parity_pulse_cycles=0;
    logic nmi_prev=0, resumed_after_nmi=0;
    integer io_wait_cycles = 0;
    integer max_cpu_cycles = 200000;
    logic protocol_reported = 0;
    logic trace_boot = 1'b0;
    logic phoenix_pm87 = 1'b0;
    logic phoenix_pm87_saw_pe = 1'b0;
    logic phoenix_pm87_saw_shutdown = 1'b0;
    integer phoenix_pm87_shutdown_cycles = 0;
    integer reset_vector_fetches = 0;
    integer keyboard_warm_reset_at = -1;
    integer forced_warm_reset_state = -1;
    wire clk_cpu = CPU_DIV2_TEST ? clk_cpu_div : clk;
    integer cpu_reset_pulses = 0;
    integer warm_reset_pulses_before = 0;
    integer warm_reset_fetches_before = 0;
    integer warm_reset_cpu_fetches_before = 0;
    logic keyboard_warm_reset_test = 1'b0;
    logic keyboard_warm_reset_injected = 1'b0;
    logic forced_warm_reset_test = 1'b0;
    logic forced_warm_reset_injected = 1'b0;
    wire warm_reset_test = keyboard_warm_reset_test || forced_warm_reset_test;
    logic trace_irq0_prev = 1'b0;
    integer trace_lines = 0;
    logic [2:0] installed_ram_size_osd = 3'd0;

    initial begin
        if ($test$plusargs("RAM16"))
            installed_ram_size_osd = 3'd4;
    end

    logic execute_enable = 1'b1;
    logic cpu_boot_reset = 1;
    logic machine_boot_reset = 1;
    wire counter_clock;
    wire normal_counter_clock;
    logic fast_counter_clock=0;
    logic [25:0] fast_pit_phase=0;
    always @(posedge clk) begin
        if(reset) begin fast_pit_phase<=0; fast_counter_clock<=0; end
        else if(fast_pit_phase>=26'd26_136_360) begin
            fast_pit_phase<=fast_pit_phase-26'd26_136_360;
            fast_counter_clock<=~fast_counter_clock;
        end else fast_pit_phase<=fast_pit_phase+26'd23_863_640;
    end
    assign counter_clock=$test$plusargs("PHOENIX_FDC_FAST") ? fast_counter_clock : normal_counter_clock;
    logic refresh_enable = 1'b1;
    spk286_at_pit_clock pit_clock(.clk(clk), .reset(reset), .counter_clock(normal_counter_clock));

    logic keyboard_byte_valid = 1'b0;
    logic [7:0] keyboard_byte = 8'h00;
    wire keyboard_byte_ready;
    wire keyboard_translate_set1;
    logic periodic_tick = 1'b0;
    logic second_tick = 1'b0;
    logic parity_event = 1'b0;
    logic channel_check_event = 1'b0;
    logic external_nmi_event = 1'b0;
    logic [15:0] mgmt_address = 16'h0000;
    logic [15:0] mgmt_writedata = 16'h0000;
    logic mgmt_write = 1'b0;
    logic mgmt_read = 1'b0;
    wire [15:0] mgmt_readdata;
    wire [1:0] floppy_present;
    wire [1:0] floppy_request;

    wire memory_request_valid;
    wire memory_command_valid;
    wire memory_write;
    wire memory_code_fetch;
    wire [3:0] memory_cycle_class;
    wire [24:0] memory_address;
    wire [1:0] memory_byte_enable;
    wire [15:0] memory_data_out;
    wire memory_accept;
    wire memory_ready;
    logic [15:0] memory_read_data;
    wire memory_read_data_valid;

    wire dma_memory_valid;
    wire dma_memory_write;
    wire dma_memory_read;
    wire [24:0] dma_memory_address;
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
    wire [24:0] backend_address;
    wire [1:0]  backend_byte_enable;
    wire [15:0] backend_data_out;
    wire        backend_accept;
    wire        backend_ready;
    logic [15:0] backend_read_data;
    wire        backend_read_data_valid;
    wire        memory_port_protocol_error;
    wire        sdram_owner_protocol_error;

    wire        p03_out_valid, p03_out_command_valid;
    wire [1:0]  p03_out_owner;
    wire        p03_out_write, p03_out_refresh, p03_out_code_fetch, p03_out_burst;
    wire [3:0]  p03_out_cycle_class;
    wire [24:0] p03_out_address;
    wire [1:0]  p03_out_byte_enable;
    wire [15:0] p03_out_data_out;
    wire        p03_in_accept, p03_in_ready;
    wire [15:0] p03_in_read_data;
    wire        p03_in_read_data_valid;
    wire        p03_out_accept, p03_out_ready;
    wire [15:0] p03_out_read_data;
    wire        p03_out_read_data_valid;

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
    spk286_sdram_pin_model #(.MEM_WORDS(1<<24)) pins (
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

    task automatic floppy_mgmt_write(input logic [15:0] address,
                                     input logic [15:0] value);
        begin
            @(negedge clk);
            mgmt_address = address;
            mgmt_writedata = value;
            mgmt_write = 1'b1;
            @(posedge clk);
            @(negedge clk);
            mgmt_write = 1'b0;
        end
    endtask

    task automatic inject_keyboard_byte(input logic [7:0] value);
        integer guard;
        begin
            guard = 0;
            while (!keyboard_byte_ready) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 100000)
                    $fatal(1, "keyboard injection timeout byte=%02h", value);
            end
            keyboard_byte = value;
            keyboard_byte_valid = 1'b1;
            @(negedge clk);
            keyboard_byte_valid = 1'b0;
        end
    endtask

    task automatic inject_ctrl_alt_delete;
        begin
            // Match the byte stream generated by spk286_at_keyboard for the
            // controller's active translation mode. The BIOS keyboard IRQ
            // handler, rather than the fixture, must request the warm reset.
            if (keyboard_translate_set1) begin
                inject_keyboard_byte(8'h1D); // left Ctrl make
                inject_keyboard_byte(8'h38); // left Alt make
                inject_keyboard_byte(8'hE0);
                inject_keyboard_byte(8'h53); // Delete make
            end else begin
                inject_keyboard_byte(8'h14); // left Ctrl make, set 2
                inject_keyboard_byte(8'h11); // left Alt make, set 2
                inject_keyboard_byte(8'hE0);
                inject_keyboard_byte(8'h71); // Delete make, set 2
            end
        end
    endtask

    always @(posedge cpu_reset_request)
        cpu_reset_pulses = cpu_reset_pulses + 1;
    integer fetch_returns=0, cpu_fetch_returns=0;
    logic saw_opcode=0;
    logic [23:0] captured_word_address;
    wire [23:0] cs_base;
    always @(posedge clk) begin
        if(!reset && sdram_owner.u_KFSDRAM.read_flag_comb && pin_dq_valid!==2'b11)
            $fatal(1,"KF samples invalid DQ addr=%h valid=%b",sdram_owner.kf_address,pin_dq_valid);
        if(!reset && memory_port.cpu_cancelled_q && memory_ready)
            $fatal(1,"cancelled pre-reset response reached CPU memory ready");
        if(!cpu_boot_reset) begin
            if(dut.u_cpu.cpu.debug_protected_msw[0] && !phoenix_pm87)
                $fatal(1,"PE set during first-fetch test");
            if(backend_accept && backend_code_fetch) captured_word_address<=sdram_owner.kf_address;
            if(backend_ready && backend_code_fetch && backend_owner==0 &&
               !cpu_reset_request && !memory_port.cpu_cancelled_q) begin
                if(!backend_read_data_valid) $fatal(1,"fetch without VLD");
                if(backend_address>=25'h00f0000 && backend_address<=25'h00fffff) begin
                    if(backend_byte_enable[0] && backend_read_data[7:0]!==rom[{backend_address[15:1],1'b0}])
                        $fatal(1,"BIOS low lane addr=%h got=%h",backend_address,backend_read_data);
                    if(backend_byte_enable[1] && backend_read_data[15:8]!==rom[{backend_address[15:1],1'b1}])
                        $fatal(1,"BIOS high lane addr=%h got=%h",backend_address,backend_read_data);
                end else if (!warm_reset_test &&
                             !$test$plusargs("FULL_BOOT"))
                    $fatal(1,"early fetch outside ROM addr=%h",backend_address);
                if(fetch_returns<32) $display("FETCH[%0d] cpu=%06h word=%06h data=%04h be=%b dqm=%b req=%b valid=%b ready=%b csip=%04h:%04h base=%06h op=%02h rst=%b hlt=%b owner=%b kf=%0d",
                    fetch_returns,backend_address,captured_word_address,backend_read_data,backend_byte_enable,
                    {sdram_udqm,sdram_ldqm},backend_valid,backend_read_data_valid,backend_ready,
                    debug_cs,debug_ip,cs_base,debug_opcode,cpu_boot_reset,cpu_halted,sdram_owner.active_q,sdram_owner.u_KFSDRAM.state);
                fetch_returns<=fetch_returns+1;
            end
            if(debug_opcode==rom[16'hfff0]) saw_opcode<=1;
        end else if(!reset && cpu_bus_valid) $fatal(1,"CPU active during download");
    end

    // Observe architectural READY on the same edge used by the CPU. This is
    // equivalent to clk in the normal build and remains correct for the /2
    // diagnostic clock, whose edge occurs after the parent-clock event.
    always @(posedge clk_cpu) begin
        if (!reset && !cpu_boot_reset && cpu_bus_valid && cpu_ready &&
            cpu_bus_status == 4'hd) begin
            if(cpu_fetch_returns==0 && cpu_data_in[7:0]!==rom[16'hfff0])
                $fatal(1,"CPU first opcode data=%h",cpu_data_in);
            if ((cpu_address>=24'hff0000) ||
                (cpu_address>=24'h0f0000 && cpu_address<=24'h0fffff)) begin
                if(!cpu_address[0] && cpu_data_in[7:0]!==rom[{cpu_address[15:1],1'b0}])
                    $fatal(1,"CPU low byte mismatch addr=%h data=%h",cpu_address,cpu_data_in);
                if(!cpu_bus_bhe_n && cpu_data_in[15:8]!==rom[{cpu_address[15:1],1'b1}])
                    $fatal(1,"CPU high byte mismatch addr=%h data=%h",cpu_address,cpu_data_in);
            end else if (!warm_reset_test && !$test$plusargs("FULL_BOOT"))
                $fatal(1,"early CPU fetch outside ROM addr=%h",cpu_address);
            cpu_fetch_returns <= cpu_fetch_returns + 1;
        end
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
            reset_vector_fetches <= 0;
            saw_native_reset_response <= 1'b0;
            saw_native_reset_data <= 1'b0;
            saw_low_rom_fetch <= 1'b0;
            first_bios_read_count <= 0;
        end else begin
            if (trace_boot) begin
                if (dut.irq0 != trace_irq0_prev && trace_lines < 160) begin
                    $display("TRACE_IRQ0 level=%b csip=%04h:%04h ticks=%04h:%04h",
                             dut.irq0, debug_cs, debug_ip,
                             pins.mem[16'h0237], pins.mem[16'h0236]);
                    trace_lines <= trace_lines + 1;
                end
                trace_irq0_prev <= dut.irq0;
            end
            if (!profile_probe && backend_accept && (backend_owner == 2'd0)) begin
                accepted_memory_beats <= accepted_memory_beats + 1;
                if (backend_address == 25'h00FFFF0 &&
                    dut.at_memory_address == 24'hFFFFF0) begin
                    saw_native_reset_fetch <= 1'b1;
                    if (backend_code_fetch)
                        reset_vector_fetches <= reset_vector_fetches + 1;
                end
                if ((backend_address >= 24'h0F0000) &&
                    (backend_address <= 24'h0FFFFF))
                    saw_low_rom_fetch <= 1'b1;
            end

            // Capture the first returned CPU reads, not only accepted
            // commands.  This makes the test fail if the SDRAM address is
            // right but the returned word/lane/valid timing is wrong.
            if (!profile_probe && backend_ready && (backend_owner == 2'd0) && !backend_write &&
                !cpu_reset_request && !memory_port.cpu_cancelled_q &&
                (first_bios_read_count < 32)) begin
                if (first_bios_read_count == 0)
                    $display("AT_FIRST_READ addr=%06h be=%b data=%04h valid=%b",
                             backend_address, backend_byte_enable,
                             backend_read_data, backend_read_data_valid);
                first_bios_read_count <= first_bios_read_count + 1;
                if (backend_address == 25'h00FFFF0 &&
                    dut.at_memory_address == 24'hFFFFF0) begin
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
                end
                if (trace_boot &&
                    ((cpu_address == 24'h00046C) ||
                     (cpu_address == 24'h00046D) ||
                     (cpu_address == 24'h00046E) ||
                     (cpu_address == 24'h00046F)) &&
                    trace_lines < 240) begin
                    $display("TRACE_TICK_WRITE addr=%06h data=%04h csip=%04h:%04h",
                             cpu_address, cpu_data_out, debug_cs, debug_ip);
                    trace_lines <= trace_lines + 1;
                end
                if (trace_boot &&
                    ((cpu_address[15:0] == 16'h01F0) ||
                     (cpu_address[15:0] == 16'h01F1) ||
                     (cpu_address[15:0] == 16'h01F6) ||
                     (cpu_address[15:0] == 16'h01F7) ||
                     (cpu_address[15:0] == 16'h03F6)) &&
                    trace_lines < 240) begin
                    $display("TRACE_IDE_IO wr=%b port=%04h data=%04h be=%b csip=%04h:%04h",
                             cpu_bus_write, cpu_address[15:0], cpu_data_out,
                             cpu_bus_bhe_n ? 2'b01 : 2'b11, debug_cs, debug_ip);
                    trace_lines <= trace_lines + 1;
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
        if ($value$plusargs("LANDMARK_CASE=%d", landmark_case)) begin
            if (rom[16'hfff0] != 8'hea || rom[16'h8d85] != 8'hee ||
                rom[16'h8c50] != 8'he6 || rom[16'h8c51] != 8'hda)
                $fatal(1,"Landmark diagnostic image signature mismatch");
            // Preserve the on-disk checksum residues before selecting an entry.
            // Case 18 later neutralizes only the fixture's own ROM-byte delta.
            for(integer lane=0;lane<2;lane=lane+1) begin
                source_lane_sum[lane]=0;
                for(integer off=16'h8000+lane;off<65536;off=off+2)
                    source_lane_sum[lane]=(source_lane_sum[lane]+int'(rom[off])) & 255;
            end
            case (landmark_case)
                1: begin rom[16'hfff1]=8'h4b; rom[16'hfff2]=8'h8c; end
                2: begin rom[16'hfff1]=8'h74; rom[16'hfff2]=8'h8d; end
                3,15: begin end // Original reset entry; 15 continues through the first RAM test.
                4,5,6,7,8,9,11,12,16,17,18,19,20,21,22,23: begin
                    // Test fixture only: set SS like POST, gate timer2 on,
                    // then execute untouched diagnostic instructions in ROM.
                    case(landmark_case)
                        4: routine_entry=16'h8dcb; // Parity precheck
                        5: routine_entry=16'h8df6; // Full 16 KiB, five patterns
                        6: routine_entry=16'h8a45; // PIT0
                        7: routine_entry=16'h8adb; // PIT1
                        8: routine_entry=16'h8af3; // PIT2
                        9: routine_entry=16'h8e48; // Original refresh status loops
                        11: routine_entry=16'h8ddd; // Clear 64 KiB and print original RAM test header
                        16: routine_entry=16'h8e62; // Real-mode entry to PROTECTED MODE CPU
                        17: routine_entry=16'h94cd; // Later protected-mode RAM entry
                        18: routine_entry=16'h89cb; // Both original ROM checksum routines
                        19: routine_entry=16'h9191; // 8042 AA/55 self-test and AB/00 interface test
                        20: routine_entry=16'h91c0; // 8042 command-byte write and quiet scan lines
                        21,22: routine_entry=16'h923f; // Floppy adapter, then read
                        23: routine_entry=16'h91f6; // CMOS RAM save, 55h/AAh test and restore
                        12: routine_entry=16'h8df6; // Same isolated test with DS != ES
                    endcase
                    rom[16'hfff1]=0; rom[16'hfff2]=8'hff;
                    // CLI; MOV AX,F000; MOV SS,AX; XOR CX,CX;
                    // MOV AL,1; OUT 61,AL; JMP FAR F000:entry.
                    rom[16'hff00]=8'hfa; rom[16'hff01]=8'hb8;
                    rom[16'hff02]=0; rom[16'hff03]=8'hf0;
                    rom[16'hff04]=8'h8e; rom[16'hff05]=8'hd0;
                    rom[16'hff06]=8'h31; rom[16'hff07]=8'hc9;
                    rom[16'hff08]=8'hb0; rom[16'hff09]=1;
                    rom[16'hff0a]=8'he6; rom[16'hff0b]=8'h61;
                    rom[16'hff0c]=8'hea;
                    rom[16'hff0d]=routine_entry[7:0];
                    rom[16'hff0e]=routine_entry[15:8];
                    rom[16'hff0f]=0; rom[16'hff10]=8'hf0;
                    if(landmark_case==17) begin
                        // This later POST entry uses CALL, with writable SS:SP
                        // 0000:0800 established by the PM CPU continuation.
                        // CLI; MOV AX,0; MOV SS,AX; MOV SP,0800; JMP FAR F000:94CD.
                        rom[16'hff03]=0;
                        rom[16'hff06]=8'hbc; rom[16'hff07]=0; rom[16'hff08]=8'h08;
                        rom[16'hff09]=8'hea; rom[16'hff0a]=8'hcd; rom[16'hff0b]=8'h94;
                        rom[16'hff0c]=0; rom[16'hff0d]=8'hf0;
                    end
                    if(landmark_case==19 || landmark_case==20 ||
                       landmark_case==21 || landmark_case==22 ||
                       landmark_case==23) begin
                        // These routines call the shared 8042 helpers. Give
                        // their isolated fixture a writable real-mode stack;
                        // an SS in the F000 ROM window cannot retain CALL's
                        // return address through the production memory path.
                        // CLI; MOV AX,0; MOV SS,AX; MOV SP,0800;
                        // JMP FAR F000:routine_entry.
                        rom[16'hff03]=0;
                        rom[16'hff06]=8'hbc; rom[16'hff07]=0; rom[16'hff08]=8'h08;
                        rom[16'hff09]=8'hea;
                        rom[16'hff0a]=routine_entry[7:0];
                        rom[16'hff0b]=routine_entry[15:8];
                        rom[16'hff0c]=0; rom[16'hff0d]=8'hf0;
                    end
                    if(landmark_case==12) begin
                        // MOV AX,B800; MOV DS,AX; JMP FAR F000:8DF6.
                        rom[16'hff0c]=8'hb8; rom[16'hff0d]=0; rom[16'hff0e]=8'hb8;
                        rom[16'hff0f]=8'h8e; rom[16'hff10]=8'hd8;
                        rom[16'hff11]=8'hea; rom[16'hff12]=8'hf6; rom[16'hff13]=8'h8d;
                        rom[16'hff14]=0; rom[16'hff15]=8'hf0;
                    end
                    if(landmark_case==9) begin
                        // POST normally leaves PIT1 in mode2, count18.
                        rom[16'hff0c]=8'hb0; rom[16'hff0d]=8'h74;
                        rom[16'hff0e]=8'he6; rom[16'hff0f]=8'h43;
                        rom[16'hff10]=8'hb0; rom[16'hff11]=8'h12;
                        rom[16'hff12]=8'he6; rom[16'hff13]=8'h41;
                        rom[16'hff14]=8'hb0; rom[16'hff15]=0;
                        rom[16'hff16]=8'he6; rom[16'hff17]=8'h41;
                        rom[16'hff18]=8'hea; rom[16'hff19]=8'h48;
                        rom[16'hff1a]=8'h8e; rom[16'hff1b]=0; rom[16'hff1c]=8'hf0;
                    end
                    if(landmark_case==19) begin
                        // Keep the original commands and comparisons, but
                        // shorten only the no-response timeout in helper
                        // F000:A39B. A missing AB reply must fail quickly in
                        // simulation instead of consuming 20*65536 polls.
                        rom[16'ha3a6]=8'h90; rom[16'ha3a7]=8'h90;
                    end
                    if(landmark_case==20) begin
                        // Preserve the scan-lines test and its two timeout
                        // phases while reducing each empty poll loop to one
                        // status read per outer iteration.
                        rom[16'h91da]=8'h90; rom[16'h91db]=8'h90;
                        rom[16'h91e8]=8'h90; rom[16'h91e9]=8'h90;
                    end
                    if(landmark_case==21 || landmark_case==22) begin
                        // Keep every FDC operation and comparison intact while
                        // shortening four pure 65536-iteration settle loops.
                        rom[16'ha29c]=8'h90; rom[16'ha29d]=8'h90;
                        rom[16'ha2a1]=8'h90; rom[16'ha2a2]=8'h90;
                        rom[16'h9291]=8'h90; rom[16'h9292]=8'h90;
                        rom[16'h92ea]=8'h90; rom[16'h92eb]=8'h90;

                        // Install IRQ6 at vector 0Eh, initialize a single
                        // master 8259 at base 08h, unmask IRQ6 and enter the
                        // original adapter routine with a writable stack.
                        rom[16'hff00]=8'hfa;
                        rom[16'hff01]=8'h31; rom[16'hff02]=8'hc0;
                        rom[16'hff03]=8'h8e; rom[16'hff04]=8'hd8;
                        rom[16'hff05]=8'h8e; rom[16'hff06]=8'hd0;
                        rom[16'hff07]=8'hbc; rom[16'hff08]=8'h00; rom[16'hff09]=8'h08;
                        rom[16'hff0a]=8'hc7; rom[16'hff0b]=8'h06;
                        rom[16'hff0c]=8'h38; rom[16'hff0d]=8'h00;
                        rom[16'hff0e]=8'h60; rom[16'hff0f]=8'hff;
                        rom[16'hff10]=8'hc7; rom[16'hff11]=8'h06;
                        rom[16'hff12]=8'h3a; rom[16'hff13]=8'h00;
                        rom[16'hff14]=8'h00; rom[16'hff15]=8'hf0;
                        rom[16'hff16]=8'hba; rom[16'hff17]=8'h20; rom[16'hff18]=8'h00;
                        rom[16'hff19]=8'hb0; rom[16'hff1a]=8'h13; rom[16'hff1b]=8'hee;
                        rom[16'hff1c]=8'h42;
                        rom[16'hff1d]=8'hb0; rom[16'hff1e]=8'h08; rom[16'hff1f]=8'hee;
                        rom[16'hff20]=8'hb0; rom[16'hff21]=8'h01; rom[16'hff22]=8'hee;
                        rom[16'hff23]=8'hb0; rom[16'hff24]=8'hbf; rom[16'hff25]=8'hee;
                        rom[16'hff26]=8'hea; rom[16'hff27]=8'h3f;
                        rom[16'hff28]=8'h92; rom[16'hff29]=8'h00; rom[16'hff2a]=8'hf0;

                        // IRQ6: set Landmark's flag, send non-specific EOI,
                        // preserve AX and return through the real INTA frame.
                        rom[16'hff60]=8'h50;
                        rom[16'hff61]=8'hc6; rom[16'hff62]=8'h06;
                        rom[16'hff63]=8'h00; rom[16'hff64]=8'h04; rom[16'hff65]=8'h01;
                        rom[16'hff66]=8'hb0; rom[16'hff67]=8'h20;
                        rom[16'hff68]=8'he6; rom[16'hff69]=8'h20;
                        rom[16'hff6a]=8'h58; rom[16'hff6b]=8'hcf;
                    end
                end
                10: begin // Integration fixture: pending parity -> RTC unmask -> one NMI -> IRET.
                    rom[16'hfff1]=0; rom[16'hfff2]=8'hff;
                    rom[16'hff00]=8'hfa;
                    rom[16'hff01]=8'hb8;
                    rom[16'hff02]=8'h00;
                    rom[16'hff03]=8'h00;
                    rom[16'hff04]=8'h8e;
                    rom[16'hff05]=8'hd8;
                    rom[16'hff06]=8'h8e;
                    rom[16'hff07]=8'hd0;
                    rom[16'hff08]=8'hbc;
                    rom[16'hff09]=8'h00;
                    rom[16'hff0a]=8'h10;
                    rom[16'hff0b]=8'hc7;
                    rom[16'hff0c]=8'h06;
                    rom[16'hff0d]=8'h08;
                    rom[16'hff0e]=8'h00;
                    rom[16'hff0f]=8'h40;
                    rom[16'hff10]=8'hff;
                    rom[16'hff11]=8'hc7;
                    rom[16'hff12]=8'h06;
                    rom[16'hff13]=8'h0a;
                    rom[16'hff14]=8'h00;
                    rom[16'hff15]=8'h00;
                    rom[16'hff16]=8'hf0;
                    rom[16'hff17]=8'hb0;
                    rom[16'hff18]=8'h00;
                    rom[16'hff19]=8'he6;
                    rom[16'hff1a]=8'h61;
                    rom[16'hff1b]=8'hb0;
                    rom[16'hff1c]=8'h10;
                    rom[16'hff1d]=8'he6;
                    rom[16'hff1e]=8'h80;
                    rom[16'hff1f]=8'h90;
                    rom[16'hff20]=8'h90;
                    rom[16'hff21]=8'h90;
                    rom[16'hff22]=8'h90;
                    rom[16'hff23]=8'h90;
                    rom[16'hff24]=8'h90;
                    rom[16'hff25]=8'h90;
                    rom[16'hff26]=8'h90;
                    rom[16'hff27]=8'hb0;
                    rom[16'hff28]=8'h00;
                    rom[16'hff29]=8'he6;
                    rom[16'hff2a]=8'h70;
                    rom[16'hff2b]=8'hb0;
                    rom[16'hff2c]=8'h20;
                    rom[16'hff2d]=8'he6;
                    rom[16'hff2e]=8'h80;
                    rom[16'hff2f]=8'hf4;
                    rom[16'hff30]=8'heb;
                    rom[16'hff31]=8'hfd;
                    rom[16'hff40]=8'hb0;
                    rom[16'hff41]=8'h30;
                    rom[16'hff42]=8'he6;
                    rom[16'hff43]=8'h80;
                    rom[16'hff44]=8'hb0;
                    rom[16'hff45]=8'h0c;
                    rom[16'hff46]=8'he6;
                    rom[16'hff47]=8'h61;
                    rom[16'hff48]=8'hcf;
                end
                default: $fatal(1,"unsupported LANDMARK_CASE");
            endcase
            if(landmark_case==18) begin
                // Changing the fixture reset vector must not invalidate a good
                // ROM, nor repair a bad one. Keep the original lane residues.
                for(integer lane=0;lane<2;lane=lane+1) begin
                    if(rom[16'hb1f0+lane]!=0) $fatal(1,"CHECKSUM_FIXTURE_SPACE_NOT_EMPTY");
                    fixture_lane_sum=0;
                    for(integer off=16'h8000+lane;off<65536;off=off+2)
                        fixture_lane_sum=(fixture_lane_sum+int'(rom[off])) & 255;
                    rom[16'hb1f0+lane]=8'(source_lane_sum[lane]-fixture_lane_sum);
                end
                $display("CHECKSUM_SOURCE_RESIDUES even=%02h odd=%02h",8'(source_lane_sum[0]),8'(source_lane_sum[1]));
            end
            max_cpu_cycles = landmark_case==15 ? 200000000 : 50000000;
            $display("LANDMARK_CASE=%0d entry=f000:%02h%02h",landmark_case,rom[16'hfff2],rom[16'hfff1]);
        end
        if ($value$plusargs("MAX_CPU_CYCLES=%d", max_cpu_cycles))
            $display("MAX_CPU_CYCLES=%0d", max_cpu_cycles);
        keyboard_warm_reset_test =
            $value$plusargs("KBD_WARM_RESET_AT=%d", keyboard_warm_reset_at);
        if (keyboard_warm_reset_test)
            $display("KBD_WARM_RESET_AT=%0d", keyboard_warm_reset_at);
        forced_warm_reset_test =
            $value$plusargs("FORCE_WARM_RESET_STATE=%d",
                            forced_warm_reset_state);
        if (forced_warm_reset_test &&
            (forced_warm_reset_state < 0 || forced_warm_reset_state > 7))
            $fatal(1, "FORCE_WARM_RESET_STATE must be 0..7");
        if (forced_warm_reset_test)
            $display("FORCE_WARM_RESET_STATE=%0d", forced_warm_reset_state);
        if (CPU_DIV2_TEST)
            $display("CPU_DIV2 enabled");
        trace_boot = $test$plusargs("TRACE_BOOT");
        phoenix_pm87 = $test$plusargs("PHOENIX_PM87");
        for (index = 0; index < 4; index = index + 1)
            port80_sequence[index] = 8'h00;
    end

    // Directed RAM16 accesses use the production mapper and the complete
    // memory-port/buffer/SDRAM path while the CPU is held in boot reset.
    logic profile_probe = 0, profile_valid = 0, profile_write = 0;
    logic [23:0] profile_address = 0;
    logic [15:0] profile_data = 0;
    wire [24:0] profile_backend_address =
        dut.map_memory_backend_address(profile_address);
    wire memory_cpu_cancel = (cpu_boot_reset && !profile_probe) | cpu_reset_request;

    task automatic profile_access(input logic write_access,
                                  input logic [23:0] address,
                                  input logic [15:0] data);
        integer guard;
        begin
            @(negedge clk);
            profile_address = address;
            profile_write = write_access;
            profile_data = data;
            profile_valid = 1;
            guard = 0;
            do begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 1000) $fatal(1, "RAM16 access timed out at %h", address);
            end while (!memory_ready);
            if (!write_access && (!memory_read_data_valid || memory_read_data !== data))
                $fatal(1, "RAM16 read %h expected=%h actual=%h", address, data, memory_read_data);
            @(negedge clk);
            profile_valid = 0;
            // Allow the serialized port and physical burst to drain.
            repeat (16) @(negedge clk);
        end
    endtask

    // Exercise the real machine through the same serialized memory boundary
    // that the future MiSTer SDRAM/HPS owner will use.
    spk286_at_mister_memory_port memory_port (
        .clk(clk), .reset(reset),
        .cancel_cpu(memory_cpu_cancel),
        .cpu_valid(profile_probe ? profile_valid : memory_request_valid),
        .cpu_command_valid(profile_probe ? profile_valid : memory_command_valid),
        .cpu_write(profile_probe ? profile_write : memory_write),
        .cpu_code_fetch(profile_probe ? !profile_write : memory_code_fetch),
        .cpu_cycle_class(memory_cycle_class),
        .cpu_address(profile_probe ? profile_backend_address : memory_address),
        .cpu_byte_enable(profile_probe ? 2'b11 : memory_byte_enable),
        .cpu_data_out(profile_probe ? profile_data : memory_data_out),
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
        .backend_accept(p03_in_accept), .backend_ready(p03_in_ready),
        .backend_read_data(p03_in_read_data),
        .backend_read_data_valid(p03_in_read_data_valid),
        .protocol_error(memory_port_protocol_error)
    );

    spk286_at_sdram_read_buffer #(.ENABLE(1'b1)) p03_buffer (
        .clk(clk), .reset(reset),
        .cancel_cpu(memory_cpu_cancel), .enable(1'b1),
        .in_valid(backend_valid), .in_command_valid(backend_command_valid),
        .in_owner(backend_owner), .in_write(backend_write),
        .in_refresh(backend_refresh), .in_code_fetch(backend_code_fetch),
        .in_cycle_class(backend_cycle_class), .in_address(backend_address),
        .in_byte_enable(backend_byte_enable), .in_data_out(backend_data_out),
        .in_accept(p03_in_accept), .in_ready(p03_in_ready),
        .in_read_data(p03_in_read_data),
        .in_read_data_valid(p03_in_read_data_valid),
        .out_valid(p03_out_valid), .out_command_valid(p03_out_command_valid),
        .out_owner(p03_out_owner), .out_write(p03_out_write),
        .out_refresh(p03_out_refresh), .out_code_fetch(p03_out_code_fetch),
        .out_burst(p03_out_burst), .out_cycle_class(p03_out_cycle_class),
        .out_address(p03_out_address), .out_byte_enable(p03_out_byte_enable),
        .out_data_out(p03_out_data_out), .out_accept(p03_out_accept),
        .out_ready(p03_out_ready), .out_read_data(p03_out_read_data),
        .out_read_data_valid(p03_out_read_data_valid),
        .debug_hit_count(), .debug_miss_count(), .debug_fill_count(),
        .debug_physical_read_count(), .debug_invalidation_count()
    );

    // Observe the logical memory-port side after inserting P03 between the
    // port and the physical owner.
    assign backend_accept          = p03_in_accept;
    assign backend_ready           = p03_in_ready;
    assign backend_read_data       = p03_in_read_data;
    assign backend_read_data_valid = p03_in_read_data_valid;

    spk286_at_mister_sdram_owner #(
        .SDRAM_INIT_WAIT(16'd32)
    ) sdram_owner (
        .clk(clk), .reset(reset),
        .request_valid(p03_out_valid),
        .request_command_valid(p03_out_command_valid),
        .request_owner_refresh(p03_out_refresh),
        .request_write(p03_out_write),
        .request_code_fetch(p03_out_code_fetch),
        .request_burst(p03_out_burst),
        .request_cycle_class(p03_out_cycle_class),
        .request_address(p03_out_address),
        .request_byte_enable(p03_out_byte_enable),
        .request_data_out(p03_out_data_out),
        .request_accept(p03_out_accept), .request_ready(p03_out_ready),
        .request_read_data(p03_out_read_data),
        .request_read_data_valid(p03_out_read_data_valid),
        .physical_idle(physical_idle), .protocol_error(sdram_owner_protocol_error),
        .sdram_address(sdram_address), .sdram_cke(sdram_cke),
        .sdram_cs(sdram_cs), .sdram_ras(sdram_ras),
        .sdram_cas(sdram_cas), .sdram_we(sdram_we),
        .sdram_ba(sdram_ba), .sdram_dq_in(sdram_dq_in),
        .sdram_dq_out(sdram_dq_out), .sdram_dq_io(sdram_dq_io),
        .sdram_ldqm(sdram_ldqm), .sdram_udqm(sdram_udqm)
    );

    spk286_at_machine #(
        .CPU_USES_SAMPLE_EDGE(CPU_DIV2_TEST)
    ) dut (
        .clk(clk), .clk_cpu(clk_cpu),
        .cpu_sample_edge(CPU_DIV2_TEST ? ~clk_cpu_div : 1'b1),
        .reset(reset | machine_boot_reset), .cpu_reset(reset | cpu_boot_reset), .clk_video(clk_video), .splashscreen(1'b0),
        .ega_monitor_profile(2'b00),
        .installed_ram_size_osd(installed_ram_size_osd),
        .execute_enable(execute_enable),
        .counter_clock(counter_clock), .refresh_enable(refresh_enable),
        .mgmt_address(mgmt_address), .mgmt_writedata(mgmt_writedata),
        .mgmt_write(mgmt_write), .mgmt_read(mgmt_read),
        .mgmt_readdata(mgmt_readdata),
        .floppy_write_protect(2'b00), .floppy_present(floppy_present),
        .floppy_request(floppy_request),
        .keyboard_byte_valid(keyboard_byte_valid), .keyboard_byte(keyboard_byte),
        .keyboard_byte_ready(keyboard_byte_ready),
        .keyboard_translate_set1(keyboard_translate_set1),
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
        if (installed_ram_size_osd == 3'd4) begin
            if (dut.installed_ram_size_q !== 3'd4 ||
                dut.u_memory_decode.extended_ram_limit !== 24'hFDFFFF)
                $fatal(1, "RAM16 decoder profile was not applied");
            if (dut.u_devices.u_rtc.cmos_q[7'h17] !== 8'h80 ||
                dut.u_devices.u_rtc.cmos_q[7'h18] !== 8'h3B)
                $fatal(1, "RAM16 CMOS size was not 15232 KiB");
            $display("AT_RAM16_PROFILE_PASS limit=fdffff reserved=fe0000-feffff cmos=3b80");
            profile_probe = 1;
            // Write first, then read: a folded high address cannot pass by
            // immediately reading its own corruption of an earlier block.
            for (integer block = 'h10; block < 'hFE; block = block + 1)
                profile_access(1, 24'(block << 16), 16'hA500 ^ 16'(block));
            for (integer block = 'h10; block < 'hFE; block = block + 1)
                profile_access(0, 24'(block << 16), 16'hA500 ^ 16'(block));
            profile_access(1, 24'hDEFFFE, 16'h1234);
            profile_access(1, 24'hDFFFFE, 16'h5678);
            profile_access(1, 24'hFDFFFE, 16'h9ABC);
            profile_access(0, 24'hDEFFFE, 16'h1234);
            profile_access(0, 24'hDFFFFE, 16'h5678);
            profile_access(0, 24'hFDFFFE, 16'h9ABC);
            // Check the complete loaded BIOS, plus reads through both CPU
            // aliases, before allowing its reset vector to execute.
            for (integer offset = 0; offset < 65536; offset = offset + 2)
                if (pins.mem[('hF0000 + offset) >> 1] !== {rom[offset+1], rom[offset]})
                    $fatal(1, "RAM16 corrupted BIOS offset=%h", offset);
            profile_access(0, 24'hFF0000, {rom[1], rom[0]});
            profile_access(0, 24'h0F0000, {rom[1], rom[0]});
            profile_access(0, 24'hFFFFF0, {rom['hFFF1], rom['hFFF0]});
            profile_probe = 0;
            $display("AT_RAM16_BACKEND_ISOLATION_PASS blocks=238 bios_bytes=65536");
        end
        if(debug_cs!==16'hf000 || debug_ip!==16'hfff0 || cs_base!==24'hff0000)
            $fatal(1,"bad reset %h:%h base=%h",debug_cs,debug_ip,cs_base);
        if($value$plusargs("WAVE=%s",wave_path)) begin
            $dumpfile(wave_path); $dumpvars(0,spk286_at_bios_first_fetch_tb);
        end
        machine_boot_reset=0;
        if($test$plusargs("PHOENIX_FDC")) begin
            // Optional investigative acceleration scales PIT and FDC equally.
            // This is NOT a production timing test; omit it for real 50 MHz.
            if($test$plusargs("PHOENIX_FDC_FAST"))
                force dut.u_devices.u_storage_video.u_fdc.u_fdc.clk_rate=28'd5_000_000;
            for(integer drive=0;drive<2;drive=drive+1) begin
                floppy_mgmt_write(16'hF200+16'(drive*128),16'd1);
                floppy_mgmt_write(16'hF201+16'(drive*128),16'd0);
                floppy_mgmt_write(16'hF202+16'(drive*128),16'd80);
                floppy_mgmt_write(16'hF203+16'(drive*128),16'd18);
                floppy_mgmt_write(16'hF204+16'(drive*128),16'd2880);
                floppy_mgmt_write(16'hF205+16'(drive*128),16'd2);
            end
            floppy_mgmt_write(16'hF410,16'h0044);
        end
        if(landmark_case==21 || landmark_case==22) begin
            // 1.2 MB AT drive: 80 cylinders, 15 sectors, two heads.
            floppy_mgmt_write(16'hF200,16'h0001);
            floppy_mgmt_write(16'hF201,16'h0000);
            floppy_mgmt_write(16'hF202,16'd80);
            floppy_mgmt_write(16'hF203,16'd15);
            floppy_mgmt_write(16'hF204,16'd2400);
            floppy_mgmt_write(16'hF205,16'd2);
            if(!floppy_present[0]) $fatal(1,"LANDMARK_FLOPPY_MEDIA_NOT_PRESENT");
            if(landmark_case==22) fork
                begin : serve_landmark_floppy_sector
                    integer byte_index;
                    wait(floppy_request[0]);
                    for(byte_index=0;byte_index<512;byte_index=byte_index+1)
                        floppy_mgmt_write(16'hF20F,{8'h00,byte_index[7:0]});
                end
            join_none
        end
        // Match the top: devices run while the splash still holds the CPU.
        repeat (1024) begin
            @(negedge clk);
            if (cpu_fault || protocol_error)
                $fatal(1,"fault during CPU splash hold bridge=%b pic=%b pit=%b dma=%b devices=%b",dut.bridge_protocol_error,dut.pic_protocol_error,dut.pit_protocol_error,dut.dma_protocol_error,dut.devices_protocol_error);
        end
        cpu_boot_reset=0;
        for(cycles=0;cycles<max_cpu_cycles;cycles=cycles+1) begin
            @(negedge clk);
            if (keyboard_warm_reset_test && !keyboard_warm_reset_injected &&
                cycles >= keyboard_warm_reset_at &&
                keyboard_translate_set1 && keyboard_byte_ready) begin
                keyboard_warm_reset_injected = 1'b1;
                warm_reset_pulses_before = cpu_reset_pulses;
                warm_reset_fetches_before = reset_vector_fetches;
                warm_reset_cpu_fetches_before = cpu_fetch_returns;
                $display("KBD_WARM_RESET_INJECT cycle=%0d csip=%04h:%04h set1=%b bridge=%0d mem=%b/%b p03=%0d/%b owner=%b",
                         cycles, debug_cs, debug_ip, keyboard_translate_set1,
                         dut.u_bridge.state_q, memory_port.active_q,
                         memory_port.accepted_q, p03_buffer.state_q,
                         p03_buffer.physical_inflight_q, sdram_owner.active_q);
                inject_ctrl_alt_delete();
            end
            if (forced_warm_reset_test && !forced_warm_reset_injected &&
                cycles >= 10000 &&
                dut.u_bridge.state_q == forced_warm_reset_state[3:0]) begin
                if ($test$plusargs("CODE_BUFFER_RESET_STRESS")) begin
                    if (pins.mem['h08300] == 0 || refresh_count == 0 ||
                        p03_buffer.debug_hit_count == 0 || p03_buffer.debug_miss_count < 2)
                        $fatal(1, "CODE_BUFFER_RESET_STRESS missing IRQ/refresh/hit/miss evidence");
                    $display("CODE_BUFFER_RESET_STRESS irq_handlers=%0d refresh=%0d hits=%0d misses=%0d",
                             pins.mem['h08300], refresh_count,
                             p03_buffer.debug_hit_count, p03_buffer.debug_miss_count);
                end
                forced_warm_reset_injected = 1'b1;
                warm_reset_pulses_before = cpu_reset_pulses;
                warm_reset_fetches_before = reset_vector_fetches;
                warm_reset_cpu_fetches_before = cpu_fetch_returns;
                $display("FORCE_WARM_RESET_INJECT cycle=%0d csip=%04h:%04h bridge=%0d mem=%b/%b p03=%0d/%b owner=%b",
                         cycles, debug_cs, debug_ip, dut.u_bridge.state_q,
                         memory_port.active_q, memory_port.accepted_q,
                         p03_buffer.state_q,
                         p03_buffer.physical_inflight_q,
                         sdram_owner.active_q);
                force dut.u_devices.u_8042.reset_pulse_q = 1'b1;
                #1;
                if (!dut.cpu_core_reset || !cpu_reset_request)
                    $fatal(1, "forced warm reset did not reach machine boundary core=%b external=%b",
                           dut.cpu_core_reset, cpu_reset_request);
                @(posedge clk);
                #1;
                if (!dut.cpu_core_reset || cpu_reset_pulses <=
                    warm_reset_pulses_before)
                    $fatal(1, "forced warm reset was not sampled core=%b pulses=%0d",
                           dut.cpu_core_reset,
                           cpu_reset_pulses - warm_reset_pulses_before);
                @(negedge clk);
                release dut.u_devices.u_8042.reset_pulse_q;
            end
            if (phoenix_pm87) begin
                if (dut.u_cpu.cpu.debug_protected_msw[0])
                    phoenix_pm87_saw_pe = 1'b1;
                if (cpu_shutdown) begin
                    phoenix_pm87_saw_shutdown = 1'b1;
                    phoenix_pm87_shutdown_cycles = phoenix_pm87_shutdown_cycles + 1;
                end else begin
                    phoenix_pm87_shutdown_cycles = 0;
                end
                if (phoenix_pm87_shutdown_cycles > 8)
                    $fatal(1,"PHOENIX_PM87_SHUTDOWN_NOT_RESET csip=%h:%h msw=%h",
                           debug_cs,debug_ip,dut.u_cpu.cpu.debug_protected_msw);
                if (dut.spk_control_error || dut.spk_unsupported_opcode ||
                    dut.spk_microcode_fault || dut.spk_operand_blocked ||
                    dut.debug_bridge_error || memory_port_protocol_error ||
                    sdram_owner_protocol_error || loader_error)
                    $fatal(1,"PHOENIX_PM87_UNEXPECTED_FAULT csip=%h:%h op=%h",
                           debug_cs,debug_ip,debug_opcode);
                if (dut.at_ready && dut.at_io && dut.at_write &&
                    dut.at_address[15:0] == 16'h0080) begin
                    if (dut.at_data_out[7:0] == 8'he7)
                        $fatal(1,"PHOENIX_PM87_COPY_MISMATCH source=%h destination=%h",
                               pins.mem[16'h1000],pins.mem[16'h1800]);
                    if (dut.at_data_out[7:0] == 8'ha7) begin
                        if (!phoenix_pm87_saw_pe || !phoenix_pm87_saw_shutdown ||
                            reset_vector_fetches < 2 ||
                            dut.u_cpu.cpu.debug_protected_msw[0] || a20_enable ||
                            pins.mem[16'h1800] !== 16'ha55a)
                            $fatal(1,"PHOENIX_PM87_INCOMPLETE pe=%b shutdown=%b resets=%0d msw=%h a20=%b destination=%h",
                                   phoenix_pm87_saw_pe,phoenix_pm87_saw_shutdown,
                                   reset_vector_fetches,
                                   dut.u_cpu.cpu.debug_protected_msw,a20_enable,
                                   pins.mem[16'h1800]);
                        $display("PHOENIX_PM87_PASS resets=%0d destination=%h PE_reset=1 A20_closed=1 cycles=%0d",
                                 reset_vector_fetches,pins.mem[16'h1800],cycles);
                        $finish;
                    end
                end
            end
            if ($test$plusargs("LOADALL_XMS")) begin
                if (cpu_fault || protocol_error || memory_port_protocol_error ||
                    sdram_owner_protocol_error || loader_error || cpu_shutdown)
                    $fatal(1,"AT_LOADALL_XMS_FAULT csip=%h:%h op=%h unsupported=%b",
                           debug_cs,debug_ip,debug_opcode,dut.spk_unsupported_opcode);
                if (dut.at_ready && dut.at_io && dut.at_write &&
                    dut.at_address[15:0] == 16'h0080) begin
                    if (dut.at_data_out[7:0] == 8'he5)
                        $fatal(1,"AT_LOADALL_XMS_DATA_MISMATCH csip=%h:%h",debug_cs,debug_ip);
                    if (dut.at_data_out[7:0] == 8'ha5) begin
                        // Physical SDRAM contents independently check the CPU's
                        // comparisons, extended addressing and both byte lanes.
                        if (a20_enable || dut.u_cpu.cpu.debug_protected_msw[0] ||
                            pins.mem[20'h80100] !== 16'h125a ||
                            pins.mem[20'h80101] !== 16'ha534 ||
                            pins.mem[20'h8010f] !== 16'ha55a ||
                            pins.mem[20'h01800] !== 16'h125a ||
                            pins.mem[20'h01801] !== 16'ha534 ||
                            pins.mem[20'h0180f] !== 16'ha55a ||
                            pins.mem[20'h00100] !== 16'h5aa5)
                            $fatal(1,"AT_LOADALL_XMS_PHYSICAL_MISMATCH a20=%b extended=%h copied=%h alias=%h",
                                   a20_enable,pins.mem[20'h80100],pins.mem[20'h01800],pins.mem[20'h00100]);
                        $display("AT_LOADALL_XMS_PASS repeated_LOADALL=3 extended_copy_bytes=32 A20_alias=1 byte_lanes=1 cycles=%0d",cycles);
                        $finish;
                    end
                end
            end
            if($test$plusargs("PHOENIX_FDC")) begin
                if(dut.at_ready && dut.at_io &&
                   ((dut.at_address>=24'h3f0 && dut.at_address<=24'h3f7 && dut.at_address!=24'h3f4) ||
                    (dut.at_address==24'h71 && dut.at_write)))
                    $display("PHOENIX_IO cycle=%0d wr=%b port=%h out=%h in=%h ip=%h",cycles,dut.at_write,dut.at_address,dut.at_data_out,dut.at_read_data,debug_ip);
                if(dut.u_cpu.cpu.opcode_start && debug_cs==16'hf000 &&
                   (debug_ip==16'ha125 || debug_ip==16'ha169 || debug_ip==16'h9b55 || debug_ip==16'h9d22))
                    $display("PHOENIX_ENTRY cycle=%0d ip=%h gpr=%h BDA48E=%h BDA43E=%h",cycles,debug_ip,dut.debug_gpr,pins.mem[16'h247],pins.mem[16'h21f]);
                if(cpu_halted) begin
                    $display("PHOENIX_POST_RESULT BDA48F=%h cycles=%0d",pins.mem[16'h247][15:8],cycles);
                    if(pins.mem[16'h247][15:8]!==8'h44) $fatal(1,"PHOENIX_DRIVE_TYPE_MISMATCH");
                    $display("PHOENIX_POST_FDC_PASS");
                    $finish;
                end
            end
            if (landmark_case>=16 && landmark_case<=18) begin
                if (dut.u_cpu.cpu.debug_protected_msw[0] || cpu_reset_request)
                    $fatal(1,"PM_SKIP_ACTIVATED_PE_OR_RESET case=%0d",landmark_case);
                if (dut.at_ready && dut.at_write && !dut.at_io && dut.at_byte_enable[0]) begin
                    for (integer ch=0; ch<7; ch=ch+1) begin
                        if(dut.at_address == 24'h0B0000 + 24'(skip_screen_offset) + 24'(2*ch))
                            skip_mono[ch*8 +: 8] = dut.at_data_out[7:0];
                        if(dut.at_address == 24'h0B8000 + 24'(skip_screen_offset) + 24'(2*ch))
                            skip_color[ch*8 +: 8] = dut.at_data_out[7:0];
                    end
                end
                if (dut.u_cpu.cpu.opcode_start && debug_cs==16'hf000) begin
                    if ((debug_ip>=16'ha3b3 && debug_ip<=16'ha657) ||
                        (debug_ip>=16'h94db && debug_ip<=16'h972c))
                        $fatal(1,"PM_SKIP_ENTERED_UNSUPPORTED_PATH case=%0d ip=%h",landmark_case,debug_ip);
                    if(debug_ip==16'h9b68)
                        $fatal(1,"PM_SKIP_REACHED_FAIL_HANDLER case=%0d",landmark_case);
                    if (landmark_case==18 && debug_ip==16'h9cb5) begin
                        if (dut.debug_gpr[32 +: 16] !== (checksum_pass_count==0 ? 16'hab45 : 16'hab67))
                            $fatal(1,"CHECKSUM_WRONG_PASS_CONTEXT");
                        checksum_pass_count=checksum_pass_count+1;
                    end
                    if ((landmark_case==16 && debug_ip==16'h8ea8) ||
                        (landmark_case==17 && debug_ip==16'h973e)) begin
                        if(skip_mono !== SKIPPED_TEXT || skip_color !== SKIPPED_TEXT)
                            $fatal(1,"PM_SKIP_VIDEO_TEXT mono=%h color=%h",skip_mono,skip_color);
                        if (cpu_fault || protocol_error)
                            $fatal(1,"PM_SKIP_FAULT");
                        if(landmark_case==16 && dut.debug_segment_selectors[32 +: 16]!==16'h0000)
                            $fatal(1,"PM_SKIP_STACK_SEGMENT");
                        $display("AT_LANDMARK_PM_SKIP_PASS case=%0d next_ip=%h mono_color_SKIPPED=1 PE=0 reset=0 cycles=%0d",landmark_case,debug_ip,cycles);
                        $finish;
                    end
                    if(landmark_case==18 && debug_ip==16'h8a22) begin
                        if(checksum_pass_count!=2 || cpu_fault || protocol_error)
                            $fatal(1,"CHECKSUM_MISSING_PASSES count=%0d",checksum_pass_count);
                        $display("AT_LANDMARK_ROM_CHECKSUMS_PASS U27=PASS U47=PASS cycles=%0d",cycles);
                        $finish;
                    end
                end
            end
            if (landmark_case==10) begin
                if(parity_pulse_cycles>0) begin
                    parity_pulse_cycles=parity_pulse_cycles-1;
                    if(parity_pulse_cycles==0) parity_event=0;
                end
                if(nmi && !nmi_prev) begin
                    nmi_pulses=nmi_pulses+1;
                    if(nmi_mask || !dut.system_check_pending) $fatal(1,"NMI_SOURCE_OR_MASK");
                end
                nmi_prev=nmi;
                if(cpu_bus_valid && cpu_ready && cpu_bus_write && cpu_bus_status==4'ha && cpu_address==24'h80) begin
                    case(cpu_data_out[7:0])
                        8'h10: begin
                            if(!nmi_mask) $fatal(1,"NMI_NOT_MASKED_AT_RESET");
                            parity_event=1; parity_pulse_cycles=4;
                        end
                        8'h30: nmi_markers=nmi_markers+1;
                        8'h20: resumed_after_nmi=1;
                    endcase
                end
                if(cpu_halted && resumed_after_nmi) begin
                    if(nmi_pulses!=1 || nmi_markers!=1 || dut.system_check_pending || protocol_error || cpu_fault)
                        $fatal(1,"NMI_INTEGRATION_FAIL pulses=%0d handlers=%0d pending=%b",nmi_pulses,nmi_markers,dut.system_check_pending);
                    $display("AT_PORT61_NMI_INTEGRATION_PASS pending_masked_unmask_handler_clear_iret cycles=%0d",cycles);
                    $finish;
                end
            end
            if((landmark_case==5 || landmark_case>=11) && dut.u_cpu.cpu.opcode_start && debug_ip==16'h9f14) begin
                ram_test_active=1;
                // ES is about to be loaded from SI by the original routine.
                // Also check the known context, not merely addresses relative to an arbitrary CPU value.
                oracle_base=(landmark_case==11 || landmark_case==15) ? 24'h006e40 : 24'd0;
                if(dut.debug_gpr[96 +: 16] !== ((landmark_case==11 || landmark_case==15) ? 16'h06e4 : 16'd0))
                    $fatal(1,"RAM_ENTRY_SEGMENT case=%0d SI=%h",landmark_case,dut.debug_gpr[96 +: 16]);
                ram_reads=0; ram_writes=0;
            end
            if(landmark_case>=11 && dut.u_cpu.cpu.opcode_start &&
                (debug_ip==16'h8df6 || debug_ip==16'h9f14 || debug_ip==16'h9f3b ||
                 debug_ip==16'h9f4d || debug_ip==16'h9e49 || debug_ip==16'h9e93))
                $display("RAM_CONTEXT ip=%h gpr=%h seg=%h flags=%h",debug_ip,
                    dut.debug_gpr,dut.debug_segment_selectors,dut.debug_flags);
            if (landmark_case != 0) begin
                if(landmark_case==21 || landmark_case==22) begin
                    if(irq_request[6] && !floppy_irq_previous)
                        floppy_irq_edges=floppy_irq_edges+1;
                    floppy_irq_previous=irq_request[6];
                    if(dma_memory_valid && dma_memory_accept) begin
                        if(landmark_case==22 &&
                           (dma_memory_address !== 24'h000A00 + 24'(floppy_dma_beats) ||
                            dma_memory_byte_enable !==
                              (dma_memory_address[0] ? 2'b10 : 2'b01) ||
                            (dma_memory_address[0] ? dma_memory_data_out[15:8] :
                                                   dma_memory_data_out[7:0]) !==
                              8'(floppy_dma_beats)))
                            $fatal(1,"LANDMARK_FLOPPY_DMA_BYTE beat=%0d addr=%h be=%b data=%h",
                                   floppy_dma_beats,dma_memory_address,
                                   dma_memory_byte_enable,dma_memory_data_out);
                        floppy_dma_beats=floppy_dma_beats+1;
                    end
                end
                if (cpu_bus_valid && cpu_ready && (cpu_bus_status==4'ha || cpu_bus_status==4'h9)) begin
                    io_completed=io_completed+1;
                    if (io_completed<10 || cpu_address[15:0]==16'hd0)
                        $display("LANDMARK_IO count=%0d ip=%04h port=%04h wr=%b data_out=%04h data_in=%04h",io_completed,debug_ip,cpu_address[15:0],cpu_bus_write,cpu_data_out,cpu_data_in);
                end
                if (cpu_bus_valid && !cpu_ready && (cpu_bus_status==4'ha || cpu_bus_status==4'h9))
                    io_wait_cycles=io_wait_cycles+1;
                else io_wait_cycles=0;
                if (protocol_error && !protocol_reported) begin
                    protocol_reported=1;
                    $display("LANDMARK_PROTOCOL ip=%h bridge=%b arb=%b pic=%b pit=%b dma=%b refresh=%b dev=%b",debug_ip,dut.bridge_protocol_error,dut.arbiter_protocol_error,dut.pic_protocol_error,dut.pit_protocol_error,dut.dma_protocol_error,dut.refresh_protocol_error,dut.devices_protocol_error);
                end
                if (landmark_case==3 && protocol_error)
                    $fatal(1,"LANDMARK_EARLY_BOOT_FAULT csip=%h:%h io=%h",debug_cs,debug_ip,cpu_address);
                if (landmark_case==3 && debug_ip==16'h8a45) begin
                    $display("LANDMARK_EARLY_BOOT_PASS cycles=%0d io=%0d",cycles,io_completed);
                    $finish;
                end
                if (cpu_bus_valid && cpu_ready && cpu_bus_status==4'h9 && cpu_address==24'h61)
                    last_port61=cpu_data_in[15:8];
                if (ram_test_active && backend_ready && backend_owner==0 && !backend_code_fetch && backend_address<24'h0a0000) begin
                    if(backend_address<oracle_base || backend_address>=oracle_base+24'h4000)
                        $fatal(1,"RAM_ADDRESS_OUTSIDE_TEST_WINDOW addr=%h base=%h",backend_address,oracle_base);
                    if(landmark_case==5 || landmark_case==11 || landmark_case==12 || landmark_case==15) begin
                        // Independent of CPU flags and the SDRAM model: verify
                        // every address, byte lane and each original ROM pattern.
                        if(backend_byte_enable !== (backend_address[0] ? 2'b10 : 2'b01))
                            $fatal(1,"RAM_BYTE_LANE addr=%h be=%b",backend_address,backend_byte_enable);
                        if(backend_write) begin
                            if(backend_address !== oracle_base+24'(ram_writes % 16384) ||
                               (backend_address[0] ? backend_data_out[15:8] : backend_data_out[7:0]) !== memory_pattern(ram_writes))
                                $fatal(1,"RAM_WRITE_ORACLE beat=%0d addr=%h data=%h",ram_writes,backend_address,backend_data_out);
                        end else begin
                            if(!backend_read_data_valid || backend_address !== oracle_base+24'(ram_reads % 16384) ||
                               (backend_address[0] ? backend_read_data[15:8] : backend_read_data[7:0]) !== memory_pattern(ram_reads))
                                $fatal(1,"RAM_READ_ORACLE beat=%0d addr=%h data=%h",ram_reads,backend_address,backend_read_data);
                            if(ram_reads % 16384 == 16383)
                                $display("LANDMARK_RAM_PATTERN_PASS pattern=%02h bytes=16384 addresses_and_lanes_checked",memory_pattern(ram_reads));
                        end
                    end
                    if(backend_write) ram_writes=ram_writes+1;
                    else ram_reads=ram_reads+1;
                end
                // Observe instruction admission, not speculative prefetch past RET.
                // The header ends at 9B67, immediately before the fail handler.
                if(landmark_case>=4 && landmark_case<=15 && (landmark_case!=15 || ram_test_active) && dut.u_cpu.cpu.opcode_start && debug_cs==16'hf000) begin
                    if(debug_ip==16'h9b68 || ((landmark_case==5 || landmark_case>=11) &&
                       (debug_ip==16'h9e49 || debug_ip==16'h9e93)))
                        $fatal(1,"LANDMARK_PERIPHERAL_FAIL case=%0d target=%h port61=%h ram_reads=%0d writes=%0d gpr=%h seg=%h",landmark_case,backend_address,last_port61,ram_reads,ram_writes,dut.debug_gpr,dut.debug_segment_selectors);
                    if(debug_ip==16'h9cb5) begin
                        if(protocol_error || cpu_fault) $fatal(1,"routine passed with fault");
                        if((landmark_case==5 || landmark_case==11 || landmark_case==12 || landmark_case==15) && (ram_reads!=81920 || ram_writes!=81920))
                            $fatal(1,"memory coverage incomplete reads=%0d writes=%0d",ram_reads,ram_writes);
                        $display("LANDMARK_PERIPHERAL_PASS case=%0d cycles=%0d io=%0d port61=%h ram_reads=%0d writes=%0d",landmark_case,cycles,io_completed,last_port61,ram_reads,ram_writes);
                        $finish;
                    end
                end
                if (io_wait_cycles>1000)
                    $fatal(1,"LANDMARK_IO_STALL case=%0d csip=%h:%h port=%h at=%h be=%b accept=%b ready=%b bridge=%0d io_completed=%0d",landmark_case,debug_cs,debug_ip,cpu_address,dut.at_address,dut.at_byte_enable,dut.at_accept,dut.at_ready,dut.u_bridge.state_q,io_completed);
                if (debug_opcode==8'hba && ((landmark_case==1 && debug_ip==16'h8d1a) ||
                    (landmark_case==2 && debug_ip==16'h8dad)))
                    $fatal(1,"LANDMARK_ROUTINE_FAIL case=%0d ip=%h io_completed=%0d dma0_address=%h",landmark_case,debug_ip,io_completed,dut.u_dma.current_address_q[4]);
                if (debug_opcode==8'hba && ((landmark_case==1 && debug_ip==16'h8d20) ||
                    (landmark_case==2 && debug_ip==16'h8da7))) begin
                    if (protocol_error || cpu_fault)
                        $fatal(1,"Landmark routine passed with sticky fault");
                    $display("LANDMARK_ROUTINE_PASS case=%0d io_completed=%0d cycles=%0d",landmark_case,io_completed,cycles);
                    $finish;
                end
                if ((landmark_case==19 || landmark_case==20) &&
                    dut.u_cpu.cpu.opcode_start && debug_cs==16'hf000) begin
                    if (debug_ip==16'h9b68)
                        $fatal(1,"LANDMARK_KEYBOARD_FAIL case=%0d io_completed=%0d",landmark_case,io_completed);
                    if (debug_ip==16'h9cb5) begin
                        if (protocol_error || cpu_fault)
                            $fatal(1,"Landmark keyboard routine passed with sticky fault");
                        $display("LANDMARK_KEYBOARD_PASS case=%0d io_completed=%0d cycles=%0d",landmark_case,io_completed,cycles);
                        $finish;
                    end
                end
                if ((landmark_case==21 || landmark_case==22) &&
                    dut.u_cpu.cpu.opcode_start && debug_cs==16'hf000) begin
                    if (debug_ip==16'h9b68)
                        $fatal(1,"LANDMARK_FLOPPY_FAIL case=%0d passes=%0d irq6=%0d dma=%0d io=%0d",
                               landmark_case,floppy_pass_count,floppy_irq_edges,
                               floppy_dma_beats,io_completed);
                    if (debug_ip==16'h9cb5) begin
                        floppy_pass_count=floppy_pass_count+1;
                        if(landmark_case==21) begin
                            if(floppy_irq_edges<1 || protocol_error || cpu_fault)
                                $fatal(1,"LANDMARK_FLOPPY_ADAPTER_EVIDENCE");
                            $display("AT_LANDMARK_FLOPPY_ADAPTER_PASS irq6=%0d io=%0d cycles=%0d",
                                     floppy_irq_edges,io_completed,cycles);
                            $finish;
                        end
                        if(landmark_case==22 && floppy_pass_count==2) begin
                            if(floppy_dma_beats!=512 || floppy_irq_edges<4 ||
                               protocol_error || cpu_fault)
                                $fatal(1,"LANDMARK_FLOPPY_READ_EVIDENCE dma=%0d irq6=%0d",
                                       floppy_dma_beats,floppy_irq_edges);
                            for(integer sector_word=0;sector_word<256;
                                sector_word=sector_word+1)
                                if(pins.mem[16'h0500+sector_word] !==
                                   {8'(sector_word*2+1),8'(sector_word*2)})
                                    $fatal(1,"LANDMARK_FLOPPY_SDRAM_WORD word=%0d data=%h",
                                           sector_word,pins.mem[16'h0500+sector_word]);
                            $display("AT_LANDMARK_FLOPPY_READ_PASS dma_bytes=%0d irq6=%0d io=%0d cycles=%0d",
                                     floppy_dma_beats,floppy_irq_edges,io_completed,cycles);
                            $finish;
                        end
                    end
                end
                if (landmark_case==23 && dut.u_cpu.cpu.opcode_start &&
                    debug_cs==16'hf000) begin
                    if (debug_ip==16'h9b68)
                        $fatal(1,"LANDMARK_CMOS_RAM_FAIL io_completed=%0d",io_completed);
                    if (debug_ip==16'h9cb5) begin
                        if (protocol_error || cpu_fault)
                            $fatal(1,"Landmark CMOS RAM routine passed with sticky fault");
                        $display("AT_LANDMARK_CMOS_RAM_PASS bytes_10_3f=48 patterns=55_AA_restore io=%0d cycles=%0d",
                                 io_completed,cycles);
                        $finish;
                    end
                end
            end
            if((landmark_case==0 && !phoenix_pm87 &&
                (cpu_fault || protocol_error)) ||
               memory_port_protocol_error || sdram_owner_protocol_error ||
               loader_error || (cpu_shutdown && !phoenix_pm87))
                $fatal(1,"first fetch fault cycle=%0d csip=%h:%h op=%h",cycles,debug_cs,debug_ip,debug_opcode);
            if ((keyboard_warm_reset_injected ||
                 forced_warm_reset_injected) &&
                cpu_reset_pulses > warm_reset_pulses_before &&
                reset_vector_fetches > warm_reset_fetches_before &&
                cpu_fetch_returns >= warm_reset_cpu_fetches_before + 16) begin
                if (keyboard_warm_reset_injected)
                    $display("KBD_WARM_RESET_PASS cycle=%0d reset_pulses=%0d reset_vectors=%0d post_reset_fetches=%0d",
                             cycles, cpu_reset_pulses - warm_reset_pulses_before,
                             reset_vector_fetches - warm_reset_fetches_before,
                             cpu_fetch_returns - warm_reset_cpu_fetches_before);
                else
                    $display("FORCE_WARM_RESET_PASS state=%0d cycle=%0d reset_pulses=%0d reset_vectors=%0d post_reset_fetches=%0d",
                             forced_warm_reset_state, cycles,
                             cpu_reset_pulses - warm_reset_pulses_before,
                             reset_vector_fetches - warm_reset_fetches_before,
                             cpu_fetch_returns - warm_reset_cpu_fetches_before);
                $finish;
            end
            if(landmark_case==0 && !warm_reset_test &&
               !$test$plusargs("FULL_BOOT") &&
               fetch_returns>=32 && cpu_fetch_returns>=16 && saw_opcode &&
               saw_low_rom_fetch) begin
                $display("AT_BIOS_FIRST_FETCH_PASS fetches=%0d cpu_responses=%0d opcode=%02h cycles=%0d",fetch_returns,cpu_fetch_returns,rom[16'hfff0],cycles);
                $finish;
            end
        end
        $display("P03_STATE memport_active=%b accepted=%b owner=%b cancel=%b backend=%b/%b p03_state=%0d inflight=%b p03_out=%b/%b owner_active=%b kf_idle=%b refresh_req=%b refresh_grant=%b refresh_pending=%b refresh_active=%b arb_cpu_grant=%b hold=%b hlda=%b bridge=%0d cpu_ready=%b bus=%b/%h wr/oe=%b/%b a=%h bhe=%b live=%b lock=%b sample=%b divclk=%b fetch_active=%b fetch_restart=%b fetch_req=%b fetch_ready=%b pit0=%b pit0_count=%h pit0_run=%b pit0_mode=%h pit0_edge=%b",
                 memory_port.active_q, memory_port.accepted_q, memory_port.owner_q,
                 cpu_boot_reset, backend_valid, backend_command_valid,
                 p03_buffer.state_q, p03_buffer.physical_inflight_q,
                 p03_out_valid, p03_out_command_valid,
                 sdram_owner.active_q, sdram_owner.kf_idle,
                 dut.refresh_request, dut.refresh_grant,
                 dut.u_refresh.pending_q, dut.u_refresh.active_q,
                 dut.cpu_grant, cpu_hold_request, cpu_hlda,
                 dut.u_bridge.state_q, cpu_ready, cpu_bus_valid,
                 cpu_bus_status, cpu_bus_write, dut.cpu_data_oe,
                 cpu_address, cpu_bus_bhe_n,
                 dut.u_bridge.live_request_valid, cpu_bus_lock,
                 (CPU_DIV2_TEST ? ~clk_cpu_div : 1'b1), clk_cpu_div,
                 dut.u_cpu.cpu.fetch.active_q, dut.u_cpu.cpu.fetch.restart_pending_q,
                 dut.u_cpu.cpu.fetch_request_internal,
                 dut.u_cpu.cpu.fetch_request_ready_internal,
                 dut.pit_counter_out[0],
                 dut.u_pit.u_timer.u_KF8253_Counter_0.count,
                 dut.u_pit.u_timer.u_KF8253_Counter_0.start_counting,
                 dut.u_pit.u_timer.u_KF8253_Counter_0.select_mode,
                 dut.u_pit.u_timer.u_KF8253_Counter_0.count_edge);
        $fatal(1,"watchdog reads=%0d cpu=%0d csip=%h:%h hlt=%b ram_reads=%0d ram_writes=%0d gpr=%h",fetch_returns,cpu_fetch_returns,debug_cs,debug_ip,cpu_halted,ram_reads,ram_writes,dut.debug_gpr);
    end
    initial begin
        #(64'd5000000000); $fatal(1,"HPS/SDRAM startup watchdog");
    end
endmodule
