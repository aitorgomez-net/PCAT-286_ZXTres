// Completed HPS configuration -> stable geometry calculation -> HDMI frame.
// The three mailboxes survive local resets and stopped video/HDMI clocks.
module at_scaler_config (
    input wire clk_sys, clk_video, clk_hdmi, src_idle,
    input wire video_vs, hdmi_vs,
    input wire [11:0] width, hfp, hbp, height, vfp, vbp,
    input wire [12:0] hs, vs,
    input wire [11:0] hset, vset,
    input wire pixel_repeat, freescale, enable, vrr,
    input wire [4:0] mode,
    input wire [12:0] arc1x, arc1y, arc2x, arc2y, arx_video, ary_video,
    input wire lfb,
    input wire [11:0] lfb_hmin, lfb_hmax, lfb_vmin, lfb_vmax,
    input wire fb_enable,
    input wire [11:0] fb_width, fb_height,
    input wire [5:0] fb_format,
    input wire [31:0] fb_base,
    input wire [13:0] fb_stride,
    output reg [11:0] hdmi_width = 0, hdmi_height = 0,
    output wire [11:0] arx_sys, ary_sys,
    output wire arxy_sys,
    output reg [4:0] input_mode = 0,
    output wire [4:0] output_mode,
    output wire output_enable, output_vrr, output_lfb,
    output wire [11:0] htotal, hsstart, hsend, hdisp, hmin, hmax,
    output wire [11:0] vtotal, vsstart, vsend, vdisp, vmin, vmax, vrrmax,
    output wire hs_polarity, vs_polarity,
    output wire output_fb_enable,
    output wire [11:0] output_fb_width, output_fb_height,
    output wire [5:0] output_fb_format,
    output wire [31:0] output_fb_base,
    output wire [13:0] output_fb_stride,
    output wire output_update,
    output reg output_retime = 0
);
    typedef struct packed {
        logic [11:0] width, hfp, hbp, height, vfp, vbp;
        logic [12:0] hs, vs;
        logic [11:0] hset, vset;
        logic pixel_repeat, freescale, enable, vrr;
        logic [4:0] mode;
        logic [12:0] arc1x, arc1y, arc2x, arc2y;
        logic lfb;
        logic [11:0] lfb_hmin, lfb_hmax, lfb_vmin, lfb_vmax;
        logic fb_enable;
        logic [11:0] fb_width, fb_height;
        logic [5:0] fb_format;
        logic [31:0] fb_base;
        logic [13:0] fb_stride;
    } config_t;
    typedef struct packed {
        logic raster_epoch;
        logic [4:0] mode;
        logic enable, vrr, lfb;
        logic [11:0] htotal, hsstart, hsend, hdisp, hmin, hmax;
        logic [11:0] vtotal, vsstart, vsend, vdisp, vmin, vmax, vrrmax;
        logic hs_polarity, vs_polarity;
        logic fb_enable;
        logic [11:0] fb_width, fb_height;
        logic [5:0] fb_format;
        logic [31:0] fb_base;
        logic [13:0] fb_stride;
    } frame_t;
    wire [$bits(config_t)-1:0] source_data = {
        width,hfp,hbp,height,vfp,vbp,hs,vs,hset,vset,
        pixel_repeat,freescale,enable,vrr,mode,arc1x,arc1y,arc2x,arc2y,
        lfb,lfb_hmin,lfb_hmax,lfb_vmin,lfb_vmax,
        fb_enable,fb_width,fb_height,fb_format,fb_base,fb_stride
    };
    wire config_update;
    config_t pending;
    config_t active_q = '0;
    // FB_* is registered once after the UIO transaction. Allow that stage
    // to settle before publishing the associated LFB bounds and mode.
    reg idle_q = 0;
    always @(posedge clk_sys) idle_q <= src_idle;
    at_cdc_snapshot #(.WIDTH($bits(config_t))) geometry_config (
        .src_clk(clk_sys), .src_send(src_idle && idle_q), .src_data(source_data),
        .src_ready(), .dst_clk(clk_video), .dst_data(pending), .dst_update(config_update)
    );

    reg received_q = 0;
    reg [3:0] state = 0;
    // ARX/ARY launch on the related, unshifted video clock. Only this direct
    // capture uses its quarter-cycle relationship with clk_video (+90 deg).
    // Change detection and the wide active_q enable then get a full cycle.
    reg [25:0] aspect_video_q = 0;
    always @(posedge clk_video) aspect_video_q <= {arx_video,ary_video};
    wire [12:0] arx_local = aspect_video_q[25:13];
    wire [12:0] ary_local = aspect_video_q[12:0];
    reg [12:0] arx_q = 0, ary_q = 0;
    reg [11:0] ax = 0, ay = 0;
    reg axy = 0;
    reg [11:0] wcalc = 0, hcalc = 0, videow = 0, videoh = 0;
    reg [11:0] left_q = 0, right_q = 0, top_q = 0, bottom_q = 0;
    reg mul_start = 0;
    reg [11:0] mul1 = 0, mul2 = 0, divisor = 0;
    wire mul_busy;
    wire [23:0] mul_result;
    sys_umuldiv #(12,12,12) ar_muldiv (
        .clk(clk_video), .start(mul_start), .busy(mul_busy),
        .mul1(mul1), .mul2(mul2), .div(divisor), .result(mul_result), .remainder()
    );
    frame_t result_q = '0;
    frame_t output_active_q;
    wire frame_ready, frame_update;
    wire publish = (state == 11) && frame_ready;
    reg hdmi_vs_q = 0;
    wire frame_accept = !output_active_q.enable || (hdmi_vs_q && !hdmi_vs);
    at_scaler_frame_snapshot #(.WIDTH($bits(frame_t))) scaler_frame_config (
        .src_clk(clk_video), .src_send(publish), .src_data(result_q), .src_ready(frame_ready),
        .dst_clk(clk_hdmi), .dst_accept(frame_accept), .dst_data(output_active_q), .dst_update(frame_update)
    );
    // Return the computed aspect as a coherent value for HPS 0x40 and CRC.
    // HPS must never sample ax/ay directly from the geometry clock.
    reg [24:0] aspect_q = 0;
    at_cdc_snapshot #(.WIDTH(25)) aspect_readback (
        .src_clk(clk_video), .src_send(1'b1), .src_data(aspect_q), .src_ready(),
        .dst_clk(clk_sys), .dst_data({arxy_sys,arx_sys,ary_sys}), .dst_update()
    );

    always @(posedge clk_video) begin
        if (config_update) received_q <= 1;
        mul_start <= 0;
        case (state)
            0: if (received_q && (pending != active_q || arx_local != arx_q || ary_local != ary_q)) begin
                // Reuse the previous calculation's registers for change
                // detection; no extra copy of the 96-bit raster is needed.
                if ({pending.width,pending.hfp,pending.hs[11:0],pending.hbp,
                     pending.height,pending.vfp,pending.vs[11:0],pending.vbp} !=
                    {active_q.width,active_q.hfp,active_q.hs[11:0],active_q.hbp,
                     active_q.height,active_q.vfp,active_q.vs[11:0],active_q.vbp})
                    result_q.raster_epoch <= ~result_q.raster_epoch;
                active_q <= pending;
                arx_q <= arx_local;
                ary_q <= ary_local;
                state <= 1;
            end
            1: begin
                hdmi_height <= (active_q.vset && active_q.vset < active_q.height) ? active_q.vset : active_q.height;
                hdmi_width <= ((active_q.hset && active_q.hset < active_q.width) ? active_q.hset : active_q.width) << active_q.pixel_repeat;
                if (ary_q != 0) begin
                    ax <= arx_q[11:0]; ay <= ary_q[11:0]; axy <= arx_q[12] | ary_q[12];
                end else if (arx_q == 1) begin
                    ax <= active_q.arc1x[11:0]; ay <= active_q.arc1y[11:0]; axy <= active_q.arc1x[12] | active_q.arc1y[12];
                end else if (arx_q == 2) begin
                    ax <= active_q.arc2x[11:0]; ay <= active_q.arc2y[11:0]; axy <= active_q.arc2x[12] | active_q.arc2y[12];
                end else begin ax <= 0; ay <= 0; axy <= 0; end
                state <= 2;
            end
            2: begin
                if (active_q.lfb) begin
                    left_q <= active_q.lfb_hmin; right_q <= active_q.lfb_hmax;
                    top_q <= active_q.lfb_vmin; bottom_q <= active_q.lfb_vmax;
                    state <= 10;
                end else if (active_q.freescale || !ax || !ay) begin
                    wcalc <= hdmi_width; hcalc <= hdmi_height; state <= 8;
                end else if (axy) begin
                    wcalc <= ax; hcalc <= ay; state <= 8;
                end else begin
                    mul1 <= hdmi_height; mul2 <= ax; divisor <= ay;
                    mul_start <= 1; state <= 3;
                end
            end
            3: if (!mul_start && !mul_busy) begin wcalc <= mul_result[11:0]; state <= 4; end
            4: begin
                mul1 <= hdmi_width; mul2 <= ay; divisor <= ax;
                mul_start <= 1; state <= 5;
            end
            5: if (!mul_start && !mul_busy) begin hcalc <= mul_result[11:0]; state <= 8; end
            8: begin
                videow <= ((wcalc > hdmi_width) ? hdmi_width : wcalc) >> active_q.pixel_repeat;
                videoh <= (hcalc > hdmi_height) ? hdmi_height : hcalc;
                state <= 9;
            end
            9: begin
                left_q <= (active_q.width - videow) >> 1;
                right_q <= ((active_q.width - videow) >> 1) + videow - 1'd1;
                top_q <= (active_q.height - videoh) >> 1;
                bottom_q <= ((active_q.height - videoh) >> 1) + videoh - 1'd1;
                state <= 10;
            end
            10: begin
                result_q.mode <= active_q.mode;
                result_q.enable <= active_q.enable;
                result_q.vrr <= active_q.vrr;
                result_q.lfb <= active_q.lfb;
                result_q.htotal <= active_q.width + active_q.hfp + active_q.hbp + active_q.hs[11:0];
                result_q.hsstart <= active_q.width + active_q.hfp;
                result_q.hsend <= active_q.width + active_q.hfp + active_q.hs[11:0];
                result_q.hdisp <= active_q.width;
                result_q.hmin <= left_q; result_q.hmax <= right_q;
                result_q.vtotal <= active_q.height + active_q.vfp + active_q.vbp + active_q.vs[11:0];
                result_q.vsstart <= active_q.height + active_q.vfp;
                result_q.vsend <= active_q.height + active_q.vfp + active_q.vs[11:0];
                result_q.vdisp <= active_q.height;
                result_q.vmin <= top_q; result_q.vmax <= bottom_q;
                result_q.vrrmax <= active_q.height + active_q.vbp + active_q.vs[11:0] + 12'd1;
                result_q.hs_polarity <= active_q.hs[12]; result_q.vs_polarity <= active_q.vs[12];
                result_q.fb_enable <= active_q.fb_enable;
                result_q.fb_width <= active_q.fb_width; result_q.fb_height <= active_q.fb_height;
                result_q.fb_format <= active_q.fb_format; result_q.fb_base <= active_q.fb_base;
                result_q.fb_stride <= active_q.fb_stride;
                aspect_q <= {axy,ax,ay};
                state <= 11;
            end
            11: if (frame_ready) state <= 0;
            default: state <= 0;
        endcase
    end

    reg result_valid = 0, input_valid = 0, video_vs_q = 0;
    always @(posedge clk_video) begin
        video_vs_q <= video_vs;
        if (publish) result_valid <= 1;
        if (result_valid && (!input_valid || (video_vs_q && !video_vs))) begin
            input_mode <= result_q.mode;
            input_valid <= 1;
        end
    end
    reg applied_epoch_q = 0, applied_enable_q = 0;
    always @(posedge clk_hdmi) begin
        hdmi_vs_q <= hdmi_vs;
        output_retime <= 0;
        if (frame_update) begin
            output_retime <= (output_active_q.raster_epoch != applied_epoch_q) ||
                             (!applied_enable_q && output_active_q.enable);
            applied_epoch_q <= output_active_q.raster_epoch;
            applied_enable_q <= output_active_q.enable;
        end
    end
    assign output_update = frame_update;
    wire applied_epoch;
    assign {applied_epoch,output_mode,output_enable,output_vrr,output_lfb,
        htotal,hsstart,hsend,hdisp,hmin,hmax,vtotal,vsstart,vsend,vdisp,vmin,vmax,vrrmax,
        hs_polarity,vs_polarity,output_fb_enable,output_fb_width,output_fb_height,
        output_fb_format,output_fb_base,output_fb_stride} = output_active_q;
endmodule

// Acknowledge only after applying the packet at the selected frame boundary.
// No intermediate/latest-value capture may discard a raster epoch: the held
// packet and its epoch are consumed in order, including while clocks stop.
module at_scaler_frame_snapshot #(parameter WIDTH = 1) (
    input wire src_clk, src_send,
    input wire [WIDTH-1:0] src_data,
    output wire src_ready,
    input wire dst_clk, dst_accept,
    output reg [WIDTH-1:0] dst_data = 0,
    output reg dst_update = 0
);
    (* preserve *) reg [WIDTH-1:0] payload_q = 0;
    (* preserve *) reg req_q = 0, ack_q = 0;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON", preserve *)
    reg ack_meta = 0, ack_sync = 0;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON", preserve *)
    reg req_meta = 0, req_sync = 0;
    assign src_ready = req_q == ack_sync;
    always @(posedge src_clk) begin
        ack_meta <= ack_q; ack_sync <= ack_meta;
        if (src_send && src_ready) begin payload_q <= src_data; req_q <= ~req_q; end
    end
    always @(posedge dst_clk) begin
        req_meta <= req_q; req_sync <= req_meta;
        dst_update <= 0;
        if (req_sync != ack_q && dst_accept) begin
            dst_data <= payload_q;
            dst_update <= 1;
            ack_q <= req_sync;
        end
    end
endmodule
