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
    input  logic         execute_enable,
    input  logic         counter_clock,
    input  logic         refresh_enable,

    input  logic         keyboard_byte_valid,
    input  logic [7:0]   keyboard_byte,
    input  logic         periodic_tick,
    input  logic         second_tick,
    input  logic         parity_event,
    input  logic         channel_check_event,
    input  logic         external_nmi_event,

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

    output logic [3:0]   selected_device,
    output logic         unmapped_request,
    output logic         ata_selected,
    output logic         floppy_selected,
    output logic         video_io_selected,
    output logic         video_memory_selected,

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
    output logic [7:0]   debug_event_vector,
    output logic [7:0]   debug_opcode,
    output logic [15:0]  debug_cs,
    output logic [15:0]  debug_ip,
    output logic [3:0]   debug_bus_state,
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

    logic        rom_write_sink_active_q;
    logic        rom_write_sink_accept;
    logic        rom_write_sink_ready;

    logic        dma_memory_accept_q;
    logic        nmi_source_active_q;

    logic        a5_io_candidate;
    logic        pic_io_candidate;
    logic        pit_io_candidate;
    logic        dma_io_candidate;
    logic        io_known_target;
    logic        io_unmapped_candidate;
    logic        cpu_owner_active;
    logic        cpu_memory_candidate;
    logic        device_request_candidate;

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
                          dma_io_candidate || a5_io_candidate;
        io_unmapped_candidate = cpu_owner_active && at_io &&
                                !io_known_target;
        cpu_memory_candidate = cpu_owner_active && !at_io && !at_inta &&
                               memory_cycle && !video_aperture_select &&
                               !rom_write_blocked;
        device_request_candidate = cpu_owner_active &&
                                   (a5_io_candidate ||
                                    video_aperture_select);
    end

    spk286_machine_cpu u_cpu (
        .clk                    (clk),
        .reset                  (reset),
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
        .reset                  (reset),
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
        .keyboard_output_valid  (keyboard_output_valid),
        .keyboard_output_byte   (keyboard_output_byte),
        .irq1                   (),
        .a20_enable             (a20_enable),
        .cpu_reset_request      (cpu_reset_request),
        .periodic_tick          (periodic_tick),
        .second_tick            (second_tick),
        .irq8                   (irq8),
        .nmi_mask               (nmi_mask),
        .dma_transfer_valid     (dma_transfer_valid),
        .dma_transfer_complete  (dma_transfer_complete),
        .dma_terminal_count     (dma_terminal_count),
        .dma_active_channel     (dma_active_channel),
        .dma_transfer_accept    (devices_dma_transfer_accept),
        .dma_transfer_ready     (devices_dma_transfer_ready),
        .dma_transfer_data_out  (devices_dma_transfer_data_out),
        .dma_request            (devices_dma_request),
        .irq6                   (irq6),
        .irq14                  (irq14),
        .ata_selected           (ata_selected),
        .floppy_selected        (floppy_selected),
        .video_io_selected      (video_io_selected),
        .video_memory_selected  (video_memory_selected),
        .side_effect_count      (device_side_effect_count),
        .irq_request             (devices_irq_request),
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

    spk286_at_pit u_pit (
        .clk                    (clk),
        .reset                  (reset),
        .counter_clock          (counter_clock),
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

    // A blocked ROM write is a completed no-op.  It is kept separate from
    // the unmapped-I/O sink so the memory policy remains visible in traces.
    always_ff @(posedge clk) begin
        if (reset) begin
            io_sink_active_q <= 1'b0;
            io_sink_read_q <= 1'b0;
            io_sink_lane_q <= 2'b00;
            rom_write_sink_active_q <= 1'b0;
            dma_memory_accept_q <= 1'b0;
            nmi_source_active_q <= 1'b0;
            nmi <= 1'b0;
        end else begin
            if (io_sink_active_q)
                io_sink_active_q <= 1'b0;
            if (rom_write_sink_active_q)
                rom_write_sink_active_q <= 1'b0;

            if (io_sink_accept) begin
                io_sink_active_q <= 1'b1;
                io_sink_read_q <= !at_write;
                io_sink_lane_q <= at_byte_enable;
            end
            if (rom_write_sink_accept)
                rom_write_sink_active_q <= 1'b1;

            if (!dma_transfer_valid)
                dma_memory_accept_q <= 1'b0;
            else if (dma_memory_accept)
                dma_memory_accept_q <= 1'b1;

            nmi <= (parity_event || channel_check_event || external_nmi_event) &&
                   !nmi_source_active_q && !nmi_mask;
            nmi_source_active_q <= parity_event || channel_check_event ||
                                   external_nmi_event;
        end
    end

    always_comb begin
        at_accept = (memory_command_valid && memory_accept) ||
                    rom_write_sink_accept ||
                    devices_request_accept || pic_request_accept ||
                    pit_request_accept || dma_config_accept ||
                    io_sink_accept;

        at_ready = (memory_request_valid && memory_ready) ||
                   rom_write_sink_ready || devices_request_ready ||
                   pic_request_ready || pit_request_ready ||
                   dma_config_ready || io_sink_ready;

        at_read_data = 16'h0000;
        at_read_data_valid = 1'b0;
        if (memory_request_valid && memory_ready &&
            memory_read_data_valid) begin
            at_read_data = memory_read_data;
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
        end else if (io_sink_ready && io_sink_read_data_valid) begin
            at_read_data = io_sink_read_data;
            at_read_data_valid = 1'b1;
        end
    end

    assign cpu_fault = spk_shutdown | spk_control_error |
                       spk_unsupported_opcode | spk_microcode_fault |
                       spk_operand_blocked | bridge_protocol_error |
                       arbiter_protocol_error | pic_protocol_error |
                       pit_protocol_error | dma_protocol_error |
                       refresh_protocol_error | devices_protocol_error;

    assign protocol_error = cpu_fault;
endmodule
