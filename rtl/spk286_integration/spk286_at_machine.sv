// Composed AT machine boundary for the SPK286 integration.
//
// This module is intentionally a profile boundary rather than a replacement
// for the active XT-derived MiSTer top level.  It composes the CPU wrapper,
// AT bridge, memory decode, ownership arbiter and AT devices behind explicit
// memory/refresh interfaces.  A later MiSTer profile can attach those ports
// to the SDRAM/HPS/media/video owners without changing the CPU contract.
`timescale 1ns/1ps

module spk286_at_machine (
    input  logic         clk,
    input  logic         reset,
    // CPU-local reset.  The AT splash holds the 286/BIU in reset while the
    // device router and EGA raster remain alive to render the splash itself.
    input  logic         cpu_reset,
    input  logic         clk_video,
    input  logic         splashscreen,
    input  logic         execute_enable,
    input  logic         counter_clock,
    input  logic         refresh_enable,

    input  logic         keyboard_byte_valid,
    input  logic [7:0]   keyboard_byte,
    output logic         keyboard_byte_ready,
    output logic         keyboard_translate_set1,
    input  logic         periodic_tick,
    input  logic         second_tick,
    input  logic         parity_event,
    input  logic         channel_check_event,
    input  logic         external_nmi_event,

    // MiSTer hps_ext management for RTC/CMOS and the shared floppy controller.
    input  logic [15:0]  mgmt_address,
    input  logic [15:0]  mgmt_writedata,
    input  logic         mgmt_write,
    input  logic         mgmt_read,
    output logic [15:0]  mgmt_readdata,
    input  logic [1:0]   use_mmc,
    input  logic [1:0]   floppy_write_protect,
    output logic [1:0]   floppy_present,
    output logic [1:0]   floppy_request,
    output logic [2:0]   ide_request,

    // CPU memory/code-fetch target.  The request metadata is retained by the
    // bridge and remains stable from command through READY.
    output logic         memory_request_valid,
    output logic         memory_command_valid,
    output logic         memory_write,
    output logic         memory_code_fetch,
    output logic [3:0]   memory_cycle_class,
    output logic [23:0]  memory_address,
    output logic [1:0]   memory_byte_enable,
    output logic [15:0]  memory_data_out,
    input  logic         memory_accept,
    input  logic         memory_ready,
    input  logic [15:0]  memory_read_data,
    input  logic         memory_read_data_valid,

    // DMA memory side.  The device endpoint is internal to this boundary;
    // this port is the motherboard memory endpoint for one DMA beat.
    output logic         dma_memory_valid,
    output logic         dma_memory_write,
    output logic         dma_memory_read,
    output logic [23:0]  dma_memory_address,
    output logic [1:0]   dma_memory_byte_enable,
    output logic [15:0]  dma_memory_data_out,
    input  logic         dma_memory_accept,
    input  logic         dma_memory_ready,
    input  logic [15:0]  dma_memory_data_in,

    // Refresh memory side.  Refresh is a separate arbiter owner and does not
    // return architectural data to the CPU.
    output logic         refresh_memory_valid,
    output logic [23:0]  refresh_memory_address,
    input  logic         refresh_memory_accept,
    input  logic         refresh_memory_ready,

    output logic         keyboard_output_valid,
    output logic [7:0]   keyboard_output_byte,
    output logic         a20_enable,
    output logic         cpu_reset_request,
    output logic         intr,
    output logic         nmi,
    output logic [15:0]  irq_request,
    output logic         nmi_mask,
    output logic         speaker_active,
    output logic         speaker_level,

    output logic [3:0]   selected_device,
    output logic         unmapped_request,
    output logic         ata_selected,
    output logic         floppy_selected,
    output logic         video_io_selected,
    output logic         video_memory_selected,
    output logic [5:0]   video_red,
    output logic [5:0]   video_green,
    output logic [5:0]   video_blue,
    output logic         video_hsync,
    output logic         video_hblank,
    output logic         video_dbl_hsync,
    output logic         video_vsync,
    output logic         video_vblank,
    output logic         video_vblank_border,
    output logic         video_de,
    output logic         video_dot_toggle,
    output logic         video_scandouble_active,
    output logic         video_vmode_toggle,
    output logic         video_mode350,
    output logic [11:0]  video_active_dots,
    output logic [9:0]   video_active_lines,

    output logic         cpu_hold_request,
    output logic         cpu_hlda,
    output logic         bus_owner_valid,
    output logic [2:0]   bus_owner,
    output logic         dma_grant,
    output logic         refresh_grant,
    output logic         bridge_idle,
    output logic         cpu_ready,

    output logic [23:0]  cpu_address,
    output logic [15:0]  cpu_data_out,
    output logic [15:0]  cpu_data_in,
    output logic         cpu_data_oe,
    output logic         cpu_bus_valid,
    output logic         cpu_bus_write,
    output logic         cpu_bus_bhe_n,
    output logic [3:0]   cpu_bus_status,
    output logic         cpu_bus_lock,
    output logic         cpu_halted,
    output logic         cpu_shutdown,
    output logic         cpu_fault,
    output wire [15:0]   debug_fault_sources,
    output logic         debug_control_error,
    output logic         debug_unsupported_opcode,
    output logic         debug_microcode_fault,
    output logic         debug_operand_blocked,
    output logic         debug_event_completed,
    output logic [7:0]   debug_event_vector,
    output logic [7:0]   debug_opcode,
    output logic [15:0]  debug_cs,
    output logic [15:0]  debug_ip,
    output logic [3:0]   debug_bus_state,
    output logic [2:0]   debug_event_kind,
    output logic [23:0]  debug_cs_base,
    output logic [15:0]  debug_flags,
    output logic [127:0] debug_gpr,
    output logic [63:0]  debug_segment_selectors,
    output logic         debug_instruction_retired,
    output logic [15:0]  debug_instruction_ip,
    output logic [95:0]  debug_segment_bases,
    output logic         debug_fetch_blocked,
    output logic [16:0]  debug_fetch_cursor,
    output logic [11:0]  debug_micro_pc,
    output logic [11:0]  debug_micro_entry,
    output logic [7:0]   debug_micro_instruction,
    output logic         debug_micro_active,
    output logic [3:0]   debug_prefetch_count,
    output logic [7:0]   debug_biu_detail,
    output logic [7:0]   debug_last_post,
    output logic [15:0]  debug_cpu_cycle_count,
    output logic [15:0]  debug_at_cycle_count,
    output logic [31:0]  debug_trace0,
    output logic [31:0]  debug_trace1,
    output logic [31:0]  debug_trace2,
    output logic [31:0]  debug_trace3,
    output logic [7:0]   debug_keyboard_keycode,
    output logic         debug_keyboard_irq,
    output logic [7:0]   debug_keyboard_port_b,
    output logic         debug_keyboard_pic_int,
    output logic [3:0]   debug_dma_request,
    output logic [3:0]   debug_dma_acknowledge_n,
    output logic [19:0]  debug_at_address,
    output logic [7:0]   debug_at_data_out,
    output logic [7:0]   debug_at_data_in,
    output logic [2:0]   debug_at_status,
    output logic         debug_at_valid,
    output logic         debug_at_write,
    output logic         debug_at_io,
    output logic         debug_at_inta,
    output logic         debug_at_code,
    output logic         debug_at_byte_high,
    output logic         debug_at_memory_projection,
    output logic         debug_at_cycle_active,
    output logic         debug_at_ready,
    output logic [15:0]  refresh_count,
    output logic [15:0]  dma_side_effect_count,
    output logic [15:0]  device_side_effect_count,
    output logic         protocol_error
);
    localparam logic [3:0] CYCLE_INTA = 4'h0;

    logic [15:0] cpu_data_in_i;
    logic        cpu_ready_i;
    logic        cpu_hlda_i;
    logic        spk_halted;
    logic        spk_shutdown;
    logic        spk_control_error;
    logic        spk_unsupported_opcode;
    logic        spk_microcode_fault;
    logic        spk_operand_blocked;
    logic        spk_event_completed;
    logic [2:0]  spk_debug_event_kind;
    logic [23:0] spk_debug_cs_base;
    logic [15:0] spk_debug_flags;
    logic [127:0] spk_debug_gpr;
    logic [63:0] spk_debug_segment_selectors;
    logic        spk_fetch_blocked;
    logic [16:0] spk_debug_fetch_cursor;
    logic [11:0] spk_debug_micro_pc;
    logic [11:0] spk_debug_micro_entry;
    logic [7:0]  spk_debug_micro_instruction;
    logic        spk_debug_micro_active;
    logic [3:0]  spk_debug_prefetch_count;
    logic [7:0]  spk_debug_biu_detail;

    logic        at_valid;
    logic        at_command_valid;
    logic [2:0]  at_owner;
    logic [3:0]  at_cycle_class;
    logic [23:0] at_address;
    logic        at_a0;
    logic        at_bhe_n;
    logic [1:0]  at_byte_enable;
    logic [15:0] at_data_out;
    logic        at_data_oe;
    logic        at_write;
    logic        at_io;
    logic        at_inta;
    logic        at_code_fetch;
    logic        at_lock;
    logic        at_accepted;
    logic        at_completed;
    logic        at_response_valid;
    logic        at_accept;
    logic        at_ready;
    logic [15:0] at_read_data;
    logic        at_read_data_valid;
    logic        bridge_protocol_error;

    logic        memory_cycle;
    logic        conventional_ram_select;
    logic        video_aperture_select;
    logic        option_region_select;
    logic        system_bios_select;
    logic        extended_ram_select;
    logic        memory_write_allowed;
    logic        rom_write_blocked;
    logic        memory_unmapped_request;

    logic        cpu_grant;
    logic        external_grant;
    logic        loader_grant;
    logic        arbiter_protocol_error;
    logic        dma_bus_request;
    logic        dma_transfer_valid;
    logic [2:0]  dma_active_channel;
    logic [23:0] dma_transfer_address;
    logic [1:0]  dma_transfer_byte_enable;
    logic        dma_transfer_write_to_memory;
    logic        dma_transfer_read_from_memory;
    logic        dma_transfer_io_to_memory;
    logic        dma_transfer_memory_to_io;
    logic [15:0] dma_transfer_data_out;
    logic        dma_transfer_complete;
    logic        dma_terminal_count;
    logic [7:0]  dma_request_state;
    logic [7:0]  dma_acknowledge;
    logic        dma_cascade_request;
    logic        dma_protocol_error;

    logic        refresh_request;
    logic        refresh_bus_valid;
    logic [23:0] refresh_address;
    logic        refresh_complete;
    logic        refresh_protocol_error;

    logic sys_request_accept, sys_request_ready, sys_read_valid;
    logic [15:0] sys_read_data;
    logic [7:0] sys_port_b;
    logic timer_2_gate, speaker_enable, system_check_pending, sys_protocol_error;
    logic        pit_request_accept;
    logic        pit_request_ready;
    logic [15:0] pit_read_data;
    logic        pit_read_data_valid;
    logic        irq0;
    logic [2:0]  pit_counter_out;
    logic        pit_protocol_error;

    logic        pic_request_accept;
    logic        pic_request_ready;
    logic [15:0] pic_read_data;
    logic        pic_read_data_valid;
    logic        pic_slave_intr;
    logic        pic_inta_sequence_active;
    logic        pic_inta_first_active;
    logic        pic_inta_second_active;
    logic        pic_protocol_error;

    logic        devices_request_accept;
    logic        devices_request_ready;
    logic [15:0] devices_read_data;
    logic        devices_read_data_valid;
    logic        devices_unmapped_request;
    logic        devices_dma_transfer_accept;
    logic        devices_dma_transfer_ready;
    logic [15:0] devices_dma_transfer_data_out;
    logic [7:0]  devices_dma_request;
    logic        devices_cpu_reset_request;
    logic        irq6;
    logic        irq8;
    logic        irq14;
    logic [15:0] devices_irq_request;
    logic        devices_protocol_error;

    logic        dma_config_accept;
    logic        dma_config_ready;
    logic [15:0] dma_config_read_data;
    logic        dma_config_read_data_valid;

    logic        io_sink_active_q;
    logic        io_sink_read_q;
    logic [1:0]  io_sink_lane_q;
    logic        io_sink_accept;
    logic        io_sink_ready;
    logic [15:0] io_sink_read_data;
    logic        io_sink_read_data_valid;

    logic        memory_sink_active_q;
    logic        memory_sink_read_q;
    logic [1:0]  memory_sink_lane_q;
    logic        memory_sink_accept;
    logic        memory_sink_ready;
    logic [15:0] memory_sink_read_data;
    logic        memory_sink_read_data_valid;

    logic        rom_write_sink_active_q;
    logic        rom_write_sink_accept;
    logic        rom_write_sink_ready;

    logic        dma_memory_accept_q;
    logic        nmi_source_active_q;

    logic [15:0] debug_cpu_cycle_count_q;
    wire [3:0] device_fault_sources;
    logic [15:0] debug_at_cycle_count_q;
    logic [31:0] debug_trace0_q;
    logic [31:0] debug_trace1_q;
    logic [31:0] debug_trace2_q;
    logic [31:0] debug_trace3_q;
    logic [7:0]  debug_last_post_q;

    logic        a5_io_candidate;
    logic        pic_io_candidate;
    logic        pit_io_candidate;
    logic        dma_io_candidate;
    logic        io_known_target;
    logic        io_unmapped_candidate;
    logic        memory_unmapped_candidate;
    logic        cpu_owner_active;
    logic        cpu_memory_candidate;
    logic        device_request_candidate;

    // The 8042 reset is a CPU-local warm reset.  It must flush the CPU and
    // its retained bus transaction, but must not reset CMOS or the other AT
    // devices because the BIOS uses CMOS shutdown codes to resume POST.
    wire       cpu_core_reset = reset | cpu_reset | devices_cpu_reset_request;

    function automatic logic is_pic_port(input logic [15:0] port);
        begin
            is_pic_port = (port == 16'h0020) || (port == 16'h0021) ||
                          (port == 16'h00A0) || (port == 16'h00A1);
        end
    endfunction

    function automatic logic is_pit_port(input logic [15:0] port);
        begin
            is_pit_port = (port >= 16'h0040) && (port <= 16'h0043);
        end
    endfunction

    function automatic logic is_dma_port(input logic [15:0] port);
        begin
            is_dma_port = ((port >= 16'h0000) && (port <= 16'h000F)) ||
                          ((port >= 16'h0080) && (port <= 16'h008F)) ||
                          ((port >= 16'h00C0) && (port <= 16'h00DF));
        end
    endfunction

    function automatic logic is_a5_io_port(input logic [15:0] port);
        begin
            is_a5_io_port = (port == 16'h0060) || (port == 16'h0064) ||
                            (port == 16'h0070) || (port == 16'h0071) ||
                            ((port >= 16'h01F0) && (port <= 16'h01F7)) ||
                            // Forward XT-IDE before the unmapped-I/O FFh sink.
                            // 308h is the high-byte latch; 309h stays unmapped.
                            ((port >= 16'h0300) && (port <= 16'h030F) &&
                             (port != 16'h0309)) ||
                            ((port >= 16'h03B0) && (port <= 16'h03DF)) ||
                            ((port >= 16'h03F0) && (port <= 16'h03F7));
        end
    endfunction

    assign cpu_owner_active = cpu_grant && at_valid;

    always_comb begin
        pic_io_candidate = at_io && is_pic_port(at_address[15:0]);
        pit_io_candidate = at_io && is_pit_port(at_address[15:0]);
        dma_io_candidate = at_io && is_dma_port(at_address[15:0]);
        a5_io_candidate = at_io && is_a5_io_port(at_address[15:0]);
        io_known_target = at_inta || pic_io_candidate || pit_io_candidate ||
                          dma_io_candidate || a5_io_candidate || (at_io && at_address[15:0]==16'h61);
        io_unmapped_candidate = cpu_owner_active && at_io &&
                                !io_known_target;
        memory_unmapped_candidate = cpu_owner_active && !at_io && !at_inta &&
                                    memory_unmapped_request;
        cpu_memory_candidate = cpu_owner_active && !at_io && !at_inta &&
                               memory_cycle && !video_aperture_select &&
                               !rom_write_blocked;
        device_request_candidate = cpu_owner_active &&
                                   (a5_io_candidate ||
                                    video_aperture_select);
    end

    spk286_machine_cpu u_cpu (
        .clk                    (clk),
        .reset                  (cpu_core_reset),
        .execute_enable         (execute_enable),
        .ready                  (cpu_ready_i),
        .data_in                (cpu_data_in_i),
        .intr                   (intr),
        .nmi                    (nmi),
        .hold_request           (cpu_hold_request),
        .address                (cpu_address),
        .data_out               (cpu_data_out),
        .data_oe                (cpu_data_oe),
        .bus_valid              (cpu_bus_valid),
        .bus_write              (cpu_bus_write),
        .bus_bhe_n              (cpu_bus_bhe_n),
        .bus_status             (cpu_bus_status),
        .bus_lock               (cpu_bus_lock),
        .hlda                   (cpu_hlda_i),
        .halted                 (spk_halted),
        .shutdown               (spk_shutdown),
        .control_error          (spk_control_error),
        .unsupported_opcode     (spk_unsupported_opcode),
        .microcode_fault        (spk_microcode_fault),
        .operand_blocked        (spk_operand_blocked),
        .event_completed        (spk_event_completed),
        .debug_event_vector     (debug_event_vector),
        .debug_event_kind       (spk_debug_event_kind),
        .debug_opcode           (debug_opcode),
        .debug_cs               (debug_cs),
        .debug_cs_base          (spk_debug_cs_base),
        .debug_ip                (debug_ip),
        .debug_flags             (spk_debug_flags),
        .debug_gpr               (spk_debug_gpr),
        .debug_segment_selectors (spk_debug_segment_selectors),
        .debug_instruction_retired(debug_instruction_retired),
        .debug_instruction_ip(debug_instruction_ip),
        .debug_segment_bases(debug_segment_bases),
        .fetch_blocked           (spk_fetch_blocked),
        .debug_fetch_cursor      (spk_debug_fetch_cursor),
        .debug_micro_pc          (spk_debug_micro_pc),
        .debug_micro_entry       (spk_debug_micro_entry),
        .debug_micro_instruction (spk_debug_micro_instruction),
        .debug_micro_active      (spk_debug_micro_active),
        .debug_prefetch_count    (spk_debug_prefetch_count),
        .debug_bus_state         (debug_bus_state),
        .debug_biu_detail        (spk_debug_biu_detail)
    );

    assign cpu_hlda = cpu_hlda_i;
    assign cpu_ready = cpu_ready_i;
    assign cpu_data_in = cpu_data_in_i;

    spk286_at_bus_bridge u_bridge (
        .clk                    (clk),
        .reset                  (cpu_core_reset),
        .cpu_bus_valid          (cpu_bus_valid),
        .cpu_address            (cpu_address),
        .cpu_data_out           (cpu_data_out),
        .cpu_data_oe            (cpu_data_oe),
        .cpu_bus_write          (cpu_bus_write),
        .cpu_bus_bhe_n          (cpu_bus_bhe_n),
        .cpu_bus_status         (cpu_bus_status),
        .cpu_bus_lock           (cpu_bus_lock),
        .cpu_ready              (cpu_ready_i),
        .cpu_data_in            (cpu_data_in_i),
        .at_valid               (at_valid),
        .at_command_valid       (at_command_valid),
        .at_owner               (at_owner),
        .at_cycle_class         (at_cycle_class),
        .at_address             (at_address),
        .at_a0                  (at_a0),
        .at_bhe_n               (at_bhe_n),
        .at_byte_enable         (at_byte_enable),
        .at_data_out            (at_data_out),
        .at_data_oe             (at_data_oe),
        .at_write               (at_write),
        .at_io                  (at_io),
        .at_inta                (at_inta),
        .at_code_fetch          (at_code_fetch),
        .at_lock                (at_lock),
        .at_accepted            (at_accepted),
        .at_completed           (at_completed),
        .at_response_valid      (at_response_valid),
        .at_accept              (at_accept),
        .at_ready               (at_ready),
        .at_read_data           (at_read_data),
        .at_read_data_valid     (at_read_data_valid),
        .bridge_idle            (bridge_idle),
        .protocol_error         (bridge_protocol_error)
    );

    spk286_at_memory_decode u_memory_decode (
        .request_valid          (cpu_owner_active),
        .request_write          (at_write),
        .cycle_class            (at_cycle_class),
        .address                (at_address),
        .memory_cycle           (memory_cycle),
        .conventional_ram_select(conventional_ram_select),
        .video_aperture_select  (video_aperture_select),
        .option_region_select   (option_region_select),
        .system_bios_select     (system_bios_select),
        .extended_ram_select    (extended_ram_select),
        .write_allowed          (memory_write_allowed),
        .rom_write_blocked      (rom_write_blocked),
        .unmapped_request       (memory_unmapped_request)
    );

    assign memory_request_valid = cpu_memory_candidate;
    assign memory_command_valid = cpu_memory_candidate && at_command_valid;
    assign memory_write = at_write;
    assign memory_code_fetch = at_code_fetch;
    assign memory_cycle_class = at_cycle_class;
    assign memory_address = at_address;
    assign memory_byte_enable = at_byte_enable;
    assign memory_data_out = at_data_out;

    assign rom_write_sink_accept = cpu_owner_active && at_command_valid &&
                                   rom_write_blocked && !rom_write_sink_active_q;
    assign rom_write_sink_ready = rom_write_sink_active_q;

    spk286_at_device_router u_devices (
        .clk                    (clk),
        .reset                  (reset),
        .clk_video              (clk_video),
        .splashscreen           (splashscreen),
        .request_valid          (device_request_candidate),
        .request_command_valid  (at_command_valid),
        .request_write          (at_write),
        .request_io             (at_io),
        .request_address        (at_address),
        .request_byte_enable    (at_byte_enable),
        .request_data_out       (at_data_out),
        .request_accept         (devices_request_accept),
        .request_ready          (devices_request_ready),
        .request_read_data      (devices_read_data),
        .request_read_data_valid(devices_read_data_valid),
        .selected_device        (selected_device),
        .unmapped_request       (devices_unmapped_request),
        .keyboard_byte_valid    (keyboard_byte_valid),
        .keyboard_byte          (keyboard_byte),
        .keyboard_byte_ready    (keyboard_byte_ready),
        .keyboard_translate_set1(keyboard_translate_set1),
        .keyboard_output_valid  (keyboard_output_valid),
        .keyboard_output_byte   (keyboard_output_byte),
        .irq1                   (),
        .a20_enable             (a20_enable),
        .cpu_reset_request      (devices_cpu_reset_request),
        .periodic_tick          (periodic_tick),
        .second_tick            (second_tick),
        .irq8                   (irq8),
        .nmi_mask               (nmi_mask),
        .dma_transfer_valid     (dma_transfer_valid),
        .dma_transfer_complete  (dma_transfer_complete),
        .dma_terminal_count     (dma_terminal_count),
        .dma_active_channel     (dma_active_channel),
        // DMA1 byte devices consume a normalized low-byte value. Select the
        // addressed SDRAM lane for memory-to-I/O transfers.
        .dma_transfer_data_in   ((dma_active_channel < 3'd4) &&
                                 dma_transfer_byte_enable[1] ?
                                 {8'h00, dma_memory_data_in[15:8]} :
                                 dma_memory_data_in),
        .dma_transfer_accept    (devices_dma_transfer_accept),
        .dma_transfer_ready     (devices_dma_transfer_ready),
        .dma_transfer_data_out  (devices_dma_transfer_data_out),
        .dma_request            (devices_dma_request),
        .mgmt_address           (mgmt_address),
        .mgmt_writedata         (mgmt_writedata),
        .mgmt_write             (mgmt_write),
        .mgmt_read              (mgmt_read),
        .mgmt_readdata          (mgmt_readdata),
        .floppy_write_protect   (floppy_write_protect),
        .floppy_present         (floppy_present),
        .floppy_request         (floppy_request),
        .use_mmc                (use_mmc),
        .ide_request            (ide_request),
        .irq6                   (irq6),
        .irq14                  (irq14),
        .ata_selected           (ata_selected),
        .floppy_selected        (floppy_selected),
        .video_io_selected      (video_io_selected),
        .video_memory_selected  (video_memory_selected),
        .video_red              (video_red),
        .video_green            (video_green),
        .video_blue             (video_blue),
        .video_hsync            (video_hsync),
        .video_hblank           (video_hblank),
        .video_dbl_hsync        (video_dbl_hsync),
        .video_vsync            (video_vsync),
        .video_vblank           (video_vblank),
        .video_vblank_border    (video_vblank_border),
        .video_de               (video_de),
        .video_dot_toggle       (video_dot_toggle),
        .video_scandouble_active(video_scandouble_active),
        .video_vmode_toggle     (video_vmode_toggle),
        .video_mode350          (video_mode350),
        .video_active_dots      (video_active_dots),
        .video_active_lines     (video_active_lines),
        .side_effect_count      (device_side_effect_count),
        .irq_request             (devices_irq_request),
        .debug_fault_sources     (device_fault_sources),
        .protocol_error          (devices_protocol_error)
    );

    // PIT IRQ0 is the only interrupt source not owned by the A5 device
    // router.  The remaining lines are already mapped by that router.
    assign irq_request = {devices_irq_request[15:1], irq0};

`ifdef AT_MACHINE_PIC_MODEL
        spk286_at_machine_pic_model u_pic (
`else
    spk286_at_pic u_pic (
`endif
        .clk                    (clk),
        .reset                  (reset),
        .request_valid          (cpu_owner_active && (at_io || at_inta)),
        .request_command_valid  (at_command_valid),
        .request_write          (at_write),
        .request_io             (at_io),
        .request_inta           (at_inta),
        .request_address        (at_address),
        .request_byte_enable    (at_byte_enable),
        .request_data_out       (at_data_out),
        .irq_request             (irq_request),
        .intr                   (intr),
        .slave_intr             (pic_slave_intr),
        .request_accept         (pic_request_accept),
        .request_ready          (pic_request_ready),
        .request_read_data      (pic_read_data),
        .request_read_data_valid(pic_read_data_valid),
        .inta_sequence_active   (pic_inta_sequence_active),
        .inta_first_active      (pic_inta_first_active),
        .inta_second_active     (pic_inta_second_active),
        .protocol_error         (pic_protocol_error)
    );

    spk286_at_system_control u_system_control (
        .clk(clk), .reset(reset),
        .request_valid(cpu_owner_active && at_io), .request_command_valid(at_command_valid),
        .request_write(at_write), .request_io(at_io), .request_address(at_address),
        .request_byte_enable(at_byte_enable), .request_data_out(at_data_out),
        .request_accept(sys_request_accept), .request_ready(sys_request_ready),
        .request_read_data(sys_read_data), .request_read_data_valid(sys_read_valid),
        .timer_1_out(pit_counter_out[1]), .timer_2_out(pit_counter_out[2]),
        .parity_event(parity_event), .channel_check_event(channel_check_event),
        .timer_2_gate(timer_2_gate), .speaker_enable(speaker_enable),
        .check_pending(system_check_pending),
        .port_b(sys_port_b), .protocol_error(sys_protocol_error)
    );
    spk286_at_pit u_pit (
        .clk                    (clk),
        .reset                  (reset),
        .counter_clock          (counter_clock),
        .counter_2_gate         (timer_2_gate),
        .request_valid          (cpu_owner_active && at_io),
        .request_command_valid  (at_command_valid),
        .request_write          (at_write),
        .request_io             (at_io),
        .request_address        (at_address),
        .request_byte_enable    (at_byte_enable),
        .request_data_out       (at_data_out),
        .request_accept         (pit_request_accept),
        .request_ready          (pit_request_ready),
        .request_read_data      (pit_read_data),
        .request_read_data_valid(pit_read_data_valid),
        .irq0                   (irq0),
        .counter_out            (pit_counter_out),
        .protocol_error         (pit_protocol_error)
    );

    spk286_at_dma u_dma (
        .clk                    (clk),
        .reset                  (reset),
        .request_valid          (cpu_owner_active && at_io),
        .request_command_valid  (at_command_valid),
        .request_write          (at_write),
        .request_io             (at_io),
        .request_address        (at_address),
        .request_byte_enable    (at_byte_enable),
        .request_data_out       (at_data_out),
        .request_accept         (dma_config_accept),
        .request_ready          (dma_config_ready),
        .request_read_data      (dma_config_read_data),
        .request_read_data_valid(dma_config_read_data_valid),
        .dma_request             (devices_dma_request),
        .dma_grant               (dma_grant),
        .transfer_accept         (devices_dma_transfer_accept),
        .transfer_ready          (devices_dma_transfer_ready &&
                                  dma_memory_ready &&
                                  (dma_memory_accept || dma_memory_accept_q)),
        .transfer_data_in        (dma_transfer_read_from_memory ?
                                  dma_memory_data_in :
                                  devices_dma_transfer_data_out),
        .dma_bus_request         (dma_bus_request),
        .dma_transfer_valid      (dma_transfer_valid),
        .dma_active_channel      (dma_active_channel),
        .dma_transfer_address    (dma_transfer_address),
        .dma_transfer_byte_enable(dma_transfer_byte_enable),
        .dma_transfer_write_to_memory(dma_transfer_write_to_memory),
        .dma_transfer_read_from_memory(dma_transfer_read_from_memory),
        .dma_transfer_io_to_memory(dma_transfer_io_to_memory),
        .dma_transfer_memory_to_io(dma_transfer_memory_to_io),
        .dma_transfer_data_out   (dma_transfer_data_out),
        .dma_transfer_complete   (dma_transfer_complete),
        .dma_terminal_count      (dma_terminal_count),
        .dma_request_state       (dma_request_state),
        .dma_acknowledge         (dma_acknowledge),
        .cascade_request         (dma_cascade_request),
        .protocol_error          (dma_protocol_error)
    );

    assign dma_memory_valid = dma_transfer_valid;
    assign dma_memory_write = dma_transfer_write_to_memory;
    assign dma_memory_read = dma_transfer_read_from_memory;
    assign dma_memory_address = dma_transfer_address;
    assign dma_memory_byte_enable = dma_transfer_byte_enable;
    assign dma_memory_data_out = dma_transfer_data_out;

    assign cpu_reset_request = devices_cpu_reset_request;

    // Minimal IBM AT PC speaker path.  The speaker only produces a waveform
    // when both port 61h's speaker-enable and GATE2 are asserted; PIT channel
    // 2 supplies the square-wave level.  Audio conversion remains at the
    // profile boundary, so the machine still exposes the native logic level.
    assign speaker_active = speaker_enable && timer_2_gate;
    assign speaker_level  = speaker_active && pit_counter_out[2];

    spk286_at_refresh u_refresh (
        .clk                    (clk),
        .reset                  (reset),
        .refresh_enable         (refresh_enable),
        .refresh_grant          (refresh_grant),
        .refresh_accept         (refresh_memory_accept &&
                                 refresh_memory_valid),
        .refresh_ready          (refresh_memory_ready &&
                                 refresh_memory_valid),
        .refresh_request        (refresh_request),
        .refresh_bus_valid      (refresh_bus_valid),
        .refresh_address        (refresh_address),
        .refresh_complete      (refresh_complete),
        .refresh_count          (refresh_count),
        .protocol_error         (refresh_protocol_error)
    );

    assign refresh_memory_valid = refresh_bus_valid && refresh_grant;
    assign refresh_memory_address = refresh_address;

    // The overlay consumes a compact, source-domain snapshot.  Keep the
    // architectural CPU state and the normalized AT transaction visible at
    // the profile boundary instead of reaching through this wrapper from the
    // MiSTer top level.
    assign debug_event_kind        = spk_debug_event_kind;
    assign cpu_halted              = spk_halted;
    assign cpu_shutdown            = spk_shutdown;
    assign debug_control_error     = spk_control_error;
    assign debug_unsupported_opcode = spk_unsupported_opcode;
    assign debug_microcode_fault   = spk_microcode_fault;
    assign debug_operand_blocked   = spk_operand_blocked;
    assign debug_event_completed   = spk_event_completed;
    assign debug_cs_base           = spk_debug_cs_base;
    assign debug_flags             = spk_debug_flags;
    assign debug_gpr               = spk_debug_gpr;
    assign debug_segment_selectors = spk_debug_segment_selectors;
    assign debug_fetch_blocked     = spk_fetch_blocked;
    assign debug_fetch_cursor      = spk_debug_fetch_cursor;
    assign debug_micro_pc          = spk_debug_micro_pc;
    assign debug_micro_entry       = spk_debug_micro_entry;
    assign debug_micro_instruction = spk_debug_micro_instruction;
    assign debug_micro_active      = spk_debug_micro_active;
    assign debug_prefetch_count    = spk_debug_prefetch_count;
    assign debug_biu_detail        = spk_debug_biu_detail;
    // Port 80h is a write-only diagnostic port on a conventional AT.  Keep
    // this observer separate from the CPU event vector: the latter is shown
    // as EVT on the overlay and must not masquerade as a BIOS POST code.
    assign debug_last_post         = debug_last_post_q;
    assign debug_cpu_cycle_count   = debug_cpu_cycle_count_q;
    assign debug_at_cycle_count    = debug_at_cycle_count_q;
    assign debug_trace0            = debug_trace0_q;
    assign debug_trace1            = debug_trace1_q;
    assign debug_trace2            = debug_trace2_q;
    assign debug_trace3            = debug_trace3_q;
    assign debug_keyboard_keycode  = keyboard_byte;
    assign debug_keyboard_irq      = keyboard_byte_valid;
    assign debug_keyboard_port_b   = sys_port_b;
    assign debug_keyboard_pic_int  = intr;
    assign debug_dma_request       = devices_dma_request[3:0];
    assign debug_dma_acknowledge_n = 4'hF;

    assign debug_at_address        = at_address[19:0];
    assign debug_at_data_out       = at_byte_enable[1] ?
                                     at_data_out[15:8] : at_data_out[7:0];
    assign debug_at_data_in        = at_byte_enable[1] ?
                                     at_read_data[15:8] : at_read_data[7:0];
    assign debug_at_status         = at_cycle_class[2:0];
    assign debug_at_valid          = at_valid;
    assign debug_at_write          = at_write;
    assign debug_at_io             = at_io;
    assign debug_at_inta           = at_inta;
    assign debug_at_code           = at_code_fetch;
    assign debug_at_byte_high      = at_byte_enable[1];
    assign debug_at_memory_projection = conventional_ram_select |
                                        video_aperture_select |
                                        option_region_select |
                                        system_bios_select |
                                        extended_ram_select;
    assign debug_at_cycle_active   = at_valid;
    assign debug_at_ready         = at_ready;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            debug_cpu_cycle_count_q <= 16'h0000;
            debug_at_cycle_count_q  <= 16'h0000;
            debug_trace0_q          <= 32'h0000_0000;
            debug_trace1_q          <= 32'h0000_0000;
            debug_trace2_q          <= 32'h0000_0000;
            debug_trace3_q          <= 32'h0000_0000;
            debug_last_post_q       <= 8'h00;
        end else begin
            if (at_completed) begin
                debug_cpu_cycle_count_q <= debug_cpu_cycle_count_q + 16'd1;
                debug_trace3_q <= debug_trace2_q;
                debug_trace2_q <= debug_trace1_q;
                debug_trace1_q <= debug_trace0_q;
                debug_trace0_q <= {at_address[19:0],
                                   at_data_out[7:0],
                                   at_cycle_class[2:0], at_write};

                // Observe a completed byte write to the standard POST
                // diagnostic port.  The normalized bridge presents the
                // active byte on the selected lane, including the second
                // beat of an aligned two-byte request.
                if (at_io && at_write &&
                    (at_address[15:0] == 16'h0080)) begin
                    debug_last_post_q <= at_byte_enable[1] ?
                                         at_data_out[15:8] :
                                         at_data_out[7:0];
                end
            end
            if (at_accepted)
                debug_at_cycle_count_q <= debug_at_cycle_count_q + 16'd1;
        end
    end

    spk286_at_arbiter u_arbiter (
        .clk                    (clk),
        .reset                  (reset),
        .cpu_hlda               (cpu_hlda_i),
        .cpu_bridge_idle        (bridge_idle),
        .cpu_lock               (at_lock),
        // The bridge retains an odd word as one locked logical request.  It
        // cannot be interrupted because bridge_idle is false until all byte
        // beats have completed; these two flags remain explicit tie-offs at
        // this normalized composition boundary.
        .cpu_odd_word_active    (1'b0),
        .cpu_inta_lock_chain    (1'b0),
        .cpu_response_pending   (at_valid),
        .dma_request            (dma_bus_request),
        .refresh_request        (refresh_request),
        .loader_request         (1'b0),
        .loader_reset_owner     (1'b0),
        .external_done          ((dma_grant && dma_transfer_complete) ||
                                 (refresh_grant && refresh_complete)),
        .cpu_hold_request       (cpu_hold_request),
        .cpu_grant              (cpu_grant),
        .external_grant         (external_grant),
        .bus_owner_valid        (bus_owner_valid),
        .bus_owner              (bus_owner),
        .dma_grant              (dma_grant),
        .refresh_grant          (refresh_grant),
        .loader_grant           (loader_grant),
        .protocol_error         (arbiter_protocol_error)
    );

    assign io_sink_accept = io_unmapped_candidate && at_command_valid &&
                            !io_sink_active_q;
    assign io_sink_ready = io_sink_active_q;
    assign io_sink_read_data = io_sink_lane_q[1] ? 16'hFF00 : 16'h00FF;
    assign io_sink_read_data_valid = io_sink_ready && io_sink_read_q;

    assign memory_sink_accept = memory_unmapped_candidate &&
                                at_command_valid && !memory_sink_active_q;
    assign memory_sink_ready = memory_sink_active_q;
    assign memory_sink_read_data = (memory_sink_lane_q == 2'b11) ?
                                   16'hFFFF :
                                   (memory_sink_lane_q[1] ?
                                    16'hFF00 : 16'h00FF);
    assign memory_sink_read_data_valid = memory_sink_ready &&
                                         memory_sink_read_q;

    assign unmapped_request = io_unmapped_candidate ||
                              memory_unmapped_candidate ||
                              devices_unmapped_request;

    // A blocked ROM write is a completed no-op.  It is kept separate from
    // the unmapped-I/O sink so the memory policy remains visible in traces.
    always_ff @(posedge clk) begin
        if (reset) begin
            io_sink_active_q <= 1'b0;
            io_sink_read_q <= 1'b0;
            io_sink_lane_q <= 2'b00;
            memory_sink_active_q <= 1'b0;
            memory_sink_read_q <= 1'b0;
            memory_sink_lane_q <= 2'b00;
            rom_write_sink_active_q <= 1'b0;
            dma_memory_accept_q <= 1'b0;
            nmi_source_active_q <= 1'b0;
            nmi <= 1'b0;
        end else begin
            if (io_sink_active_q)
                io_sink_active_q <= 1'b0;
            if (memory_sink_active_q)
                memory_sink_active_q <= 1'b0;
            if (rom_write_sink_active_q)
                rom_write_sink_active_q <= 1'b0;

            if (io_sink_accept) begin
                io_sink_active_q <= 1'b1;
                io_sink_read_q <= !at_write;
                io_sink_lane_q <= at_byte_enable;
            end
            if (memory_sink_accept) begin
                memory_sink_active_q <= 1'b1;
                memory_sink_read_q <= !at_write;
                memory_sink_lane_q <= at_byte_enable;
            end
            if (rom_write_sink_accept)
                rom_write_sink_active_q <= 1'b1;

            if (!dma_transfer_valid)
                dma_memory_accept_q <= 1'b0;
            else if (dma_memory_accept)
                dma_memory_accept_q <= 1'b1;

            nmi <= (system_check_pending || external_nmi_event) &&
                   !nmi_source_active_q && !nmi_mask;
            nmi_source_active_q <= (system_check_pending || external_nmi_event) && !nmi_mask;
        end
    end

    always_comb begin
        at_accept = (memory_command_valid && memory_accept) ||
                    memory_sink_accept ||
                    rom_write_sink_accept ||
                    devices_request_accept || pic_request_accept ||
                    pit_request_accept || dma_config_accept ||
                    sys_request_accept || io_sink_accept;

        at_ready = (memory_request_valid && memory_ready) ||
                   memory_sink_ready ||
                   rom_write_sink_ready || devices_request_ready ||
                   pic_request_ready || pit_request_ready ||
                   dma_config_ready || sys_request_ready || io_sink_ready;

        at_read_data = 16'h0000;
        at_read_data_valid = 1'b0;
        if (memory_request_valid && memory_ready &&
            memory_read_data_valid) begin
            at_read_data = memory_read_data;
            at_read_data_valid = 1'b1;
        end else if (memory_sink_ready && memory_sink_read_data_valid) begin
            at_read_data = memory_sink_read_data;
            at_read_data_valid = 1'b1;
        end else if (devices_request_ready && devices_read_data_valid) begin
            at_read_data = devices_read_data;
            at_read_data_valid = 1'b1;
        end else if (pic_request_ready && pic_read_data_valid) begin
            at_read_data = pic_read_data;
            at_read_data_valid = 1'b1;
        end else if (pit_request_ready && pit_read_data_valid) begin
            at_read_data = pit_read_data;
            at_read_data_valid = 1'b1;
        end else if (dma_config_ready && dma_config_read_data_valid) begin
            at_read_data = dma_config_read_data;
            at_read_data_valid = 1'b1;
        end else if (sys_request_ready && sys_read_valid) begin
            at_read_data = sys_read_data;
            at_read_data_valid = 1'b1;
        end else if (io_sink_ready && io_sink_read_data_valid) begin
            at_read_data = io_sink_read_data;
            at_read_data_valid = 1'b1;
        end
    end

    // Bits 0..4 CPU, 5 bridge, 6 arbiter, 7 PIC, 8 PIT, 9 DMA,
    // 10 refresh, 11 router, 12 keyboard, 13 RTC, 14 storage, 15 aggregate devices (including system control 61h).
    assign debug_fault_sources = {(devices_protocol_error | sys_protocol_error), device_fault_sources,
        refresh_protocol_error, dma_protocol_error, pit_protocol_error,
        pic_protocol_error, arbiter_protocol_error, bridge_protocol_error,
        spk_operand_blocked, spk_microcode_fault, spk_unsupported_opcode,
        spk_control_error, spk_shutdown};

    assign cpu_fault = spk_shutdown | spk_control_error |
                       spk_unsupported_opcode | spk_microcode_fault |
                       spk_operand_blocked | bridge_protocol_error |
                       arbiter_protocol_error | pic_protocol_error |
                       pit_protocol_error | dma_protocol_error |
                       refresh_protocol_error | devices_protocol_error | sys_protocol_error;

    assign protocol_error = cpu_fault;
endmodule
