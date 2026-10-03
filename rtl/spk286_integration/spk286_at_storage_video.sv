// Functional AT storage/video device boundary.
//
// The storage side exposes the primary ATA registers and the shared uPD765
// floppy controller, including its channel-2 DMA request. The video side is
// the real EGA device: its register file, CRTC and planar VRAM are provided by
// spk286_at_video_adapter and share this request owner with ATA/FDC.
`timescale 1ns/1ps

module spk286_at_storage_video #(
    parameter logic RETAINED_FDC_WRITE = 1'b0
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        video_reset,
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
    input  logic [1:0]  use_mmc,

    input  logic        request_valid,
    input  logic        request_command_valid,
    input  logic        request_write,
    input  logic        request_io,
    input  logic [23:0] request_address,
    input  logic [1:0]  request_byte_enable,
    input  logic [15:0] request_data_out,
    input  logic        retained_io_command,
    input  logic [23:0] retained_io_address,
    input  logic        retained_io_write,
    input  logic [1:0]  retained_io_byte_enable,
    input  logic [15:0] retained_io_data_out,
    output logic        request_accept,
    output logic        request_ready,
    output logic [15:0] request_read_data,
    output logic        request_read_data_valid,

    input  logic        dma_transfer_valid,
    input  logic        dma_transfer_complete,
    input  logic        dma_terminal_count,
    input  logic [2:0]  dma_active_channel,
    input  logic [15:0] dma_transfer_data_in,
    output logic        dma_transfer_accept,
    output logic        dma_transfer_ready,
    output logic [15:0] dma_transfer_data_out,
    output logic [7:0]  dma_request,

    input  logic [15:0] mgmt_address,
    input  logic [15:0] mgmt_writedata,
    input  logic        mgmt_write,
    input  logic        mgmt_read,
    output logic [15:0] mgmt_readdata,
    input  logic [1:0]  floppy_write_protect,
    output logic [1:0]  floppy_present,
    output logic [1:0]  floppy_request,

    output logic        ata_irq14,
    output logic [2:0]  ide_request,
    output logic        floppy_irq6,
    output logic        ata_selected,
    output logic        floppy_selected,
    output logic        video_io_selected,
    output logic        video_memory_selected,
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
    output logic [9:0]  video_active_lines,
    output logic [15:0] side_effect_count,
    output logic [15:0] ata_command_count,
    output logic [15:0] floppy_command_count,
    output logic        protocol_error
);
    localparam logic IO_IDLE = 1'b0;
    localparam logic IO_DONE = 1'b1;

    logic       io_state_q;
    logic [15:0] io_read_data_q;
    logic       io_read_data_valid_q;
    logic [15:0] current_read_data;
    logic [7:0] request_byte;
    logic       lane_valid;
    logic       ata_data_word;
    logic       xtide_selected;
    logic       xtide_data_word;
    logic       device_selected;

    logic [7:0]  ata_status_q;
    logic [7:0]  ata_error_q;
    logic [7:0]  ata_features_q;
    logic [7:0]  ata_sector_count_q;
    logic [7:0]  ata_lba_low_q;
    logic [7:0]  ata_lba_mid_q;
    logic [7:0]  ata_lba_high_q;
    logic [7:0]  ata_drive_head_q;
    logic [15:0] ata_data_q;
    logic [7:0]  ata_data_index_q;
    logic       video_active_q;
    logic       floppy_active_q;
    logic       xtide_active_q;
    logic       video_request_accept;
    logic       video_request_ready;
    logic [15:0] video_read_data;
    logic       video_read_data_valid;
    logic       floppy_request_accept;
    logic       floppy_request_ready;
    logic [15:0] floppy_read_data;
    logic       floppy_read_data_valid;
    logic       floppy_dma_transfer_accept;
    logic       floppy_dma_transfer_ready;
    logic [15:0] floppy_dma_transfer_data_out;
    logic [7:0] floppy_dma_request;
    logic       floppy_irq;
    logic [15:0] floppy_command_count_i;
    logic       floppy_protocol_error;
    logic       xtide_request_accept;
    logic       xtide_request_ready;
    logic [15:0] xtide_read_data;
    logic       xtide_read_data_valid;
    logic [15:0] xtide_mgmt_readdata;
    logic [2:0]  xtide_ide_request;
    logic       xtide_irq14;
    logic       xtide_protocol_error;
    logic [15:0] floppy_mgmt_readdata;
    logic       protocol_error_q;
    integer i;

    always_comb begin
        ata_selected = request_valid && request_command_valid && request_io &&
                       (request_address[15:0] >= 16'h01F0) &&
                       (request_address[15:0] <= 16'h01F7);
        // 3F6h is the AT IDE alternate-status/device-control port. The
        // neighboring floppy ports remain owned by the uPD765, including
        // 3F7h (digital input/change register).
        floppy_selected = request_valid && request_command_valid && request_io &&
                          (request_address[15:0] >= 16'h03F0) &&
                          (request_address[15:0] <= 16'h03F7) &&
                          (request_address[15:0] != 16'h03F6);
        video_io_selected = request_valid && request_command_valid && request_io &&
                            (request_address[15:0] >= 16'h03B0) &&
                            (request_address[15:0] <= 16'h03DF);
        video_memory_selected = request_valid && request_command_valid &&
                                !request_io &&
                                (request_address[23:0] >= 24'h0A0000) &&
                                (request_address[23:0] <= 24'h0BFFFF);
        // Standard AT IDE channel: 1F0h-1F7h are the command block and 3F6h
        // is the alternate-status/device-control register.
        xtide_selected = request_valid && request_command_valid &&
                         request_io &&
                         (((request_address[15:0] >= 16'h01F0) &&
                           (request_address[15:0] <= 16'h01F7)) ||
                          (request_address[15:0] == 16'h03F6));
        device_selected = ata_selected || floppy_selected ||
                          video_io_selected || video_memory_selected ||
                          xtide_selected;

        lane_valid = ((request_address[0] == 1'b0) &&
                      (request_byte_enable == 2'b01)) ||
                     ((request_address[0] == 1'b1) &&
                      (request_byte_enable == 2'b10));
        ata_data_word = ata_selected &&
                        (request_address[15:0] == 16'h01F0) &&
                        (request_byte_enable == 2'b11);
        xtide_data_word = xtide_selected &&
                          (request_address[15:0] == 16'h01F0) &&
                          (request_byte_enable == 2'b11);
        request_byte = request_byte_enable[1] ?
                       request_data_out[15:8] : request_data_out[7:0];

        current_read_data = 16'h0000;
        if (ata_selected) begin
            case (request_address[15:0])
                16'h01F0: current_read_data = ata_data_q;
                16'h01F1: current_read_data = {8'h00, ata_error_q};
                16'h01F2: current_read_data = {8'h00, ata_sector_count_q};
                16'h01F3: current_read_data = {8'h00, ata_lba_low_q};
                16'h01F4: current_read_data = {8'h00, ata_lba_mid_q};
                16'h01F5: current_read_data = {8'h00, ata_lba_high_q};
                16'h01F6: current_read_data = {8'h00, ata_drive_head_q};
                16'h01F7: current_read_data = {8'h00, ata_status_q};
                default:  current_read_data = 16'h0000;
            endcase
        end

        // Byte devices return data on the addressed lane.  ATA data port 1F0h
        // also admits a native 16-bit transfer in the normalized boundary.
        if (!ata_data_word && (request_byte_enable == 2'b10))
            current_read_data = {current_read_data[7:0], 8'h00};
        else if (!ata_data_word && (request_byte_enable == 2'b01))
            current_read_data = {8'h00, current_read_data[7:0]};
    end

    // Video transactions have their own clock-crossing completion. The shared
    // floppy controller registers its read data and therefore owns a separate
    // normalized completion. ATA remains the short local endpoint.
    assign request_accept = (video_io_selected || video_memory_selected) ?
                            video_request_accept :
                            (floppy_selected ? floppy_request_accept :
                             (xtide_selected ? xtide_request_accept :
                              ((io_state_q == IO_IDLE) && ata_selected &&
                               (lane_valid || ata_data_word))));
    assign request_ready = video_active_q ? video_request_ready :
                           (floppy_active_q ? floppy_request_ready :
                            (xtide_active_q ? xtide_request_ready :
                             (io_state_q == IO_DONE)));
    assign request_read_data_valid = video_active_q ? video_read_data_valid :
                                     (floppy_active_q ? floppy_read_data_valid :
                                      (xtide_active_q ? xtide_read_data_valid :
                                       (request_ready && io_read_data_valid_q)));
    assign request_read_data = video_active_q ? video_read_data :
                               (floppy_active_q ? floppy_read_data :
                                (xtide_active_q ? xtide_read_data :
                                 io_read_data_q));
    assign dma_request = floppy_dma_request;
    assign dma_transfer_accept = floppy_dma_transfer_accept;
    assign dma_transfer_ready = floppy_dma_transfer_ready;
    assign dma_transfer_data_out = floppy_dma_transfer_data_out;
    assign ata_irq14 = ata_irq14_q | xtide_irq14;
    assign ide_request = xtide_ide_request;
    assign floppy_irq6 = floppy_irq;
    assign floppy_command_count = floppy_command_count_i;
    assign mgmt_readdata = (mgmt_address[15:8] == 8'hF0) ?
                           xtide_mgmt_readdata : floppy_mgmt_readdata;
    assign protocol_error = protocol_error_q || floppy_protocol_error ||
                            xtide_protocol_error;

    logic ata_irq14_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            io_state_q <= IO_IDLE;
            io_read_data_q <= 16'h0000;
            io_read_data_valid_q <= 1'b0;
            ata_status_q <= 8'h50;
            ata_error_q <= 8'h00;
            ata_features_q <= 8'h00;
            ata_sector_count_q <= 8'h01;
            ata_lba_low_q <= 8'h00;
            ata_lba_mid_q <= 8'h00;
            ata_lba_high_q <= 8'h00;
            ata_drive_head_q <= 8'hA0;
            ata_data_q <= 16'h0040;
            ata_data_index_q <= 8'h00;
            ata_irq14_q <= 1'b0;
            side_effect_count <= 16'h0000;
            ata_command_count <= 16'h0000;
            protocol_error_q <= 1'b0;
            video_active_q <= 1'b0;
            floppy_active_q <= 1'b0;
            xtide_active_q <= 1'b0;
        end else begin
            if (io_state_q == IO_DONE)
                io_state_q <= IO_IDLE;

            if (video_active_q && video_request_ready)
                video_active_q <= 1'b0;
            if (floppy_active_q && floppy_request_ready)
                floppy_active_q <= 1'b0;
            if (xtide_active_q && xtide_request_ready)
                xtide_active_q <= 1'b0;

            if (request_accept && (video_io_selected || video_memory_selected)) begin
                video_active_q <= 1'b1;
                side_effect_count <= side_effect_count + 16'h0001;
            end else if (floppy_request_accept) begin
                floppy_active_q <= 1'b1;
                side_effect_count <= side_effect_count + 16'h0001;
            end else if (xtide_request_accept) begin
                xtide_active_q <= 1'b1;
                side_effect_count <= side_effect_count + 16'h0001;
            end else if (request_accept) begin
                io_state_q <= IO_DONE;
                io_read_data_valid_q <= !request_write;
                io_read_data_q <= current_read_data;
                side_effect_count <= side_effect_count + 16'h0001;

                if (ata_selected) begin
                    if (request_address[15:0] == 16'h01F0) begin
                        if (request_write)
                            ata_data_q <= request_data_out;
                        else
                            ata_data_index_q <= ata_data_index_q + 8'h01;
                    end else if (request_write) begin
                        case (request_address[15:0])
                            16'h01F1: ata_features_q <= request_byte;
                            16'h01F2: ata_sector_count_q <= request_byte;
                            16'h01F3: ata_lba_low_q <= request_byte;
                            16'h01F4: ata_lba_mid_q <= request_byte;
                            16'h01F5: ata_lba_high_q <= request_byte;
                            16'h01F6: ata_drive_head_q <= request_byte;
                            16'h01F7: begin
                                ata_status_q <= 8'h58;
                                ata_command_count <= ata_command_count + 16'h0001;
                                ata_irq14_q <= 1'b1;
                                if (request_byte == 8'hEC)
                                    ata_data_q <= 16'h0040;
                            end
                            default: begin end
                        endcase
                    end else if (request_address[15:0] == 16'h01F7) begin
                        ata_irq14_q <= 1'b0;
                    end
                end
            end

            if (device_selected && !(lane_valid || ata_data_word ||
                                     xtide_data_word))
                protocol_error_q <= 1'b1;
        end
    end

    spk286_at_fdc #(
        .RETAINED_FDC_WRITE(RETAINED_FDC_WRITE)
    ) u_fdc (
        .clk                    (clk),
        .reset                  (reset),
        // 3F6h is shared in the broad ISA decode but belongs to IDE on an AT;
        // keep the FDC endpoint from accepting it behind the top-level
        // priority mux.
        .request_valid          (request_valid && floppy_selected),
        .retained_io_command     (retained_io_command),
        .retained_io_address     (retained_io_address),
        .retained_io_write       (retained_io_write),
        .retained_io_byte_enable (retained_io_byte_enable),
        .retained_io_data_out    (retained_io_data_out),
        .request_command_valid  (request_command_valid && floppy_selected),
        .request_write          (request_write),
        .request_io             (request_io),
        .request_address        (request_address),
        .request_byte_enable    (request_byte_enable),
        .request_data_out       (request_data_out),
        .request_accept         (floppy_request_accept),
        .request_ready          (floppy_request_ready),
        .request_read_data      (floppy_read_data),
        .request_read_data_valid(floppy_read_data_valid),
        .dma_transfer_valid     (dma_transfer_valid),
        .dma_transfer_complete  (dma_transfer_complete),
        .dma_terminal_count     (dma_terminal_count),
        .dma_active_channel     (dma_active_channel),
        .dma_transfer_data_in   (dma_transfer_data_in),
        .dma_transfer_accept    (floppy_dma_transfer_accept),
        .dma_transfer_ready     (floppy_dma_transfer_ready),
        .dma_transfer_data_out  (floppy_dma_transfer_data_out),
        .dma_request            (floppy_dma_request),
        .irq6                   (floppy_irq),
        .mgmt_address           (mgmt_address),
        .mgmt_writedata         (mgmt_writedata),
        .mgmt_write             (mgmt_write),
        .mgmt_read              (mgmt_read),
        .mgmt_readdata          (floppy_mgmt_readdata),
        .floppy_write_protect   (floppy_write_protect),
        .floppy_present         (floppy_present),
        .floppy_request         (floppy_request),
        .side_effect_count      (),
        .command_count          (floppy_command_count_i),
        .protocol_error         (floppy_protocol_error)
    );

    spk286_at_xtide u_xtide (
        .clk                    (clk),
        .reset                  (reset),
        .use_mmc                (use_mmc),
        .request_valid          (request_valid),
        .request_command_valid  (request_command_valid),
        .request_write          (request_write),
        .request_io             (request_io),
        .request_address        (request_address),
        .request_byte_enable    (request_byte_enable),
        .request_data_out       (request_data_out),
        .request_accept         (xtide_request_accept),
        .request_ready          (xtide_request_ready),
        .request_read_data      (xtide_read_data),
        .request_read_data_valid(xtide_read_data_valid),
        .mgmt_address           (mgmt_address),
        .mgmt_writedata         (mgmt_writedata),
        .mgmt_write             (mgmt_write),
        .mgmt_read              (mgmt_read),
        .mgmt_readdata          (xtide_mgmt_readdata),
        .ide_request            (xtide_ide_request),
        .irq14                  (xtide_irq14),
        .protocol_error         (xtide_protocol_error)
    );

    spk286_at_video_adapter u_video (
        .clk                    (clk),
        .reset                  (reset),
        .video_reset_in         (video_reset),
        .prebios_video          (prebios_video),
        .clk_video              (clk_video),
        .splashscreen           (splashscreen),
        .ega_monitor_profile    (ega_monitor_profile),
        .vga_enabled            (vga_enabled),
        .vga_mode13_native      (vga_mode13_native),
        .crt_h_offset           (crt_h_offset),
        .crt_v_offset           (crt_v_offset),
        .vsync_width_osd        (vsync_width_osd),
        .hsync_width_osd        (hsync_width_osd),
        .request_valid          (request_valid),
        .request_command_valid  (request_command_valid),
        .request_write          (request_write),
        .request_io             (request_io),
        .request_address        (request_address),
        .request_byte_enable    (request_byte_enable),
        .request_data_out       (request_data_out),
        .request_accept         (video_request_accept),
        .request_ready          (video_request_ready),
        .request_read_data      (video_read_data),
        .request_read_data_valid(video_read_data_valid),
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
        .video_active_lines     (video_active_lines)
    );

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset)
            assert (!(request_accept && !device_selected))
                else $error("AT storage/video accepted an unselected request");
    end
`endif
endmodule
