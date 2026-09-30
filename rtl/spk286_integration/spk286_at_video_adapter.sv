// Real EGA device behind the normalized AT request boundary.
//
// The AT machine and its device router run at 50 MHz.  The EGA sequencer,
// CRTC and raster run from the 28.636 MHz clock produced by pll_system.  A
// small toggle mailbox carries one I/O transaction at a time across that
// boundary.  The request is held in the video domain long enough for
// ega_top's settled-bus qualifier, and the response returns with a matching
// toggle.  Video aperture accesses stay in the 50 MHz domain at the
// frontends; planar EGA VRAM and the packed VGA framebuffer are each shared
// with the raster through their own dual-port memories.
`timescale 1ns/1ps

module spk286_at_video_adapter (
    input  logic        clk,
    input  logic        reset,
    input  logic        video_reset_in,
    input  logic        prebios_video,
    input  logic        clk_video,
    input  logic        splashscreen,
    input  logic [1:0]  ega_monitor_profile,
    input  logic        vga_enabled,
    input  logic        vga_mode13_native,
    input  logic [3:0]  crt_h_offset,
    input  logic [2:0]  crt_v_offset,
    input  logic [2:0]  vsync_width_osd,
    input  logic [2:0]  hsync_width_osd,

    input  logic        request_valid,
    input  logic        request_command_valid,
    input  logic        request_write,
    input  logic        request_io,
    input  logic [23:0] request_address,
    input  logic [1:0]  request_byte_enable,
    input  logic [15:0] request_data_out,
    output logic        request_accept,
    output logic        request_ready,
    output logic [15:0] request_read_data,
    output logic        request_read_data_valid,

    output logic [5:0]  video_red,
    output logic [5:0]  video_green,
    output logic [5:0]  video_blue,
    output logic        video_hsync,
    output logic        video_hblank,
    output logic        video_dbl_hsync,
    output logic        video_vsync,
    output logic        video_vblank,
    output logic        video_vblank_border,
    output logic        video_de,
    output logic        video_dot_toggle,
    output logic        video_scandouble_active,
    output logic        video_vmode_toggle,
    output logic        video_mode350,
    output logic [11:0] video_active_dots,
    output logic [9:0]  video_active_lines
);

    // Release video-side state only on a video-clock edge. This reset is
    // independent of the machine reset so the default raster can keep MiSTer
    // video detection alive while firmware is missing.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic video_reset_sync1_q;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic video_reset_sync2_q;
    wire  video_reset = video_reset_sync2_q;

    always_ff @(posedge clk_video or posedge video_reset_in) begin
        if (video_reset_in) begin
            video_reset_sync1_q <= 1'b1;
            video_reset_sync2_q <= 1'b1;
        end else begin
            video_reset_sync1_q <= 1'b0;
            video_reset_sync2_q <= video_reset_sync1_q;
        end
    end

    // P05: the splash lifetime is generated at 50 MHz, but selects raster
    // state in the video domain. Only a synchronized level may reach EGA.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic splash_video_sync1_q;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic splash_video_sync2_q;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic prebios_video_sync1_q;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic prebios_video_sync2_q;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic vga_mode13_native_video_sync1_q;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic vga_mode13_native_video_sync2_q;
    always_ff @(posedge clk_video) begin
        if (video_reset) begin
            splash_video_sync1_q <= 1'b0;
            splash_video_sync2_q <= 1'b0;
            prebios_video_sync1_q <= 1'b0;
            prebios_video_sync2_q <= 1'b0;
            vga_mode13_native_video_sync1_q <= 1'b1;
            vga_mode13_native_video_sync2_q <= 1'b1;
        end else begin
            splash_video_sync1_q <= splashscreen;
            splash_video_sync2_q <= splash_video_sync1_q;
            prebios_video_sync1_q <= prebios_video;
            prebios_video_sync2_q <= prebios_video_sync1_q;
            vga_mode13_native_video_sync1_q <= vga_mode13_native;
            vga_mode13_native_video_sync2_q <= vga_mode13_native_video_sync1_q;
        end
    end

    // Transfer geometry and the applied physical monitor profile coherently.
    // The profile latch can change throughout machine reset (including the
    // splash, while this raster is live). Two independent bit synchronizers
    // cannot guarantee an atomic 01 <-> 10 change. Reuse the held mailbox;
    // it stays live across machine resets and stopped raster clocks.
    wire [15:0] video_geometry_source = {
        ega_monitor_profile, vga_enabled, hsync_width_osd, vsync_width_osd,
        crt_v_offset, crt_h_offset
    };
    logic [15:0] video_geometry_sent_q = 16'd0;
    wire video_geometry_ready;
    wire [15:0] video_geometry;
    always_ff @(posedge clk) begin
        if (video_geometry_ready && video_geometry_source != video_geometry_sent_q)
            video_geometry_sent_q <= video_geometry_source;
    end
    at_cdc_snapshot #(.WIDTH(16)) video_geometry_cdc (
        .src_clk   (clk),
        .src_send  (video_geometry_ready && video_geometry_source != video_geometry_sent_q),
        .src_data  (video_geometry_source),
        .src_ready (video_geometry_ready),
        .dst_clk   (clk_video),
        .dst_data  (video_geometry),
        .dst_update()
    );

    wire video_io_request = request_valid && request_command_valid &&
                            request_io &&
                            (request_address[15:0] >= 16'h03B0) &&
                            (request_address[15:0] <= 16'h03DF);
    wire video_memory_request = request_valid && request_command_valid &&
                                !request_io &&
                                (request_address[23:0] >= 24'h0A0000) &&
                                (request_address[23:0] <= 24'h0BFFFF);
    wire lane_valid = ((request_address[0] == 1'b0) &&
                       (request_byte_enable == 2'b01)) ||
                      ((request_address[0] == 1'b1) &&
                       (request_byte_enable == 2'b10));

    wire [7:0] request_byte = request_byte_enable[1] ?
                              request_data_out[15:8] : request_data_out[7:0];

    // Decode the CPU aperture before remapping offsets inside VRAM. Keep
    // these write-only register fields in the AT domain, updated by the
    // accepted I/O transaction (as for switch sense below). The mailbox
    // completes that OUT before allowing a following memory transaction, so
    // no asynchronous multi-bit GDC value enters the address decoder.
    logic [3:0] ega_gfx_index_host_q;
    logic [1:0] ega_mem_map_host_q;
    logic       ega_ram_enable_host_q;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic video_reset_at_sync1_q;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic video_reset_at_sync2_q;
    always_ff @(posedge clk or posedge video_reset_in) begin
        if (video_reset_in) begin
            video_reset_at_sync1_q <= 1'b1;
            video_reset_at_sync2_q <= 1'b1;
        end else begin
            video_reset_at_sync1_q <= 1'b0;
            video_reset_at_sync2_q <= video_reset_at_sync1_q;
        end
    end
    wire ega_aperture_hit = (ega_mem_map_host_q == 2'b00) ||
                           ((ega_mem_map_host_q == 2'b01) && !request_address[16]) ||
                           ((ega_mem_map_host_q == 2'b10) && request_address[16:15] == 2'b10) ||
                           ((ega_mem_map_host_q == 2'b11) && request_address[16:15] == 2'b11);
    // The optional VGA path retains its existing packed/planar selection.
    wire memory_selected = vga_enabled || (ega_ram_enable_host_q && ega_aperture_hit);

    // A CPU/machine-only reset leaves the live EGA registers intact. Only
    // video reset may restore these architectural decode fields to defaults.
    always_ff @(posedge clk) begin
        if (video_reset_at_sync2_q) begin
            ega_gfx_index_host_q <= 4'h0;
            ega_mem_map_host_q <= 2'b00;
            ega_ram_enable_host_q <= 1'b1; // ega_top reset Misc Output = 63h.
        end else if (!reset && request_accept && video_io_request && request_write) begin
            case (request_address[15:0])
                16'h03C2: ega_ram_enable_host_q <= request_byte[1];
                16'h03CE: ega_gfx_index_host_q <= request_byte[3:0];
                16'h03CF: if (ega_gfx_index_host_q == 4'h6)
                             ega_mem_map_host_q <= request_byte[3:2];
                default: begin end
            endcase
        end
    end

    // EGA Input Status Register 0 is read at 3C2h.  Its selector is the
    // value most recently written to Miscellaneous Output, so it must be
    // sampled in this ISA-clock domain rather than inferred from the posted
    // video-domain mailbox.  The shared decoder models the real EGA switch
    // sense pins used by the AT BIOS probe.
    wire ega_switch_request = request_valid && request_command_valid &&
                              request_io &&
                              ((request_address[15:0] == 16'h03C2) ||
                               (request_address[15:0] == 16'h02C2));
    wire [7:0] ega_switch_host_data;

    ega_switch_sense_host u_ega_switch_sense_host (
        .clock             (clk),
        .reset             (reset),
        .monitor_profile   (ega_monitor_profile),
        .io_address        (request_address[14:0]),
        .io_data           (request_byte),
        .io_write_n        (!(ega_switch_request && request_write)),
        .io_read_n         (!(ega_switch_request && !request_write)),
        .address_enable_n  (!ega_switch_request),
        .data_out          (ega_switch_host_data),
        .output_enable     ()
    );

    logic       io_busy_q;
    logic       io_write_q;
    logic       io_read_q;
    logic [14:0] io_address_q;
    logic [7:0] io_data_q;
    logic [1:0] io_byte_enable_q;
    logic       io_request_toggle_q;
    logic       io_ack_sync1_q;
    logic       io_ack_sync2_q;
    logic [7:0] io_read_data_sync1_q;
    logic [7:0] io_read_data_sync2_q;
    logic       io_switch_read_q;
    logic [7:0] io_switch_read_data_q;

    logic       memory_busy_q;
    logic       memory_write_q;
    logic       memory_read_q;
    logic       memory_selected_q;
    logic [15:0] memory_address_q;
    logic        memory_a16_q;
    logic [7:0]  memory_data_q;
    logic [1:0]  memory_byte_enable_q;
    logic [7:0]  memory_read_data;
    wire         vram_cpu_ready;
    wire         vga_framebuffer_cpu_ready;
    wire         memory_ready;

    wire io_idle = !io_busy_q;
    wire memory_idle = !memory_busy_q;
    wire io_complete = io_busy_q &&
                       (io_ack_sync2_q == io_request_toggle_q);
    wire memory_complete = memory_busy_q && memory_ready;

    assign request_accept = (video_io_request && io_idle && memory_idle &&
                             lane_valid) ||
                            (video_memory_request && io_idle && memory_idle);
    assign request_ready = io_complete || memory_complete;
    assign request_read_data = io_complete ?
                               (io_switch_read_q ?
                                (io_byte_enable_q[1] ?
                                 {io_switch_read_data_q, 8'h00} :
                                 {8'h00, io_switch_read_data_q}) :
                                (io_byte_enable_q[1] ?
                                 {io_read_data_sync2_q, 8'h00} :
                                 {8'h00, io_read_data_sync2_q})) :
                               (memory_byte_enable_q[1] ?
                                {memory_read_data, 8'h00} :
                                {8'h00, memory_read_data});
    assign request_read_data_valid = request_ready &&
                                     (io_complete ? io_read_q : memory_read_q);

    // The CPU-side transaction mailbox and the planar VRAM frontend.
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            io_busy_q <= 1'b0;
            io_write_q <= 1'b0;
            io_read_q <= 1'b0;
            io_address_q <= 15'h0000;
            io_data_q <= 8'h00;
            io_byte_enable_q <= 2'b00;
            io_request_toggle_q <= 1'b0;
            io_ack_sync1_q <= 1'b0;
            io_ack_sync2_q <= 1'b0;
            io_read_data_sync1_q <= 8'h00;
            io_read_data_sync2_q <= 8'h00;
            io_switch_read_q <= 1'b0;
            io_switch_read_data_q <= 8'h00;
            memory_busy_q <= 1'b0;
            memory_write_q <= 1'b0;
            memory_read_q <= 1'b0;
            memory_selected_q <= 1'b0;
            memory_address_q <= 16'h0000;
            memory_a16_q <= 1'b0;
            memory_data_q <= 8'h00;
            memory_byte_enable_q <= 2'b00;
        end else begin
            io_ack_sync1_q <= video_io_ack_toggle;
            io_ack_sync2_q <= io_ack_sync1_q;
            io_read_data_sync1_q <= video_io_read_data;
            io_read_data_sync2_q <= io_read_data_sync1_q;

            if (request_accept && video_io_request) begin
                io_busy_q <= 1'b1;
                io_write_q <= request_write;
                io_read_q <= !request_write;
                io_address_q <= request_address[14:0];
                io_data_q <= request_byte;
                io_byte_enable_q <= request_byte_enable;
                io_switch_read_q <= ega_switch_request && !request_write;
                io_switch_read_data_q <= ega_switch_host_data;
                io_request_toggle_q <= ~io_request_toggle_q;
            end else if (io_complete) begin
                io_busy_q <= 1'b0;
            end

            if (request_accept && video_memory_request) begin
                memory_busy_q <= 1'b1;
                memory_write_q <= request_write;
                memory_read_q <= !request_write;
                memory_selected_q <= memory_selected;
                memory_address_q <= request_address[15:0];
                memory_a16_q <= request_address[16];
                memory_data_q <= request_byte;
                memory_byte_enable_q <= request_byte_enable;
            end else if (memory_complete) begin
                memory_busy_q <= 1'b0;
            end
        end
    end

    wire [7:0] vram_cpu_dout;
    wire [7:0] vga_framebuffer_cpu_dout;
    wire [7:0] vram_plane0;
    wire [7:0] vram_plane1;
    wire [7:0] vram_plane2;
    wire [7:0] vram_plane3;
    wire        vram_video_valid;
    wire [7:0] vram_text_char;
    wire [7:0] vram_text_attr;
    wire [7:0] vram_text_glyph;
    wire        vram_text_valid;

    wire [15:0] ega_fetch_addr;
    wire        ega_fetch_en;
    wire [15:0] vga_framebuffer_addr;
    wire        vga_framebuffer_read_en;
    wire [7:0]  vga_framebuffer_pixel;
    wire        vga_framebuffer_data_valid;
    wire        vga_mode13_active_video;
    wire        vga_planar_memory_active_video;
    wire [15:0] ega_text_cell_addr;
    wire [15:0] ega_text_font_addr;
    wire        ega_text_fetch_en;

    wire        ega_cfg_toggle;
    wire [3:0]  ega_plane_write_mask;
    wire        ega_odd_even_mode;
    wire        ega_cpu_access_slot;
    wire        ega_chain2_write;
    wire        ega_chain2_read;
    wire        ega_extended_memory;
    wire [1:0]  ega_mem_map_sel;
    wire        ega_page_select;
    wire [1:0]  ega_write_mode;
    wire [1:0]  ega_read_mode;
    wire [1:0]  ega_read_plane_sel;
    wire [7:0]  ega_color_compare;
    wire [7:0]  ega_color_dont_care;
    wire [7:0]  ega_bit_mask;
    wire [7:0]  ega_set_reset;
    wire [3:0]  ega_enable_set_reset;
    wire [1:0]  ega_rop_select;
    wire [2:0]  ega_rotate_count;

    // Standard VGA mode 13h uses a packed 64 KiB A0000 framebuffer. Keep its
    // CPU aperture separate from the planar EGA VRAM, whose Chain-4 path is
    // intentionally handled by ega_vram_bram_frontend.
    // Register the decoded mode before crossing clocks: the planar/packed
    // decision depends on several graphics registers and must not propagate
    // combinational decode glitches into the CPU-domain synchronizer.
    logic vga_packed_memory_video_q;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON" *)
    logic vga_packed_memory_sync1_q;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON" *)
    logic vga_packed_memory_sync2_q;
    wire  vga_packed_memory_active = vga_packed_memory_sync2_q;
    wire  vga_packed_memory_request = memory_busy_q && memory_selected_q &&
                                       vga_packed_memory_active &&
                                       !memory_a16_q;

    // The AT router owns the whole A0000-BFFFF region. An unselected EGA
    // access must still complete there: reads float high, writes do nothing.
    // In particular neither an outside read nor write may update VRAM latches.
    assign memory_read_data = !memory_selected_q ? 8'hFF :
                              vga_packed_memory_request ?
                               vga_framebuffer_cpu_dout : vram_cpu_dout;
    assign memory_ready = !memory_selected_q ? 1'b1 :
                          vga_packed_memory_request ?
                          vga_framebuffer_cpu_ready : vram_cpu_ready;

    always_ff @(posedge clk_video) begin
        if (video_reset)
            vga_packed_memory_video_q <= 1'b0;
        else
            vga_packed_memory_video_q <= vga_mode13_active_video &&
                                         !vga_planar_memory_active_video;
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            vga_packed_memory_sync1_q <= 1'b0;
            vga_packed_memory_sync2_q <= 1'b0;
        end else begin
            vga_packed_memory_sync1_q <= vga_packed_memory_video_q;
            vga_packed_memory_sync2_q <= vga_packed_memory_sync1_q;
        end
    end

    // ega_top sees the memory access in its own clock domain.  The VRAM
    // frontend has its own two-stage configuration crossing back to clk.
    logic memory_select_video1_q;
    logic memory_select_video2_q;
    logic memory_write_video1_q;
    logic memory_write_video2_q;
    always_ff @(posedge clk_video) begin
        if (video_reset) begin
            memory_select_video1_q <= 1'b0;
            memory_select_video2_q <= 1'b0;
            memory_write_video1_q <= 1'b0;
            memory_write_video2_q <= 1'b0;
        end else begin
            memory_select_video1_q <= memory_busy_q && memory_selected_q;
            memory_select_video2_q <= memory_select_video1_q;
            memory_write_video1_q <= memory_write_q;
            memory_write_video2_q <= memory_write_video1_q;
        end
    end

    ega_vram_bram_frontend u_vram (
        .clock              (clk),
        .reset_cpu          (reset),
        .clk_video          (clk_video),
        .reset_video        (video_reset),
        .cpu_addr           (memory_address_q),
        .cpu_a16            (memory_a16_q),
        .cpu_din            (memory_data_q),
        .cpu_read           (memory_busy_q && memory_selected_q && memory_read_q &&
                             !vga_packed_memory_request),
        .cpu_write          (memory_busy_q && memory_selected_q && memory_write_q &&
                             !vga_packed_memory_request),
        .cpu_dout           (vram_cpu_dout),
        .cpu_ready          (vram_cpu_ready),
        .video_addr         (ega_fetch_addr),
        .video_read_en      (ega_fetch_en),
        .video_plane0       (vram_plane0),
        .video_plane1       (vram_plane1),
        .video_plane2       (vram_plane2),
        .video_plane3       (vram_plane3),
        .video_data_valid   (vram_video_valid),
        .text_cell_addr     (ega_text_cell_addr),
        .text_font_addr     (ega_text_font_addr),
        .text_fetch_en      (ega_text_fetch_en),
        .text_char          (vram_text_char),
        .text_attr          (vram_text_attr),
        .text_glyph         (vram_text_glyph),
        .text_data_valid    (vram_text_valid),
        .cfg_toggle         (ega_cfg_toggle),
        .plane_write_mask   (ega_plane_write_mask),
        .odd_even_mode      (ega_odd_even_mode),
        .cpu_access_en      (ega_cpu_access_slot),
        .chain2_write       (ega_chain2_write),
        .chain2_read        (ega_chain2_read),
        .extended_memory    (ega_extended_memory),
        .mem_map_sel        (ega_mem_map_sel),
        .page_select        (ega_page_select),
        .write_mode         (ega_write_mode),
        .read_mode          (ega_read_mode),
        .read_plane_sel     (ega_read_plane_sel),
        .color_compare      (ega_color_compare),
        .color_dont_care    (ega_color_dont_care),
        .bit_mask           (ega_bit_mask),
        .set_reset          (ega_set_reset),
        .enable_set_reset   (ega_enable_set_reset),
        .rop_select         (ega_rop_select),
        .rotate_count       (ega_rotate_count)
    );

`ifndef PCAT_EGA_ONLY
    vga_framebuffer u_vga_framebuffer (
        .clk_cpu            (clk),
        .reset_cpu          (reset),
        .cpu_addr           (memory_address_q),
        .cpu_din            (memory_data_q),
        .cpu_read           (memory_busy_q && memory_read_q &&
                             vga_packed_memory_request),
        .cpu_write          (memory_busy_q && memory_write_q &&
                             vga_packed_memory_request),
        .cpu_dout           (vga_framebuffer_cpu_dout),
        .cpu_ready          (vga_framebuffer_cpu_ready),
        .clk_video          (clk_video),
        .video_addr         (vga_framebuffer_addr),
        .video_read_en      (vga_framebuffer_read_en),
        .video_pixel        (vga_framebuffer_pixel),
        .video_data_valid   (vga_framebuffer_data_valid)
    );
`else
    assign vga_framebuffer_cpu_dout = 8'h00;
    assign vga_framebuffer_cpu_ready = 1'b0;
    assign vga_framebuffer_pixel = 8'h00;
    assign vga_framebuffer_data_valid = 1'b0;
`endif

    // Video-domain request mailbox.  The command fields are held constant by
    // the source until the acknowledgement returns, so two synchronizer
    // stages on the toggle provide enough settling time for the bus fields.
    logic       video_io_req_sync1_q;
    logic       video_io_req_sync2_q;
    logic       video_io_req_seen_q;
    logic [1:0] video_io_state_q;
    logic [4:0] video_io_ticks_q;
    logic [14:0] video_bus_address_q;
    logic [7:0]  video_bus_data_q;
    logic        video_bus_ior_q;
    logic        video_bus_iow_q;
    logic        video_bus_aen_q;
    logic        video_io_ack_toggle;
    logic [7:0]  video_io_read_data;

    localparam logic [1:0] VIDEO_IO_IDLE  = 2'd0;
    localparam logic [1:0] VIDEO_IO_SETUP = 2'd1;
    localparam logic [1:0] VIDEO_IO_ACTIVE = 2'd2;
    localparam logic [1:0] VIDEO_IO_ACK   = 2'd3;

    wire [7:0] ega_bus_out;
    wire       ega_bus_dir;

    always_ff @(posedge clk_video) begin
        if (video_reset) begin
            video_io_req_sync1_q <= 1'b0;
            video_io_req_sync2_q <= 1'b0;
            video_io_req_seen_q <= 1'b0;
            video_io_state_q <= VIDEO_IO_IDLE;
            video_io_ticks_q <= 5'd0;
            video_bus_address_q <= 15'h0000;
            video_bus_data_q <= 8'h00;
            video_bus_ior_q <= 1'b1;
            video_bus_iow_q <= 1'b1;
            video_bus_aen_q <= 1'b1;
            video_io_ack_toggle <= 1'b0;
            video_io_read_data <= 8'h00;
        end else begin
            video_io_req_sync1_q <= io_request_toggle_q;
            video_io_req_sync2_q <= video_io_req_sync1_q;

            case (video_io_state_q)
                VIDEO_IO_IDLE: begin
                    video_bus_ior_q <= 1'b1;
                    video_bus_iow_q <= 1'b1;
                    video_bus_aen_q <= 1'b1;
                    if (video_io_req_sync2_q != video_io_req_seen_q) begin
                        video_io_req_seen_q <= video_io_req_sync2_q;
                        video_bus_address_q <= io_address_q;
                        video_bus_data_q <= io_data_q;
                        video_io_ticks_q <= 5'd3;
                        video_bus_aen_q <= 1'b0;
                        video_io_state_q <= VIDEO_IO_SETUP;
                    end
                end

                VIDEO_IO_SETUP: begin
                    video_bus_aen_q <= 1'b0;
                    if (video_io_ticks_q != 5'd0)
                        video_io_ticks_q <= video_io_ticks_q - 1'b1;
                    else begin
                        video_bus_ior_q <= io_read_q ? 1'b0 : 1'b1;
                        video_bus_iow_q <= io_write_q ? 1'b0 : 1'b1;
                        video_io_ticks_q <= 5'd6;
                        video_io_state_q <= VIDEO_IO_ACTIVE;
                    end
                end

                VIDEO_IO_ACTIVE: begin
                    video_bus_aen_q <= 1'b0;
                    if (video_io_ticks_q != 5'd0)
                        video_io_ticks_q <= video_io_ticks_q - 1'b1;
                    else begin
                        // An undecoded/write-only port leaves the ISA bus
                        // undriven. Do not turn an inactive mono port into 00h.
                        video_io_read_data <= ega_bus_dir ? ega_bus_out : 8'hFF;
                        video_bus_ior_q <= 1'b1;
                        video_bus_iow_q <= 1'b1;
                        video_bus_aen_q <= 1'b1;
                        video_io_state_q <= VIDEO_IO_ACK;
                    end
                end

                VIDEO_IO_ACK: begin
                    video_io_ack_toggle <= video_io_req_seen_q;
                    video_io_state_q <= VIDEO_IO_IDLE;
                end

                default: video_io_state_q <= VIDEO_IO_IDLE;
            endcase
        end
    end

    // Native EGA RGB follows the renderer/attribute pipeline, whose visible
    // window is later than the CRTC's HBLANK (13 dots in 80-column text).
    // Match PCXT-EGA's LHBL selection so the HDMI mixer and framebuffer keep
    // the entire rendered line. Private VGA and scandoubled rasters already
    // supply their own aligned blanking.
    wire ega_hblank_raw;
    assign video_hblank = (video_scandouble_active || vga_mode13_active_video)
                          ? ega_hblank_raw : ~video_de;

    ega_top u_ega (
        .clk                        (clk_video),
        .reset                      (video_reset),
        .bus_a                      (video_bus_address_q),
        .bus_ior_l                  (video_bus_ior_q),
        .bus_iow_l                  (video_bus_iow_q),
        .bus_d                      (video_bus_data_q),
        .bus_out                    (ega_bus_out),
        .bus_dir                    (ega_bus_dir),
        .bus_aen                    (video_bus_aen_q),
        .ega_fetch_addr             (ega_fetch_addr),
        .ega_fetch_en               (ega_fetch_en),
        .ega_plane0_data            (vram_plane0),
        .ega_plane1_data            (vram_plane1),
        .ega_plane2_data            (vram_plane2),
        .ega_plane3_data            (vram_plane3),
        .ega_fetch_data_valid       (vram_video_valid),
        .ega_text_cell_addr         (ega_text_cell_addr),
        .ega_text_font_addr         (ega_text_font_addr),
        .ega_text_fetch_en          (ega_text_fetch_en),
        .ega_text_char              (vram_text_char),
        .ega_text_attr              (vram_text_attr),
        .ega_text_glyph             (vram_text_glyph),
        .ega_text_data_valid        (vram_text_valid),
        .vga_framebuffer_addr       (vga_framebuffer_addr),
        .vga_framebuffer_read_en    (vga_framebuffer_read_en),
        .vga_framebuffer_pixel      (vga_framebuffer_pixel),
        .vga_framebuffer_data_valid (vga_framebuffer_data_valid),
        .cpu_mem_select             (memory_select_video2_q),
        .cpu_mem_write              (memory_write_video2_q),
        .ega_cfg_toggle             (ega_cfg_toggle),
        .ega_plane_write_mask_out   (ega_plane_write_mask),
        .ega_odd_even_mode_out      (ega_odd_even_mode),
        .ega_cpu_access_slot_out    (ega_cpu_access_slot),
        .ega_chain2_write_out       (ega_chain2_write),
        .ega_chain2_read_out        (ega_chain2_read),
        .ega_extended_memory_out    (ega_extended_memory),
        .ega_mem_map_sel_out        (ega_mem_map_sel),
        .ega_page_select_out        (ega_page_select),
        .ega_write_mode_out         (ega_write_mode),
        .ega_read_mode_out          (ega_read_mode),
        .ega_read_plane_sel_out     (ega_read_plane_sel),
        .ega_color_compare_out      (ega_color_compare),
        .ega_color_dont_care_out    (ega_color_dont_care),
        .ega_bit_mask_out           (ega_bit_mask),
        .ega_set_reset_out          (ega_set_reset),
        .ega_enable_set_reset_out   (ega_enable_set_reset),
        .ega_rop_select_out         (ega_rop_select),
        .ega_rotate_count_out       (ega_rotate_count),
        .ega_blink_counter_out      (),
        .ega_blink_state_out        (),
        .hsync                      (video_hsync),
        .hblank                     (ega_hblank_raw),
        .dbl_hsync                  (video_dbl_hsync),
        .vsync                      (video_vsync),
        .vblank                     (video_vblank),
        .vblank_border              (video_vblank_border),
        .std_hsyncwidth             (),
        .de_o                       (video_de),
        .ega_red                    (video_red),
        .ega_green                  (video_green),
        .ega_blue                   (video_blue),
        .ega_display_sel_out        (),
        .ega_dot_toggle_out         (video_dot_toggle),
        .ega_dot_clock_sel_out      (),
        .ega_scandouble_active_out  (video_scandouble_active),
        .ega_mode350_out            (video_mode350),
        .ega_active_dots_out        (video_active_dots),
        .ega_active_lines_out       (video_active_lines),
        .ega_vmode_toggle_out       (video_vmode_toggle),
        .splashscreen               (splash_video_sync2_q),
        .prebios_video              (prebios_video_sync2_q),
        .thin_font                  (1'b0),
        .scandouble_en              (1'b0),
        .ega_enabled                (1'b1),
        .ega_monitor_profile        (video_geometry[15:14]),
        .vga_enabled                (video_geometry[13]),
        .vga_mode13_native          (vga_mode13_native_video_sync2_q),
        .vga_mode13_set             (1'b0),
        .vga_mode13_clear           (1'b0),
        .vga_mode13_active_out      (vga_mode13_active_video),
        .vga_unchained256_active_out(),
        .vga_mode13_wide_clock_out  (),
        .vga_planar_memory_active_out(vga_planar_memory_active_video),
        .vga_mode13_pixel_toggle_out(),
        .crt_h_offset               (video_geometry[3:0]),
        .crt_v_offset               (video_geometry[6:4]),
        .vsync_width_osd            (video_geometry[9:7]),
        .hsync_width_osd            (video_geometry[12:10])
    );

endmodule
