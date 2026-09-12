// Functional AT storage/video device boundary.
//
// The storage side exposes deterministic primary ATA and floppy register
// behaviour plus a floppy-like DMA request on channel 2.  The video side is
// the real EGA device: its register file, CRTC and planar VRAM are provided by
// spk286_at_video_adapter and share this request owner with ATA/FDC.
`timescale 1ns/1ps

module spk286_at_storage_video (
    input  logic        clk,
    input  logic        reset,
    input  logic        clk_video,
    input  logic        splashscreen,

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

    input  logic        dma_transfer_valid,
    input  logic        dma_transfer_complete,
    input  logic        dma_terminal_count,
    input  logic [2:0]  dma_active_channel,
    output logic        dma_transfer_accept,
    output logic        dma_transfer_ready,
    output logic [15:0] dma_transfer_data_out,
    output logic [7:0]  dma_request,

    output logic        ata_irq14,
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
    logic       device_selected;
    logic       endpoint_seen_q;

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
    logic [7:0]  floppy_command_q;
    logic [1:0]  floppy_bytes_remaining_q;
    logic       floppy_busy_q;
    logic [7:0]  floppy_data_q;
    logic       video_active_q;
    logic       video_request_accept;
    logic       video_request_ready;
    logic [15:0] video_read_data;
    logic       video_read_data_valid;
    integer i;

    always_comb begin
        ata_selected = request_valid && request_command_valid && request_io &&
                       (request_address[15:0] >= 16'h01F0) &&
                       (request_address[15:0] <= 16'h01F7);
        floppy_selected = request_valid && request_command_valid && request_io &&
                          (request_address[15:0] >= 16'h03F0) &&
                          (request_address[15:0] <= 16'h03F7);
        video_io_selected = request_valid && request_command_valid && request_io &&
                            (request_address[15:0] >= 16'h03B0) &&
                            (request_address[15:0] <= 16'h03DF);
        video_memory_selected = request_valid && request_command_valid &&
                                !request_io &&
                                (request_address[23:0] >= 24'h0A0000) &&
                                (request_address[23:0] <= 24'h0BFFFF);
        device_selected = ata_selected || floppy_selected ||
                          video_io_selected || video_memory_selected;

        lane_valid = ((request_address[0] == 1'b0) &&
                      (request_byte_enable == 2'b01)) ||
                     ((request_address[0] == 1'b1) &&
                      (request_byte_enable == 2'b10));
        ata_data_word = ata_selected &&
                        (request_address[15:0] == 16'h01F0) &&
                        (request_byte_enable == 2'b11);
        request_byte = request_byte_enable[1] ?
                       request_data_out[15:8] : request_data_out[7:0];

        current_read_data = 16'h0000;
        if (floppy_selected) begin
            case (request_address[15:0])
                16'h03F4: current_read_data = {8'h00,
                                               4'b1000,
                                               floppy_busy_q,
                                               3'b000};
                16'h03F5: current_read_data = {8'h00, floppy_data_q};
                16'h03F7: current_read_data = 16'h0000;
                default:  current_read_data = 16'h0000;
            endcase
        end else if (ata_selected) begin
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

    // Video transactions have their own clock-crossing completion.  ATA and
    // floppy remain the short single-clock endpoints that were already
    // implemented here.
    assign request_accept = (video_io_selected || video_memory_selected) ?
                            video_request_accept :
                            ((io_state_q == IO_IDLE) && device_selected &&
                             (lane_valid || ata_data_word));
    assign request_ready = video_active_q ? video_request_ready :
                           (io_state_q == IO_DONE);
    assign request_read_data_valid = video_active_q ? video_read_data_valid :
                                     (request_ready && io_read_data_valid_q);
    assign request_read_data = video_active_q ? video_read_data : io_read_data_q;
    assign dma_request = floppy_busy_q ? 8'b00000100 : 8'h00;
    assign dma_transfer_accept = floppy_busy_q && dma_transfer_valid &&
                                 (dma_active_channel == 3'd2) &&
                                 !endpoint_seen_q;
    assign dma_transfer_ready = floppy_busy_q && dma_transfer_valid &&
                                (dma_active_channel == 3'd2) &&
                                endpoint_seen_q;
    assign dma_transfer_data_out = {8'hF0, floppy_data_q};
    assign ata_irq14 = ata_irq14_q;
    assign floppy_irq6 = floppy_irq6_q;

    logic ata_irq14_q;
    logic floppy_irq6_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            io_state_q <= IO_IDLE;
            io_read_data_q <= 16'h0000;
            io_read_data_valid_q <= 1'b0;
            endpoint_seen_q <= 1'b0;
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
            floppy_command_q <= 8'h00;
            floppy_bytes_remaining_q <= 2'd0;
            floppy_busy_q <= 1'b0;
            floppy_data_q <= 8'hF0;
            ata_irq14_q <= 1'b0;
            floppy_irq6_q <= 1'b0;
            side_effect_count <= 16'h0000;
            ata_command_count <= 16'h0000;
            floppy_command_count <= 16'h0000;
            protocol_error <= 1'b0;
            video_active_q <= 1'b0;
        end else begin
            if (io_state_q == IO_DONE)
                io_state_q <= IO_IDLE;

            if (video_active_q && video_request_ready)
                video_active_q <= 1'b0;

            if (!dma_transfer_valid)
                endpoint_seen_q <= 1'b0;
            else if (!endpoint_seen_q && dma_transfer_accept)
                endpoint_seen_q <= 1'b1;

            if (request_accept && (video_io_selected || video_memory_selected)) begin
                video_active_q <= 1'b1;
                side_effect_count <= side_effect_count + 16'h0001;
            end else if (request_accept) begin
                io_state_q <= IO_DONE;
                io_read_data_valid_q <= !request_write;
                io_read_data_q <= current_read_data;
                side_effect_count <= side_effect_count + 16'h0001;

                if (floppy_selected) begin
                    if (!request_write && request_address[15:0] == 16'h03F4)
                        floppy_irq6_q <= 1'b0;
                    else if (request_write && request_address[15:0] == 16'h03F5) begin
                        floppy_command_q <= request_byte;
                        floppy_command_count <= floppy_command_count + 16'h0001;
                        if ((request_byte == 8'h06) || (request_byte == 8'h46)) begin
                            floppy_busy_q <= 1'b1;
                            floppy_bytes_remaining_q <= 2'd2;
                            floppy_data_q <= 8'hF0;
                        end else if (request_byte == 8'h08) begin
                            floppy_busy_q <= 1'b0;
                            floppy_bytes_remaining_q <= 2'd0;
                            floppy_irq6_q <= 1'b0;
                        end
                    end
                end else if (ata_selected) begin
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

            if (dma_transfer_complete && dma_active_channel == 3'd2 &&
                floppy_busy_q) begin
                floppy_data_q <= floppy_data_q + 8'h01;
                if (floppy_bytes_remaining_q <= 2'd1 || dma_terminal_count) begin
                    floppy_bytes_remaining_q <= 2'd0;
                    floppy_busy_q <= 1'b0;
                    floppy_irq6_q <= 1'b1;
                end else begin
                    floppy_bytes_remaining_q <= floppy_bytes_remaining_q - 2'd1;
                end
            end

            if (device_selected && !(lane_valid || ata_data_word))
                protocol_error <= 1'b1;
        end
    end

    spk286_at_video_adapter u_video (
        .clk                    (clk),
        .reset                  (reset),
        .clk_video              (clk_video),
        .splashscreen           (splashscreen),
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
