// Normalized AT sound devices.
//
// This boundary carries the non-Sound-Blaster audio devices from the XT
// profile into the SPK286 AT bus: AdLib/OPL2, Creative Music System (C/MS)
// and the Tandy SN76489.  Each CPU byte transaction is accepted once and is
// held until the corresponding chip has absorbed it, so a slow Tandy write
// cannot be lost at the AT device router.
`timescale 1ns/1ps

`ifndef ENABLE_OPL2
`define ENABLE_OPL2 0
`endif
`ifndef ENABLE_CMS
`define ENABLE_CMS 0
`endif
`ifndef ENABLE_TANDY_AUDIO
`define ENABLE_TANDY_AUDIO 0
`endif

module spk286_at_sound (
    input  logic         clk,
    input  logic         reset,
    input  logic         warm_reset,
    input  logic [1:0]   opl2_io,
    input  logic         cms_en,
    input  logic         tandy_en,

    input  logic         request_valid,
    input  logic         request_command_valid,
    input  logic         request_write,
    input  logic         request_io,
    input  logic [23:0]  request_address,
    input  logic [1:0]   request_byte_enable,
    input  logic [15:0]  request_data_out,
    output logic         request_accept,
    output logic         request_ready,
    output logic [15:0]  request_read_data,
    output logic         request_read_data_valid,

    output logic signed [15:0] opl2_sound,
    output logic signed [15:0] cms_sound_l,
    output logic signed [15:0] cms_sound_r,
    output logic signed [10:0] tandy_sound,
    output logic [15:0] side_effect_count,
    output logic        protocol_error
);
    localparam logic [1:0] TARGET_NONE  = 2'd0;
    localparam logic [1:0] TARGET_OPL2  = 2'd1;
    localparam logic [1:0] TARGET_CMS   = 2'd2;
    localparam logic [1:0] TARGET_TANDY = 2'd3;

    logic       active_q;
    logic       write_q;
    logic       read_q;
    logic [1:0] target_q;
    logic [1:0] byte_enable_q;
    logic       address_a0_q;
    logic [7:0] data_out_q;
    logic [3:0] address_low_q;
    logic       tandy_started_q;
    logic       cms_started_q;
    logic [7:0] cms_det_q;

    logic       opl2_candidate;
    logic       cms_candidate;
    logic       tandy_candidate;
    logic       lane_valid;
    logic [1:0] request_target;
    logic [7:0] request_byte;

    wire opl2_388 = (request_address[15:0] == 16'h0388) ||
                    (request_address[15:0] == 16'h0389);
    wire opl2_228 = (request_address[15:0] == 16'h0228) ||
                    (request_address[15:0] == 16'h0229);

    always_comb begin
        // The OPL2 menu's first entry is AdLib at 388h. Its second entry is
        // the same chip at both 388h and the Sound-Blaster FM alias 228h;
        // no Sound-Blaster DSP, DMA or IRQ logic is present here.
        opl2_candidate = `ENABLE_OPL2 && request_valid &&
                         request_command_valid && request_io &&
                         (((opl2_io == 2'd0) && opl2_388) ||
                          ((opl2_io == 2'd1) && (opl2_388 || opl2_228)));
        // C/MS writes occupy 220h-227h; only 224h and 22Bh are readable
        // (the latter is the detection register). Keep the AT bus decode as
        // narrow as the source profile so unused ports remain unmapped.
        cms_candidate = `ENABLE_CMS && cms_en && request_valid &&
                        request_command_valid && request_io &&
                        (request_address[15:4] == 12'h022) &&
                        ((request_write && !request_address[3]) ||
                         (!request_write &&
                          ((request_address[3:0] == 4'h4) ||
                           (request_address[3:0] == 4'hB))));
        tandy_candidate = `ENABLE_TANDY_AUDIO && tandy_en && request_valid &&
                          request_command_valid && request_io &&
                          request_write &&
                          (request_address[15:4] == 12'h00C);

        request_target = TARGET_NONE;
        if (opl2_candidate)
            request_target = TARGET_OPL2;
        else if (cms_candidate)
            request_target = TARGET_CMS;
        else if (tandy_candidate)
            request_target = TARGET_TANDY;

        lane_valid = ((request_address[0] == 1'b0) &&
                      (request_byte_enable == 2'b01)) ||
                     ((request_address[0] == 1'b1) &&
                      (request_byte_enable == 2'b10));
        request_byte = request_byte_enable[1] ?
                       request_data_out[15:8] : request_data_out[7:0];
    end

    assign request_accept = !active_q && lane_valid &&
                            (request_target != TARGET_NONE);

    // OPL2 absorbs a byte on the first active clock. C/MS needs one setup
    // clock because its source model detects the falling edge of WR#. JT89
    // exposes a ready handshake and must first see CS go low before its
    // ready-high state is eligible to complete the transaction.
    wire tandy_ready_i;
    assign request_ready = active_q &&
                           ((target_q == TARGET_OPL2) ||
                            ((target_q == TARGET_CMS) &&
                             (!write_q || cms_started_q)) ||
                            ((target_q == TARGET_TANDY) &&
                             (tandy_started_q && tandy_ready_i)));

    wire [7:0] opl2_dout_i;
    wire signed [15:0] opl2_sound_i;
    wire [7:0] cms_sound_l_i;
    wire [7:0] cms_sound_r_i;
    wire [7:0] cms1_sound_l_i;
    wire [7:0] cms1_sound_r_i;
    wire signed [10:0] tandy_sound_i;

    wire active_opl2  = active_q && (target_q == TARGET_OPL2);
    wire active_cms   = active_q && (target_q == TARGET_CMS);
    wire active_tandy = active_q && (target_q == TARGET_TANDY);

    wire opl2_cs_n = ~active_opl2;
    wire opl2_wr_n = ~(active_opl2 && write_q);
    wire cms_wr    = active_cms && write_q && cms_started_q;
    wire cms_wr_n  = ~cms_wr;
    wire cms_chip0_cs_n = ~(cms_wr && !address_low_q[3] &&
                            (address_low_q[2:1] == 2'd0));
    wire cms_chip1_cs_n = ~(cms_wr && !address_low_q[3] &&
                            (address_low_q[2:1] == 2'd1));
    wire tandy_cs_n = ~active_tandy;
    wire tandy_wr_n = ~(active_tandy && write_q && tandy_started_q);

    wire [7:0] cms_read_byte = (address_low_q == 4'hB) ? cms_det_q : 8'h7F;
    wire [7:0] read_byte = (target_q == TARGET_OPL2) ? opl2_dout_i :
                           (target_q == TARGET_CMS)  ? cms_read_byte :
                           8'hFF;

    assign request_read_data = byte_enable_q[1] ?
                               {read_byte, 8'h00} :
                               {8'h00, read_byte};
    assign request_read_data_valid = request_ready && read_q;

    // The three devices share an exact 50 MHz fractional clock divider in the
    // source profile: 3.579545 MHz for OPL2/SN76489 and 7.159090 MHz for
    // C/MS. The one-clock enables are intentionally generated independently
    // of CPU request traffic.
    logic [31:0] phase_3579_q;
    logic [31:0] phase_7159_q;
    logic        clk_en_3579;
    logic        clk_en_7159;

    always_ff @(posedge clk) begin
        if (reset) begin
            phase_3579_q <= 32'd0;
            phase_7159_q <= 32'd0;
            clk_en_3579 <= 1'b0;
            clk_en_7159 <= 1'b0;
        end else begin
            if (phase_3579_q >= 32'd46420455) begin
                phase_3579_q <= phase_3579_q - 32'd46420455;
                clk_en_3579 <= 1'b1;
            end else begin
                phase_3579_q <= phase_3579_q + 32'd3579545;
                clk_en_3579 <= 1'b0;
            end
            if (phase_7159_q >= 32'd42840910) begin
                phase_7159_q <= phase_7159_q - 32'd42840910;
                clk_en_7159 <= 1'b1;
            end else begin
                phase_7159_q <= phase_7159_q + 32'd7159090;
                clk_en_7159 <= 1'b0;
            end
        end
    end

    generate
        if (`ENABLE_OPL2) begin : GEN_OPL2
            jtopl2 u_jtopl2 (
                .rst    (reset | warm_reset),
                .clk    (clk),
                .cen    (clk_en_3579),
                .din    (data_out_q),
                .dout   (opl2_dout_i),
                .addr   (address_a0_q),
                .cs_n   (opl2_cs_n),
                .wr_n   (opl2_wr_n),
                .irq_n  (),
                .snd    (opl2_sound_i),
                .sample ()
            );
        end else begin : GEN_NO_OPL2
            assign opl2_dout_i  = 8'hFF;
            assign opl2_sound_i = 16'sd0;
        end

        if (`ENABLE_TANDY_AUDIO) begin : GEN_TANDY
            jt89 u_sn76489 (
                .rst    (reset),
                .clk    (clk),
                .clk_en (clk_en_3579),
                .wr_n   (tandy_wr_n),
                .cs_n   (tandy_cs_n),
                .din    (data_out_q),
                .sound  (tandy_sound_i),
                .ready  (tandy_ready_i)
            );
        end else begin : GEN_NO_TANDY
            assign tandy_sound_i = 11'sd0;
            assign tandy_ready_i = 1'b1;
        end

        if (`ENABLE_CMS) begin : GEN_CMS
            saa1099 u_cms0 (
                .clk_sys (clk),
                .ce      (clk_en_7159),
                .rst_n   (~reset & cms_en),
                .cs_n    (cms_chip0_cs_n),
                .a0      (address_a0_q),
                .wr_n    (cms_wr_n),
                .din     (data_out_q),
                .out_l   (cms_sound_l_i),
                .out_r   (cms_sound_r_i)
            );
            saa1099 u_cms1 (
                .clk_sys (clk),
                .ce      (clk_en_7159),
                .rst_n   (~reset & cms_en),
                .cs_n    (cms_chip1_cs_n),
                .a0      (address_a0_q),
                .wr_n    (cms_wr_n),
                .din     (data_out_q),
                .out_l   (cms1_sound_l_i),
                .out_r   (cms1_sound_r_i)
            );
        end else begin : GEN_NO_CMS
            assign cms_sound_l_i = 8'h00;
            assign cms_sound_r_i = 8'h00;
            assign cms1_sound_l_i = 8'h00;
            assign cms1_sound_r_i = 8'h00;
        end
    endgenerate

    logic [8:0] cms_sum_l;
    logic [8:0] cms_sum_r;
    logic [15:0] cms_pre_l_q;
    logic [15:0] cms_pre_r_q;
    logic [15:0] cms_sound_l_q;
    logic [15:0] cms_sound_r_q;

    // The second C/MS output is intentionally kept separate above; its
    // channel values are combined here by instantiating the two chips with
    // explicit output wires.
    assign cms_sum_l = {1'b0, cms_sound_l_i} + {1'b0, cms1_sound_l_i};
    assign cms_sum_r = {1'b0, cms_sound_r_i} + {1'b0, cms1_sound_r_i};

    always_ff @(posedge clk) begin
        if (reset) begin
            cms_pre_l_q   <= 16'd0;
            cms_pre_r_q   <= 16'd0;
            cms_sound_l_q <= 16'd0;
            cms_sound_r_q <= 16'd0;
        end else if (`ENABLE_CMS) begin
            cms_pre_l_q   <= {2'b00, cms_sum_l, cms_sum_l[8:4]};
            cms_pre_r_q   <= {2'b00, cms_sum_r, cms_sum_r[8:4]};
            cms_sound_l_q <= $signed(cms_pre_l_q) >>> 1'd0;
            cms_sound_r_q <= $signed(cms_pre_r_q) >>> 1'd0;
        end else begin
            cms_pre_l_q   <= 16'd0;
            cms_pre_r_q   <= 16'd0;
            cms_sound_l_q <= 16'd0;
            cms_sound_r_q <= 16'd0;
        end
    end

    assign opl2_sound = (opl2_io == 2'd2) ? 16'sd0 : opl2_sound_i;
    assign cms_sound_l = cms_en ? $signed(cms_sound_l_q) : 16'sd0;
    assign cms_sound_r = cms_en ? $signed(cms_sound_r_q) : 16'sd0;
    assign tandy_sound = tandy_en ? tandy_sound_i : 11'sd0;

    assign side_effect_count = 16'd0;
    assign protocol_error = 1'b0;

    always_ff @(posedge clk) begin
        if (reset) begin
            active_q        <= 1'b0;
            write_q         <= 1'b0;
            read_q          <= 1'b0;
            target_q        <= TARGET_NONE;
            byte_enable_q   <= 2'b00;
            address_a0_q    <= 1'b0;
            data_out_q      <= 8'h00;
            address_low_q   <= 4'h0;
            tandy_started_q <= 1'b0;
            cms_started_q   <= 1'b0;
            cms_det_q       <= 8'h00;
        end else begin
            if (!active_q && request_accept) begin
                active_q        <= 1'b1;
                write_q         <= request_write;
                read_q          <= !request_write;
                target_q        <= request_target;
                byte_enable_q   <= request_byte_enable;
                address_a0_q    <= request_address[0];
                data_out_q      <= request_byte;
                address_low_q   <= request_address[3:0];
                tandy_started_q <= 1'b0;
                cms_started_q   <= 1'b0;
                if (request_write && cms_candidate &&
                    ((request_address[3:0] == 4'h6) ||
                     (request_address[3:0] == 4'h7)))
                    cms_det_q <= request_byte;
            end else if (active_q) begin
                if (target_q == TARGET_TANDY && !tandy_started_q)
                    tandy_started_q <= 1'b1;
                if (target_q == TARGET_CMS && !cms_started_q)
                    cms_started_q <= 1'b1;
                if (request_ready) begin
                    active_q        <= 1'b0;
                    target_q        <= TARGET_NONE;
                    tandy_started_q <= 1'b0;
                    cms_started_q   <= 1'b0;
                end
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset)
            assert (!(request_accept && !lane_valid))
                else $error("AT sound accepted an invalid byte lane");
    end
`endif
endmodule
