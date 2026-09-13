// AT device decode and response router.
//
// One normalized request has one owner.  The router latches that owner until
// its child reaches DONE, so changing the CPU address while READY is pending
// cannot redirect the response to another device.
`timescale 1ns/1ps

module spk286_at_device_router (
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
    output logic [3:0]  selected_device,
    output logic        unmapped_request,

    input  logic        keyboard_byte_valid,
    input  logic [7:0]  keyboard_byte,
    output logic        keyboard_byte_ready,
    output logic        keyboard_translate_set1,
    output logic        keyboard_output_valid,
    output logic [7:0]  keyboard_output_byte,
    output logic        irq1,
    output logic        a20_enable,
    output logic        cpu_reset_request,

    input  logic        periodic_tick,
    input  logic        second_tick,
    output logic        irq8,
    output logic        nmi_mask,

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
    output logic        irq6,
    output logic        irq14,
    input  logic [1:0]  use_mmc,
    output logic [2:0]  ide_request,
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
    output logic [15:0] irq_request,
    output wire [3:0]   debug_fault_sources,
    output logic        protocol_error
);
    localparam logic [2:0] ROUTER_IDLE   = 3'd0;
    localparam logic [2:0] ROUTER_ACTIVE = 3'd1;
    localparam logic [2:0] ROUTER_DONE   = 3'd2;

    localparam logic [3:0] DEVICE_NONE    = 4'd0;
    localparam logic [3:0] DEVICE_8042    = 4'd1;
    localparam logic [3:0] DEVICE_RTC     = 4'd2;
    localparam logic [3:0] DEVICE_STORAGE = 4'd3;
    localparam logic [3:0] DEVICE_UNMAPPED = 4'd15;

    logic [2:0] router_state_q;
    logic [3:0] target_device_q;
    logic       unmapped_read_q;
    logic [1:0] unmapped_lane_q;
    logic [15:0] response_data_q;
    logic        response_data_valid_q;
    logic        router_protocol_error_q;

    logic       device_8042_candidate;
    logic       device_rtc_candidate;
    logic       device_storage_candidate;
    logic       device_candidate;
    logic       lane_valid;

    logic       kbd_request_accept;
    logic       kbd_request_ready;
    logic [15:0] kbd_read_data;
    logic       kbd_read_data_valid;
    logic       kbd_protocol_error;
    logic [15:0] kbd_side_effect_count;

    logic       rtc_request_accept;
    logic       rtc_request_ready;
    logic [15:0] rtc_read_data;
    logic       rtc_read_data_valid;
    logic       rtc_protocol_error;
    logic [15:0] rtc_side_effect_count;

    logic       storage_request_accept;
    logic       storage_request_ready;
    logic [15:0] storage_read_data;
    logic       storage_read_data_valid;
    logic       storage_protocol_error;
    logic [15:0] storage_side_effect_count;
    logic [2:0]  storage_ide_request;

    always_comb begin
        device_8042_candidate = request_valid && request_command_valid &&
                                request_io &&
                                ((request_address[15:0] == 16'h0060) ||
                                 (request_address[15:0] == 16'h0064));
        device_rtc_candidate = request_valid && request_command_valid &&
                               request_io &&
                               ((request_address[15:0] == 16'h0070) ||
                                (request_address[15:0] == 16'h0071));
        device_storage_candidate = request_valid && request_command_valid &&
                                   ((request_io &&
                                     (((request_address[15:0] >= 16'h01F0) &&
                                       (request_address[15:0] <= 16'h01F7)) ||
                                      ((request_address[15:0] >= 16'h03B0) &&
                                       (request_address[15:0] <= 16'h03DF)) ||
                                      ((request_address[15:0] >= 16'h03F0) &&
                                       (request_address[15:0] <= 16'h03F7)) ||
                                      ((request_address[15:4] == 12'h030) &&
                                       ((!request_address[3]) ||
                                        (request_address[3:0] == 4'h8) ||
                                        (request_address[2:1] != 2'b00))))) ||
                                    (!request_io &&
                                     (request_address[23:0] >= 24'h0A0000) &&
                                     (request_address[23:0] <= 24'h0BFFFF)));
        device_candidate = device_8042_candidate || device_rtc_candidate ||
                           device_storage_candidate;
        lane_valid = ((request_address[0] == 1'b0) &&
                      (request_byte_enable == 2'b01)) ||
                     ((request_address[0] == 1'b1) &&
                      (request_byte_enable == 2'b10)) ||
                     (device_storage_candidate && request_io &&
                      (request_address[15:0] == 16'h01F0) &&
                      (request_byte_enable == 2'b11)) ||
                     (device_storage_candidate && request_io &&
                      (request_address[15:0] == 16'h0300) &&
                      (request_byte_enable == 2'b11));

        selected_device = DEVICE_NONE;
        if (router_state_q != ROUTER_IDLE)
            selected_device = target_device_q;
        else if (device_8042_candidate)
            selected_device = DEVICE_8042;
        else if (device_rtc_candidate)
            selected_device = DEVICE_RTC;
        else if (device_storage_candidate)
            selected_device = DEVICE_STORAGE;
        else if (request_valid && request_command_valid && request_io)
            selected_device = DEVICE_UNMAPPED;

        unmapped_request = request_valid && request_command_valid &&
                           request_io && !device_candidate;
    end

    spk286_at_8042 u_8042 (
        .clk(clk), .reset(reset),
        .request_valid(device_8042_candidate),
        .request_command_valid(request_command_valid),
        .request_write(request_write), .request_io(request_io),
        .request_address(request_address),
        .request_byte_enable(request_byte_enable),
        .request_data_out(request_data_out),
        .request_accept(kbd_request_accept), .request_ready(kbd_request_ready),
        .request_read_data(kbd_read_data),
        .request_read_data_valid(kbd_read_data_valid),
        .keyboard_byte_valid(keyboard_byte_valid),
        .keyboard_byte(keyboard_byte),
        .keyboard_byte_ready(keyboard_byte_ready),
        .keyboard_translate_set1(keyboard_translate_set1),
        .keyboard_output_valid(keyboard_output_valid),
        .keyboard_output_byte(keyboard_output_byte), .irq1(irq1),
        .a20_enable(a20_enable), .cpu_reset_request(cpu_reset_request),
        .side_effect_count(kbd_side_effect_count),
        .protocol_error(kbd_protocol_error)
    );

    spk286_at_rtc_cmos u_rtc (
        .clk(clk), .reset(reset),
        .request_valid(device_rtc_candidate),
        .request_command_valid(request_command_valid),
        .request_write(request_write), .request_io(request_io),
        .request_address(request_address),
        .request_byte_enable(request_byte_enable),
        .request_data_out(request_data_out),
        .request_accept(rtc_request_accept), .request_ready(rtc_request_ready),
        .request_read_data(rtc_read_data),
        .request_read_data_valid(rtc_read_data_valid),
        .mgmt_address(mgmt_address), .mgmt_writedata(mgmt_writedata),
        .mgmt_write(mgmt_write),
        .periodic_tick(periodic_tick), .second_tick(second_tick),
        .irq8(irq8), .nmi_mask(nmi_mask),
        .side_effect_count(rtc_side_effect_count),
        .selected_index(), .protocol_error(rtc_protocol_error)
    );

    spk286_at_storage_video u_storage_video (
        .clk(clk), .reset(reset),
        .clk_video(clk_video), .splashscreen(splashscreen),
        .use_mmc(use_mmc),
        .request_valid(device_storage_candidate),
        .request_command_valid(request_command_valid),
        .request_write(request_write), .request_io(request_io),
        .request_address(request_address),
        .request_byte_enable(request_byte_enable),
        .request_data_out(request_data_out),
        .request_accept(storage_request_accept),
        .request_ready(storage_request_ready),
        .request_read_data(storage_read_data),
        .request_read_data_valid(storage_read_data_valid),
        .dma_transfer_valid(dma_transfer_valid),
        .dma_transfer_complete(dma_transfer_complete),
        .dma_terminal_count(dma_terminal_count),
        .dma_active_channel(dma_active_channel),
        .dma_transfer_data_in(dma_transfer_data_in),
        .dma_transfer_accept(dma_transfer_accept),
        .dma_transfer_ready(dma_transfer_ready),
        .dma_transfer_data_out(dma_transfer_data_out),
        .dma_request(dma_request),
        .mgmt_address(mgmt_address), .mgmt_writedata(mgmt_writedata),
        .mgmt_write(mgmt_write), .mgmt_read(mgmt_read),
        .mgmt_readdata(mgmt_readdata),
        .floppy_write_protect(floppy_write_protect),
        .floppy_present(floppy_present), .floppy_request(floppy_request),
        .ata_irq14(irq14), .floppy_irq6(irq6),
        .ide_request(storage_ide_request),
        .ata_selected(ata_selected), .floppy_selected(floppy_selected),
        .video_io_selected(video_io_selected),
        .video_memory_selected(video_memory_selected),
        .video_red(video_red), .video_green(video_green),
        .video_blue(video_blue), .video_hsync(video_hsync),
        .video_hblank(video_hblank), .video_dbl_hsync(video_dbl_hsync),
        .video_vsync(video_vsync), .video_vblank(video_vblank),
        .video_vblank_border(video_vblank_border), .video_de(video_de),
        .video_dot_toggle(video_dot_toggle),
        .video_scandouble_active(video_scandouble_active),
        .video_vmode_toggle(video_vmode_toggle),
        .video_mode350(video_mode350),
        .video_active_dots(video_active_dots),
        .video_active_lines(video_active_lines),
        .side_effect_count(storage_side_effect_count),
        .ata_command_count(), .floppy_command_count(),
        .protocol_error(storage_protocol_error)
    );

    always_comb begin
        request_accept = 1'b0;
        if (router_state_q == ROUTER_IDLE) begin
            if (device_8042_candidate)
                request_accept = kbd_request_accept;
            else if (device_rtc_candidate)
                request_accept = rtc_request_accept;
            else if (device_storage_candidate)
                request_accept = storage_request_accept;
            else if (unmapped_request && lane_valid)
                request_accept = 1'b1;
        end

        request_ready = (router_state_q == ROUTER_DONE);
        request_read_data = response_data_q;
        request_read_data_valid = request_ready && response_data_valid_q;
        if ((router_state_q == ROUTER_DONE) &&
            (target_device_q == DEVICE_UNMAPPED)) begin
            request_read_data = unmapped_lane_q[1] ? 16'hFF00 : 16'h00FF;
            request_read_data_valid = !unmapped_read_q ? 1'b0 : 1'b1;
        end

        side_effect_count = kbd_side_effect_count + rtc_side_effect_count +
                             storage_side_effect_count;
        irq_request = 16'h0000;
        irq_request[1] = irq1;
        irq_request[6] = irq6;
        irq_request[8] = irq8;
        irq_request[14] = irq14;
        ide_request = storage_ide_request;
    end

    assign debug_fault_sources = {storage_protocol_error, rtc_protocol_error,
                                  kbd_protocol_error, router_protocol_error_q};

    assign protocol_error = router_protocol_error_q | kbd_protocol_error |
                            rtc_protocol_error | storage_protocol_error;

    always_ff @(posedge clk) begin
        if (reset) begin
            router_state_q <= ROUTER_IDLE;
            target_device_q <= DEVICE_NONE;
            unmapped_read_q <= 1'b0;
            unmapped_lane_q <= 2'b00;
            response_data_q <= 16'h0000;
            response_data_valid_q <= 1'b0;
            router_protocol_error_q <= 1'b0;
        end else begin
            case (router_state_q)
                ROUTER_IDLE: begin
                    response_data_valid_q <= 1'b0;
                    if (request_accept) begin
                        router_state_q <= ROUTER_ACTIVE;
                        target_device_q <= selected_device;
                        if (selected_device == DEVICE_UNMAPPED) begin
                            unmapped_read_q <= !request_write;
                            unmapped_lane_q <= request_byte_enable;
                        end
                    end
                    if (unmapped_request && !lane_valid)
                        router_protocol_error_q <= 1'b1;
                end
                ROUTER_ACTIVE: begin
                    if (target_device_q == DEVICE_8042 && kbd_request_ready) begin
                        router_state_q <= ROUTER_DONE;
                        response_data_q <= kbd_read_data;
                        response_data_valid_q <= kbd_read_data_valid;
                    end else if (target_device_q == DEVICE_RTC && rtc_request_ready) begin
                        router_state_q <= ROUTER_DONE;
                        response_data_q <= rtc_read_data;
                        response_data_valid_q <= rtc_read_data_valid;
                    end else if (target_device_q == DEVICE_STORAGE &&
                                 storage_request_ready) begin
                        router_state_q <= ROUTER_DONE;
                        response_data_q <= storage_read_data;
                        response_data_valid_q <= storage_read_data_valid;
                    end else if (target_device_q == DEVICE_UNMAPPED) begin
                        router_state_q <= ROUTER_DONE;
                        response_data_q <= 16'hFFFF;
                        response_data_valid_q <= unmapped_read_q;
                    end
                end
                ROUTER_DONE: begin
                    router_state_q <= ROUTER_IDLE;
                    target_device_q <= DEVICE_NONE;
                end
                default: router_state_q <= ROUTER_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset) begin
            assert (!((selected_device == DEVICE_8042) &&
                      (selected_device == DEVICE_RTC)))
                else $error("AT device router selected two owners");
            assert (!(request_accept && !lane_valid && unmapped_request))
                else $error("AT router accepted an invalid unmapped lane");
        end
    end
`endif
endmodule
