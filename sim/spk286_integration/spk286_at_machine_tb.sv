`timescale 1ns/1ps

`ifndef ENABLE_MIDI
`define ENABLE_MIDI 0
`endif

// Composed CPU-to-AT boundary test.  The memory model is intentionally small:
// it provides the externally loaded 64 KiB system ROM, sparse conventional
// memory and the same handshake used by a future MiSTer SDRAM owner.
module spk286_at_machine_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    logic cpu_local_reset = 1'b0;
    integer selected_cpu_profile = 0;
    logic [2:0] applied_cpu_profile;
    wire cpu_profile_pending;
    always #5 clk = ~clk;
    logic clk_video = 1'b0;
    always #17.45 clk_video = ~clk_video;

    logic execute_enable = 1'b1;
    logic counter_clock_limited = 1'b0;
    logic counter_clock_real;
    logic counter_clock_fast = 1'b0;
    logic counter_clock;
    logic full_pit = 1'b0;
    logic fast_pit = 1'b0;
    logic refresh_enable = 1'b1;
    logic pit_clock_active = 1'b0;
    integer pit_clock_rising_edges = 0;
    always_ff @(posedge clk) begin
        if (reset) begin
            counter_clock_limited <= 1'b0;
            pit_clock_active <= 1'b0;
            pit_clock_rising_edges <= 0;
        end else if (!pit_clock_active) begin
            counter_clock_limited <= 1'b0;
        end else if (pit_clock_rising_edges < 32) begin
            counter_clock_limited <= ~counter_clock_limited;
            if (!counter_clock_limited)
                pit_clock_rising_edges <= pit_clock_rising_edges + 1;
        end else begin
            counter_clock_limited <= 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (reset)
            counter_clock_fast <= 1'b0;
        else if (full_pit)
            counter_clock_fast <= ~counter_clock_fast;
        else
            counter_clock_fast <= 1'b0;
    end

    assign counter_clock = full_pit ?
                           (fast_pit ? counter_clock_fast : counter_clock_real) :
                           counter_clock_limited;
    spk286_at_pit_clock pit_clock_model(
        .clk(clk), .reset(reset), .counter_clock(counter_clock_real));

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
    // The IBM 5170 POST probes conventional memory well beyond the first
    // few KiB.  Model the installed 512 KiB as contiguous RAM; the old
    // sparse windows made the BIOS's first-64-KiB test fail by construction.
    logic [7:0] base_ram [0:524287];
    integer index;
    integer rom_file;
    integer loaded_bytes;
    reg [8*512-1:0] rom_path;
    logic runtime_mpu_enable = `ENABLE_MIDI;
    logic runtime_midi_rx = 1'b1;
    logic runtime_mpu_test;
    logic runtime_mpu_switched = 1'b0;
    logic mpu_rx_started = 1'b0;
    logic [7:0] trace_last_8042_status = 8'h00;
    logic [15:0] trace_last_8042_ip = 16'h0000;
    logic trace_last_8042_valid = 1'b0;

    task automatic send_midi_test_byte(input logic [7:0] data);
        integer bit_index;
        begin
            @(negedge clk);
            runtime_midi_rx = 1'b0;
            repeat (8) @(posedge clk);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                runtime_midi_rx = data[bit_index];
                repeat (16) @(posedge clk);
            end
            runtime_midi_rx = 1'b1;
            repeat (16) @(posedge clk);
        end
    endtask

    always @(posedge clk) begin
        if (!reset && $test$plusargs("MPU_RX_TEST") && !mpu_rx_started &&
            cpu_ready && cpu_bus_valid && cpu_bus_write &&
            (cpu_bus_status == 4'hA) && (cpu_address[15:0] == 16'h0331) &&
            ((cpu_data_out[7:0] == 8'h3f) ||
             (cpu_data_out[15:8] == 8'h3f))) begin
            mpu_rx_started = 1'b1;
            fork
                send_midi_test_byte(8'h55);
            join_none
        end
    end

    integer accepted_memory_beats = 0;
    integer accepted_io_writes = 0;
    integer refresh_beats = 0;
    integer irq0_edges = 0;
    integer port80_writes = 0;
    integer port81_writes = 0;
    integer pit_data_writes = 0;
    integer first_bios_read_count = 0;
    logic [7:0] last_post_code = 8'h00;
    logic [7:0] port80_sequence [0:3];
    logic saw_native_reset_fetch = 1'b0;
    logic saw_native_reset_response = 1'b0;
    logic saw_native_reset_data = 1'b0;
    logic saw_low_rom_fetch = 1'b0;

    function automatic logic [7:0] memory_read_byte(input logic [24:0] address);
        begin
            if ((address >= 25'h00F0000) && (address <= 25'h00FFFFF))
                memory_read_byte = rom[address[15:0]];
            else if (address < 24'h080000)
                memory_read_byte = base_ram[address[18:0]];
            else
                memory_read_byte = 8'h00;
        end
    endfunction

    task automatic write_memory_byte(input logic [24:0] address,
                                     input logic [7:0] value);
        begin
            if (address < 24'h080000)
                base_ram[address[18:0]] <= value;
        end
    endtask

    // Behavioural SDRAM model for the production KFSDRAM owner.  The model
    // uses the logical AT byte map while observing ACT/READ/WRITE commands and
    // DQM on the physical pins.  The production owner maps the logical byte
    // address to a physical SDRAM word with A >> 1, so reconstruct the even
    // byte address at this pin-level boundary.
    logic [12:0] sdram_active_row = 13'h0000;
    logic [1:0]  sdram_active_bank = 2'b00;
    logic [15:0] sdram_read_data_d1 = 16'h0000;
    logic [15:0] sdram_read_data_d2 = 16'h0000;
    wire sdram_command_active = !sdram_cs && !sdram_ras &&
                                 sdram_cas && sdram_we;
    wire sdram_command_read = !sdram_cs && sdram_ras &&
                              !sdram_cas && sdram_we;
    wire sdram_command_write = !sdram_cs && sdram_ras &&
                               !sdram_cas && !sdram_we;
    wire [23:0] sdram_command_address =
        {sdram_active_bank, sdram_active_row, sdram_address[8:0]};
    wire [23:0] sdram_command_byte_address =
        {sdram_command_address[22:0], 1'b0};

    always_ff @(posedge clk) begin
        if (reset) begin
            sdram_active_row <= 13'h0000;
            sdram_active_bank <= 2'b00;
            sdram_read_data_d1 <= 16'h0000;
            sdram_read_data_d2 <= 16'h0000;
        end else begin
            if (sdram_command_active) begin
                sdram_active_row <= sdram_address;
                sdram_active_bank <= sdram_ba;
            end
            if (sdram_command_read) begin
                sdram_read_data_d1 <= {
                    memory_read_byte(sdram_command_byte_address + 24'd1),
                    memory_read_byte(sdram_command_byte_address)
                };
            end
            sdram_read_data_d2 <= sdram_read_data_d1;
            if (sdram_command_write) begin
                if (!sdram_ldqm)
                    write_memory_byte(sdram_command_byte_address,
                                      sdram_dq_out[7:0]);
                if (!sdram_udqm)
                    write_memory_byte(sdram_command_byte_address + 24'd1,
                                      sdram_dq_out[15:8]);
            end
        end
    end

    assign sdram_dq_in = sdram_read_data_d2;

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
                if (backend_address == 25'h00FFFF0 &&
                    dut.at_memory_address == 24'hFFFFF0)
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
                if ($test$plusargs("TRACE_8042") &&
                    ((cpu_address[15:0] == 16'h0060) ||
                     (cpu_address[15:0] == 16'h0064)))
                    $display("TRACE_8042 cs:ip=%04h:%04h W port=%04h data=%04h status=%02h a20=%b",
                             debug_cs, debug_ip, cpu_address[15:0], cpu_data_out,
                             dut.u_devices.u_8042.current_read_data,
                             a20_enable);
                accepted_io_writes <= accepted_io_writes + 1;
                if (cpu_address[15:0] == 16'h0080) begin
                    last_post_code <= cpu_data_out[7:0];
                    if ($test$plusargs("TRACE_POST") && port80_writes < 64)
                        $display("TRACE_POST t=%0t cs:ip=%04h:%04h code=%02h",
                                 $time, debug_cs, debug_ip, cpu_data_out[7:0]);
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
            if ($test$plusargs("TRACE_8042") && cpu_ready && cpu_bus_valid &&
                !cpu_bus_write && (cpu_bus_status == 4'h9) &&
                (cpu_address[15:0] == 16'h0060))
                $display("TRACE_8042 cs:ip=%04h:%04h R port=%04h data=%04h status=%02h a20=%b",
                         debug_cs, debug_ip, cpu_address[15:0], cpu_data_in,
                         dut.u_devices.u_8042.current_read_data,
                         a20_enable);
            if ($test$plusargs("TRACE_8042") && cpu_ready && cpu_bus_valid &&
                !cpu_bus_write && (cpu_bus_status == 4'h9) &&
                (cpu_address[15:0] == 16'h0064) &&
                (!trace_last_8042_valid ||
                 (cpu_data_in[7:0] != trace_last_8042_status) ||
                 (debug_ip != trace_last_8042_ip))) begin
                $display("TRACE_8042 cs:ip=%04h:%04h R port=%04h data=%04h status=%02h a20=%b",
                         debug_cs, debug_ip, cpu_address[15:0], cpu_data_in,
                         dut.u_devices.u_8042.current_read_data,
                         a20_enable);
                trace_last_8042_status <= cpu_data_in[7:0];
                trace_last_8042_ip <= debug_ip;
                trace_last_8042_valid <= 1'b1;
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
        for (index = 0; index < 524288; index = index + 1)
            base_ram[index] = 8'h00;
        for (index = 0; index < 4; index = index + 1)
            port80_sequence[index] = 8'h00;
    end

    // Exercise the real machine through the same serialized memory boundary
    // that the future MiSTer SDRAM/HPS owner will use.
    spk286_at_mister_memory_port memory_port (
        .clk(clk), .reset(reset),
        .cancel_cpu(cpu_reset_request),
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
        .loader_valid(1'b0), .loader_write(1'b0),
        .loader_address(24'h000000), .loader_byte_enable(2'b00),
        .loader_data_out(16'h0000), .loader_accept(), .loader_ready(),
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
        .physical_idle(), .protocol_error(sdram_owner_protocol_error),
        .sdram_address(sdram_address), .sdram_cke(sdram_cke),
        .sdram_cs(sdram_cs), .sdram_ras(sdram_ras),
        .sdram_cas(sdram_cas), .sdram_we(sdram_we),
        .sdram_ba(sdram_ba), .sdram_dq_in(sdram_dq_in),
        .sdram_dq_out(sdram_dq_out), .sdram_dq_io(sdram_dq_io),
        .sdram_ldqm(sdram_ldqm), .sdram_udqm(sdram_udqm)
    );

    spk286_at_machine dut (
        .clk(clk), .clk_cpu(clk), .cpu_sample_edge(1'b1), .reset(reset), .video_reset(reset),
        .cpu_reset(reset | cpu_local_reset), .clk_video(clk_video), .splashscreen(1'b0),
        .cpu_speed_requested(3'(selected_cpu_profile)),
        .cpu_speed_active(applied_cpu_profile), .cpu_speed_pending(cpu_profile_pending),
        .ega_monitor_profile(2'b00),
        .installed_ram_size_osd(3'd0),
        .at286ctl_eff_mpu401(runtime_mpu_enable),
        .midi_baudce(1'b1), .uart_baudce(1'b1), .midi_rx(runtime_midi_rx),
        .uart1_rx(1'b1),
        .uart2_rx(1'b1), .uart2_cts_n(1'b1), .uart2_dsr_n(1'b1),
        .uart2_dcd_n(1'b1),
        .execute_enable(execute_enable),
        .counter_clock(counter_clock), .refresh_enable(refresh_enable),
        .mgmt_address(16'h0000), .mgmt_writedata(16'h0000),
        .mgmt_write(1'b0), .mgmt_read(1'b0), .mgmt_readdata(),
        .floppy_write_protect(2'b00), .floppy_present(), .floppy_request(),
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
        .debug_cs(debug_cs), .debug_ip(debug_ip),
        .debug_bus_state(debug_bus_state), .refresh_count(refresh_count),
        .dma_side_effect_count(dma_side_effect_count),
        .device_side_effect_count(device_side_effect_count),
        .protocol_error(protocol_error)
    );

    initial begin : run
        integer cycles;
        integer max_cycles;
        integer mrbios_warm_restarts;
        integer last_mrbios_restart_port80_writes;
        integer mrbios_reset_grace;
        logic mrbios_ram_fault_seen;
        if (!$value$plusargs("MAX_CYCLES=%d", max_cycles))
            max_cycles = 2000000;
        if (!$value$plusargs("CPU_PROFILE=%d", selected_cpu_profile))
            selected_cpu_profile = 0;
        if (selected_cpu_profile < 0 || selected_cpu_profile > 7)
            $fatal(1, "invalid CPU_PROFILE=%0d", selected_cpu_profile);

        runtime_mpu_test = $test$plusargs("RUNTIME_MPU_ENABLE");
        mrbios_warm_restarts = 0;
        last_mrbios_restart_port80_writes = -1;
        mrbios_reset_grace = 0;
        mrbios_ram_fault_seen = 1'b0;
        full_pit = $test$plusargs("FULL_PIT");
        fast_pit = $test$plusargs("FAST_PIT");
        if (runtime_mpu_test) begin
            runtime_mpu_enable = 1'b0;
            runtime_midi_rx = 1'b0;
        end

        repeat (8) @(posedge clk);
        reset = 1'b0;
        #1;
        if (applied_cpu_profile !== 3'(selected_cpu_profile) || cpu_profile_pending)
            $fatal(1, "CPU profile was not applied through machine reset");

        // The AT motherboard converts the 80286 SHUTDOWN indication into a
        // CPU-local reset and exports the same pulse to cancel a retained
        // transaction at the serialized memory boundary.
        force dut.spk_shutdown = 1'b1;
        #1;
        if (!dut.cpu_core_reset || !cpu_reset_request)
            $fatal(1, "SHUTDOWN_WARM_RESET_PATH_FAILURE core=%b external=%b",
                   dut.cpu_core_reset,cpu_reset_request);
        release dut.spk_shutdown;
        @(posedge clk);
        #1;
        if (dut.cpu_core_reset || cpu_reset_request)
            $fatal(1, "SHUTDOWN_WARM_RESET_PATH_STUCK core=%b external=%b",
                   dut.cpu_core_reset,cpu_reset_request);

        // The IBM AT 8042 starts with A20 disabled; BIOS POST opens it
        // explicitly through the output-port protocol.
        // When explicitly gated, the machine boundary must reproduce the
        // AT wrap at bit 20 for CPU memory transactions; the raw bridge
        // address remains unchanged. Legacy DMA is independent of A20.
        if (a20_enable)
            $fatal(1, "A20_RESET_STATE_FAILURE expected disabled at reset");
        force dut.at_address = 24'h10_1234;
        force dut.at_io = 1'b0;
        force dut.a20_enable = 1'b0;
        #1;
        if (dut.at_memory_address !== 24'h00_1234 ||
            memory_address !== 24'h00_1234)
            $fatal(1, "A20_OFF_CPU_GATE_FAILURE raw=%06h gated=%06h output=%06h",
                   dut.at_address, dut.at_memory_address, memory_address);
        force dut.at_address = 24'hFF_FFF0;
        #1;
        if (dut.at_memory_address !== 24'hFF_FFF0 ||
            memory_address !== 25'h00F_FFF0)
            $fatal(1, "A20_RESET_ALIAS_FAILURE gated=%06h output=%06h",
                   dut.at_memory_address, memory_address);
        force dut.at_address = 24'h10_1234;
        force dut.a20_enable = 1'b1;
        #1;
        if (dut.at_memory_address !== 24'h10_1234 ||
            memory_address !== 24'h10_1234)
            $fatal(1, "A20_ON_CPU_GATE_FAILURE raw=%06h gated=%06h output=%06h",
                   dut.at_address, dut.at_memory_address, memory_address);
        force dut.at_io = 1'b1;
        force dut.a20_enable = 1'b0;
        #1;
        if (dut.at_memory_address !== 24'h10_1234)
            $fatal(1, "A20_IO_GATE_FAILURE address=%06h", dut.at_memory_address);
        force dut.dma_transfer_address = 24'h10_5678;
        #1;
        if (dma_memory_address !== 24'h10_5678)
            $fatal(1, "A20_DMA_MUST_BYPASS_GATE address=%06h", dma_memory_address);
        release dut.dma_transfer_address;
        release dut.at_io;
        release dut.a20_enable;
        release dut.at_address;

        for (cycles = 0; cycles < max_cycles; cycles = cycles + 1) begin
            @(negedge clk);
            if (mrbios_reset_grace != 0)
                mrbios_reset_grace = mrbios_reset_grace - 1;
            if ($test$plusargs("MRBIOS_WARM_RESET") ||
                $test$plusargs("MRBIOS_DIRECT_RESTART")) begin
                if (!mrbios_ram_fault_seen && debug_cs == 16'hF000 &&
                    debug_ip == 16'h9067) begin
                    mrbios_ram_fault_seen = 1'b1;
                    $display("MRBIOS_RAM_FAULT restart=%0d ax=%04h bx=%04h si=%04h di=%04h flags=%04h",
                             mrbios_warm_restarts, dut.spk_debug_gpr[15:0],
                             dut.spk_debug_gpr[63:48],
                             dut.spk_debug_gpr[111:96],
                             dut.spk_debug_gpr[127:112], dut.spk_debug_flags);
                end
                if (cpu_halted) begin
                    $fatal(1, "MRBIOS_HALT restart=%0d post=%02h cs_ip=%04h:%04h ax=%04h di=%04h",
                           mrbios_warm_restarts, last_post_code, debug_cs,
                           debug_ip, dut.spk_debug_gpr[15:0],
                           dut.spk_debug_gpr[127:112]);
                end
                if (last_post_code == 8'h0B &&
                    port80_writes != last_mrbios_restart_port80_writes) begin
                    if (mrbios_warm_restarts == 3) begin
                        $display("MRBIOS_WARM_MEMORY_PASS restarts=%0d post=%02h memory_beats=%0d",
                                 mrbios_warm_restarts, last_post_code,
                                 accepted_memory_beats);
                        $finish;
                    end
                    // Keep RAM and chipset live. DIRECT_RESTART mirrors the
                    // MR BIOS keyboard handler's near jump to POST; the other
                    // mode pulses only the processor reset input.
                    base_ram[16'h0472] = 8'h34;
                    base_ram[16'h0473] = 8'h12;
                    last_mrbios_restart_port80_writes = port80_writes;
                    mrbios_warm_restarts = mrbios_warm_restarts + 1;
                    mrbios_ram_fault_seen = 1'b0;
                    if ($test$plusargs("MRBIOS_DIRECT_RESTART")) begin
                        dut.u_cpu.sim_redirect = 1'b1;
                        // The native-jump mode executes the handler's own
                        // F49A near jump, exercising the CPU's branch and
                        // prefetch flush instead of jumping straight to POST.
                        dut.u_cpu.sim_redirect_ip =
                            $test$plusargs("MRBIOS_NATIVE_JUMP") ? 16'hF49A : 16'hC2E6;
                        @(posedge clk);
                        #1;
                        dut.u_cpu.sim_redirect = 1'b0;
                        dut.u_cpu.sim_redirect_ip = 16'h0000;
                    end else begin
                        cpu_local_reset = 1'b1;
                        @(posedge clk);
                        #1;
                        cpu_local_reset = 1'b0;
                    end
                    mrbios_reset_grace = 4;
                    $display("MRBIOS_WARM_RESTART restart=%0d direct=%0d cycle=%0d",
                             mrbios_warm_restarts,
                             $test$plusargs("MRBIOS_DIRECT_RESTART"), cycles);
                end
            end
            if (runtime_mpu_test && !runtime_mpu_switched &&
                (cycles == 500)) begin
                runtime_mpu_enable = 1'b1;
                runtime_mpu_switched = 1'b1;
                $display("AT_RUNTIME_MPU_ENABLED midi_rx=%b", runtime_midi_rx);
            end
            if ((cpu_fault || protocol_error) && mrbios_reset_grace == 0)
                $fatal(1, "AT_SYSTEM_FAULT cycle=%0d cs_ip=%04h:%04h opcode=%02h owner=%0d bridge_idle=%b fault=%b",
                       cycles, debug_cs, debug_ip, debug_opcode, bus_owner,
                       bridge_idle, cpu_fault);
            if (memory_port_protocol_error)
                $fatal(1, "AT_MEMORY_PORT_FAULT cycle=%0d owner=%0d address=%06h",
                       cycles, backend_owner, backend_address);
            if (sdram_owner_protocol_error)
                $fatal(1, "AT_SDRAM_OWNER_FAULT cycle=%0d owner=%0d address=%06h",
                       cycles, backend_owner, backend_address);
            if (port81_writes != 0 && !full_pit)
                $fatal(1, "AT_SYSTEM_DIAGNOSTIC_FAILURE cycle=%0d port81=%0d cs_ip=%04h:%04h",
                       cycles, port81_writes, debug_cs, debug_ip);
            if (cpu_shutdown)
                $fatal(1, "AT_SYSTEM_SHUTDOWN cycle=%0d cs_ip=%04h:%04h",
                       cycles, debug_cs, debug_ip);
            if (!full_pit && port80_writes >= 4 &&
                port80_sequence[0] == 8'h70 &&
                port80_sequence[1] == 8'h72 &&
                port80_sequence[2] == 8'h71 &&
                port80_sequence[3] == 8'h86 &&
                saw_native_reset_fetch && saw_native_reset_response &&
                saw_native_reset_data && saw_low_rom_fetch &&
                irq0_edges != 0 && refresh_beats != 0) begin
                $display("AT_SYSTEM_BOUNDARY_PASS memory_beats=%0d io_writes=%0d irq0=%0d refresh=%0d port80=%0d",
                         accepted_memory_beats, accepted_io_writes,
                         irq0_edges, refresh_beats, port80_writes);
                $finish;
            end
        end
        $fatal(1, "AT_SYSTEM_WATCHDOG reset_fetch=%b reset_response=%b reset_data=%b low_rom=%b port80=%0d irq0=%0d refresh=%0d memory=%0d halted=%b intr=%b bus_valid=%b status=%h address=%06h cs_ip=%04h:%04h seq=%02h,%02h,%02h,%02h",
               saw_native_reset_fetch, saw_native_reset_response,
               saw_native_reset_data, saw_low_rom_fetch, port80_writes,
               irq0_edges, refresh_beats, accepted_memory_beats, cpu_halted,
               intr, cpu_bus_valid, cpu_bus_status, cpu_address, debug_cs,
               debug_ip, port80_sequence[0], port80_sequence[1],
               port80_sequence[2], port80_sequence[3]);
    end
endmodule
