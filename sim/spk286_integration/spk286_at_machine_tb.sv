`timescale 1ns/1ps

// Composed CPU-to-AT boundary test.  The memory model is intentionally small:
// it provides the externally loaded 64 KiB system ROM, sparse conventional
// memory and the same handshake used by a future MiSTer SDRAM owner.
module spk286_at_machine_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    logic execute_enable = 1'b1;
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
    wire memory_accept = memory_command_valid;
    wire memory_ready = memory_request_valid;
    logic [15:0] memory_read_data;
    wire memory_read_data_valid = memory_request_valid && !memory_write;

    wire dma_memory_valid;
    wire dma_memory_write;
    wire dma_memory_read;
    wire [23:0] dma_memory_address;
    wire [1:0] dma_memory_byte_enable;
    wire [15:0] dma_memory_data_out;
    wire dma_memory_accept = dma_memory_valid;
    wire dma_memory_ready = dma_memory_valid;
    logic [15:0] dma_memory_data_in;

    wire refresh_memory_valid;
    wire [23:0] refresh_memory_address;
    wire refresh_memory_accept = refresh_memory_valid;
    wire refresh_memory_ready = refresh_memory_valid;

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
    logic [7:0] low_ram [0:4095];
    logic [7:0] data_ram [0:4095];
    logic [7:0] stack_ram [0:4095];
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
    logic [7:0] port80_sequence [0:3];
    logic saw_native_reset_fetch = 1'b0;
    logic saw_low_rom_fetch = 1'b0;

    function automatic logic [7:0] memory_read_byte(input logic [23:0] address);
        begin
            if (((address >= 24'h0F0000) && (address <= 24'h0FFFFF)) ||
                ((address >= 24'hFFF000) && (address <= 24'hFFFFFF)))
                memory_read_byte = rom[address[15:0]];
            else if (address < 24'h001000)
                memory_read_byte = low_ram[address[11:0]];
            else if ((address >= 24'h010000) && (address < 24'h011000))
                memory_read_byte = data_ram[address[11:0]];
            else if ((address >= 24'h01F000) && (address < 24'h020000))
                memory_read_byte = stack_ram[address[11:0]];
            else
                memory_read_byte = 8'h00;
        end
    endfunction

    task automatic write_memory_byte(input logic [23:0] address,
                                     input logic [7:0] value);
        begin
            if (address < 24'h001000)
                low_ram[address[11:0]] <= value;
            else if ((address >= 24'h010000) && (address < 24'h011000))
                data_ram[address[11:0]] <= value;
            else if ((address >= 24'h01F000) && (address < 24'h020000))
                stack_ram[address[11:0]] <= value;
        end
    endtask

    always_comb begin
        if (memory_byte_enable[1])
            memory_read_data = {memory_read_byte(memory_address), 8'h00};
        else
            memory_read_data = {8'h00, memory_read_byte(memory_address)};
    end

    always_comb begin
        if (dma_memory_byte_enable[1])
            dma_memory_data_in = {memory_read_byte(dma_memory_address), 8'h00};
        else
            dma_memory_data_in = {8'h00, memory_read_byte(dma_memory_address)};
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
            saw_low_rom_fetch <= 1'b0;
        end else begin
            if (memory_command_valid) begin
                accepted_memory_beats <= accepted_memory_beats + 1;
                if (memory_address == 24'hFFFFF0)
                    saw_native_reset_fetch <= 1'b1;
                if ((memory_address >= 24'h0F0000) &&
                    (memory_address <= 24'h0FFFFF))
                    saw_low_rom_fetch <= 1'b1;
                if (memory_write) begin
                    if (memory_byte_enable[0])
                        write_memory_byte(memory_address, memory_data_out[7:0]);
                    if (memory_byte_enable[1])
                        write_memory_byte(memory_address,
                                          memory_data_out[15:8]);
                end
            end

            if (dma_memory_valid && dma_memory_write) begin
                if (dma_memory_byte_enable[0])
                    write_memory_byte(dma_memory_address,
                                      dma_memory_data_out[7:0]);
                if (dma_memory_byte_enable[1])
                    write_memory_byte(dma_memory_address + 24'd1,
                                      dma_memory_data_out[15:8]);
            end

            if (refresh_memory_valid)
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
        for (index = 0; index < 4096; index = index + 1) begin
            low_ram[index] = 8'h00;
            data_ram[index] = 8'h00;
            stack_ram[index] = 8'h00;
        end
        for (index = 0; index < 4; index = index + 1)
            port80_sequence[index] = 8'h00;
    end

    spk286_at_machine dut (
        .clk(clk), .reset(reset), .execute_enable(execute_enable),
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
        .debug_cs(debug_cs), .debug_ip(debug_ip),
        .debug_bus_state(debug_bus_state), .refresh_count(refresh_count),
        .dma_side_effect_count(dma_side_effect_count),
        .device_side_effect_count(device_side_effect_count),
        .protocol_error(protocol_error)
    );

    initial begin : run
        integer cycles;
        integer max_cycles;
        if (!$value$plusargs("MAX_CYCLES=%d", max_cycles))
            max_cycles = 2000000;

        repeat (8) @(posedge clk);
        reset = 1'b0;
        for (cycles = 0; cycles < max_cycles; cycles = cycles + 1) begin
            @(negedge clk);
            if (cpu_fault || protocol_error)
                $fatal(1, "AT_SYSTEM_FAULT cycle=%0d cs_ip=%04h:%04h opcode=%02h owner=%0d bridge_idle=%b fault=%b",
                       cycles, debug_cs, debug_ip, debug_opcode, bus_owner,
                       bridge_idle, cpu_fault);
            if (port81_writes != 0)
                $fatal(1, "AT_SYSTEM_DIAGNOSTIC_FAILURE cycle=%0d port81=%0d cs_ip=%04h:%04h",
                       cycles, port81_writes, debug_cs, debug_ip);
            if (cpu_shutdown)
                $fatal(1, "AT_SYSTEM_SHUTDOWN cycle=%0d cs_ip=%04h:%04h",
                       cycles, debug_cs, debug_ip);
            if (port80_writes >= 4 &&
                port80_sequence[0] == 8'h70 &&
                port80_sequence[1] == 8'h72 &&
                port80_sequence[2] == 8'h71 &&
                port80_sequence[3] == 8'h86 &&
                saw_native_reset_fetch && saw_low_rom_fetch &&
                irq0_edges != 0 && refresh_beats != 0) begin
                $display("AT_SYSTEM_BOUNDARY_PASS memory_beats=%0d io_writes=%0d irq0=%0d refresh=%0d port80=%0d",
                         accepted_memory_beats, accepted_io_writes,
                         irq0_edges, refresh_beats, port80_writes);
                $finish;
            end
        end
        $fatal(1, "AT_SYSTEM_WATCHDOG reset_fetch=%b low_rom=%b port80=%0d irq0=%0d refresh=%0d memory=%0d halted=%b intr=%b bus_valid=%b status=%h address=%06h cs_ip=%04h:%04h seq=%02h,%02h,%02h,%02h",
               saw_native_reset_fetch, saw_low_rom_fetch, port80_writes,
               irq0_edges, refresh_beats, accepted_memory_beats, cpu_halted,
               intr, cpu_bus_valid, cpu_bus_status, cpu_address, debug_cs,
               debug_ip, port80_sequence[0], port80_sequence[1],
               port80_sequence[2], port80_sequence[3]);
    end
endmodule
