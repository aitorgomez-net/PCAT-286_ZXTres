// Hard disks for the PC/AT guest on boards without an HPS. The machine's IDE
// device (rtl/common/ide.v, the AO486 one) is served through its management
// window F000-F0FF the way MiSTer's Main serves it; the sectors come from
// two MiST block devices (user_io sd_*, units 0 and 1), which the DeMiSTify
// firmware fills from the VHD images chosen in the OSD. Commands are served
// only once both units have had a mount event, even an empty one.
//
// The window, as ide.v defines it (each access is one 16-bit word):
//   F000  write {error, block size in 256-word units}; also resets the FIFO index
//   F001  {sector, sector count}      F002  cylinder      F006  drive presence
//   F005  read {command, drive/head}; write {status and flags, drive/head}:
//         bit 14 DRDY, 12 DSC, 11 DRQ, 10 raise IRQ14, 9 last block, 8 ERR
//   F0FF  the sector FIFO, one word per access
// ide_request says what the machine wants: 6 reset, 4 a new command, 5 the
// next block of a transfer. Writing F005 answers it and clears the request.
//
// A VHD's last sector is read once when it is mounted: with the "conectix"
// cookie the geometry comes from the footer, else it is 16 heads and 63
// sectors per track. READ and WRITE SECTORS, IDENTIFY, INIT DEVICE
// PARAMETERS and the commands a BIOS and DOS use to wake a disk are served;
// every block is one sector (IDENTIFY reports no READ MULTIPLE).
//
// The management window is shared with zxtres_cmos_store.sv: this module asks
// with bus_req, owns the window while bus_use is set, and the CMOS store
// holds its scan meanwhile.
`timescale 1ns/1ps
module zxtres_ide_store #(
    parameter int TIMEOUT_CYCLES = 100_000_000      // 2 s at 50 MHz
) (
    input  logic        clk,
    input  logic        reset,

    // user_io block devices 0 and 1
    input  logic [1:0]  img_mounted,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0] img_size,      // bytes; the low nine bits are not used
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [1:0]  sd_rd,
    output logic [1:0]  sd_wr,
    output logic [31:0] sd_lba,
    input  logic [1:0]  sd_ack,
    input  logic [8:0]  sd_buff_addr,
    input  logic [7:0]  sd_dout,
    input  logic        sd_dout_strobe,
    output logic [7:0]  sd_din,

    // management window of the machine
    output logic        bus_req,
    input  logic        bus_grant,
    output logic        bus_use,
    output logic [15:0] mgmt_address,
    output logic [15:0] mgmt_writedata,
    output logic        mgmt_write,
    output logic        mgmt_read,
    input  logic [15:0] mgmt_readdata,
    input  logic [2:0]  ide_request,

    output logic [15:0] command_count     // commands served
);
    // ------------------------------------------------------------------
    // Drives
    // present_q: the geometry is known and commands may be served.
    // pres_out_q: what F006 announces, set as soon as an image is mounted,
    // so that a reset the machine already sees stays busy (0x80) rather than
    // reading as an empty bus while the geometry is fetched.
    logic [1:0]  seen_q = 2'b00, need_geo_q = 2'b00, present_q = 2'b00, pres_out_q = 2'b00;
    logic        pres_dirty_q = 1'b0;
    logic [31:0] size_q   [0:1];
    logic [31:0] total_q  [0:1];
    logic [15:0] cyl_q    [0:1];
    logic [4:0]  heads_q  [0:1];
    logic [7:0]  spt_q    [0:1];
    logic [4:0]  cheads_q [0:1];     // translation set by INIT DEVICE PARAMETERS
    logic [7:0]  cspt_q   [0:1];

    initial begin
        for (int u = 0; u < 2; u++) begin
            size_q[u] = '0; total_q[u] = '0; cyl_q[u] = '0; heads_q[u] = '0;
            spt_q[u] = '0; cheads_q[u] = '0; cspt_q[u] = '0;
        end
    end

    // ------------------------------------------------------------------
    // Sector buffer: one sector as 256 words, used in both directions
    logic [15:0] buf_mem [0:255];
    logic [15:0] buf_q;
    logic [7:0]  idx_q;
    logic [7:0]  lo_q;
    logic        addr0_q;

    typedef enum logic [6:0] {
        S_IDLE, S_ACQ, S_FIN,
        // geometry of a mounted image
        S_GEO_DONE, S_GEO_DIV, S_GEO_FIN, S_GEO_ABORT,
        // sector transfer with the controller
        S_SD_REQ, S_SD_XFER,
        // reset and presence
        S_RST0, S_RST1, S_RST2, S_RST3, S_RST4, S_RST5, S_RST6, S_PRES,
        // command fetch and decode
        S_C0, S_C1, S_C2, S_C3, S_C4, S_RESP0, S_RESP1,
        // CHS or LBA to a sector number
        S_ADDR0, S_ADDR1, S_ADDR2, S_ADDR_CHK,
        // IDENTIFY
        S_ID0, S_ID1, S_ID2, S_ID3, S_ID4, S_ID5,
        // read
        S_RD_NEXT, S_RD_SD, S_RD_PUSH0, S_RD_PUSH1, S_RD_PUSH2, S_RD_PUSH3, S_RD_FIN,
        // write
        S_WR_ACK0, S_WR_ACK1, S_WR_PULL0, S_WR_PULL1, S_WR_PULL2, S_WR_PULL3,
        S_WR_SD, S_WR_DONE0, S_WR_DONE1,
        // management window operation
        S_OP
    } state_t;
    state_t state_q = S_IDLE;
    state_t after_q = S_IDLE;           // where S_OP continues
    state_t svc_q   = S_IDLE;           // the service S_ACQ starts
    state_t sd_ret_q = S_IDLE;          // where S_SD_XFER continues

    // Window operation
    logic        op_wr_q;
    logic [15:0] op_addr_q, op_data_q, rd_q;
    logic [3:0]  op_cnt_q;

    // Block transfer with the controller
    logic        sd_req_q = 1'b0, sd_is_wr_q = 1'b0, sd_geo_q = 1'b0;
    logic        sd_unit_q = 1'b0;
    logic [31:0] sd_lba_q = '0;
    logic [26:0] wd_q = '0;

    // Command in progress
    logic        active_q = 1'b0;       // a transfer spans several blocks
    logic        is_write_q = 1'b0;
    logic        dsel_q = 1'b0;
    logic [7:0]  cmd_q, drv_q, sn_q, sc_q;
    logic [15:0] cyl_cmd_q;
    logic [8:0]  remain_q;
    logic [31:0] lba_q;
    logic [20:0] m1_q;
    logic [28:0] m2_q;
    logic [7:0]  resp_err_q, resp_stat_q, wr_stat_q;
    logic [3:0]  gap_q = 4'd0;
    logic [15:0] retry_q = 16'd0;
    logic [31:0] cap_q;

    // Geometry fetch
    logic        geo_u_q = 1'b0, cookie_ok_q = 1'b1;
    logic [15:0] gcyl_q;
    logic [7:0]  gheads_q, gspt_q;
    logic [31:0] div_rem_q;
    logic [15:0] div_cyl_q;
    logic [31:0] geo_total_q;

    assign bus_req = bus_use || (state_q == S_ACQ);

    // ------------------------------------------------------------------
    // IDENTIFY words of the selected drive
    localparam logic [8*20-1:0] SERIAL   = "PCAT286ZXTRES0000001";
    localparam logic [8*8-1:0]  FIRMWARE = "1.00    ";
    localparam logic [8*40-1:0] MODEL    = "PCAT-286 ZXTRES HARD DISK               ";

    function automatic logic [15:0] ident_word(input logic [7:0] i);
        logic [15:0] w;
        begin
            w = 16'h0000;
            case (i)
                8'd0:  w = 16'h0040;
                8'd1:  w = cyl_q[dsel_q];
                8'd3:  w = {11'd0, heads_q[dsel_q]};
                8'd6:  w = {8'd0, spt_q[dsel_q]};
                8'd49: w = 16'h0200;
                8'd53: w = 16'h0001;
                8'd54: w = cyl_q[dsel_q];
                8'd55: w = {11'd0, cheads_q[dsel_q]};
                8'd56: w = {8'd0, cspt_q[dsel_q]};
                8'd57: w = cap_q[15:0];
                8'd58: w = cap_q[31:16];
                8'd60: w = total_q[dsel_q][15:0];
                8'd61: w = total_q[dsel_q][31:16];
                8'd80: w = 16'h0004;
                default: begin
                    if (i >= 8'd10 && i <= 8'd19)
                        w = SERIAL[8*20-1 - 16*(int'(i) - 10) -: 16];
                    else if (i >= 8'd23 && i <= 8'd26)
                        w = FIRMWARE[8*8-1 - 16*(int'(i) - 23) -: 16];
                    else if (i >= 8'd27 && i <= 8'd46)
                        w = MODEL[8*40-1 - 16*(int'(i) - 27) -: 16];
                end
            endcase
            ident_word = w;
        end
    endfunction

    // ------------------------------------------------------------------
    // Sector buffer ports
    wire sd_busy_st  = (state_q == S_SD_REQ) || (state_q == S_SD_XFER);
    wire we_sd       = (state_q == S_SD_XFER) && !sd_is_wr_q && sd_dout_strobe && sd_buff_addr[0];
    wire we_fifo     = (state_q == S_WR_PULL2);
    wire buf_we      = we_sd || we_fifo;
    wire [7:0]  buf_waddr = we_sd ? sd_buff_addr[8:1] : idx_q;
    wire [15:0] buf_wdata = we_sd ? {sd_dout, lo_q} : rd_q;
    wire [7:0]  buf_raddr = (sd_busy_st && sd_is_wr_q) ? sd_buff_addr[8:1] : idx_q;

    always_ff @(posedge clk) begin
        if (buf_we) buf_mem[buf_waddr] <= buf_wdata;
        buf_q   <= buf_mem[buf_raddr];
        addr0_q <= sd_buff_addr[0];
        if (state_q == S_SD_XFER && sd_dout_strobe && !sd_buff_addr[0])
            lo_q <= sd_dout;
    end
    assign sd_din = addr0_q ? buf_q[15:8] : buf_q[7:0];

    // ------------------------------------------------------------------
    // Block-device request lines
    assign sd_rd  = (sd_req_q && !sd_is_wr_q) ? (2'b01 << sd_unit_q) : 2'b00;
    assign sd_wr  = (sd_req_q &&  sd_is_wr_q) ? (2'b01 << sd_unit_q) : 2'b00;
    assign sd_lba = sd_lba_q;
    wire   unit_ack = sd_ack[sd_unit_q];

    // ------------------------------------------------------------------
    // A window operation takes 11 clocks: the address and data settle for
    // five, the strobe lasts one, and the FIFO index and the read-back path
    // need four more to follow it.
`define OP_WR(A, D, NEXT) begin \
        op_wr_q <= 1'b1; op_addr_q <= (A); op_data_q <= (D); op_cnt_q <= 4'd0; \
        after_q <= (NEXT); state_q <= S_OP; end
`define OP_RD(A, NEXT) begin \
        op_wr_q <= 1'b0; op_addr_q <= (A); op_data_q <= 16'h0000; op_cnt_q <= 4'd0; \
        after_q <= (NEXT); state_q <= S_OP; end
    // A block transfer; RET is where it goes when the controller is done.
`define SD_GO(UNIT, LBA, WR, GEO, RET) begin \
        sd_unit_q <= (UNIT); sd_lba_q <= (LBA); sd_is_wr_q <= (WR); sd_geo_q <= (GEO); \
        sd_ret_q <= (RET); sd_req_q <= 1'b1; wd_q <= '0; state_q <= S_SD_REQ; end
    // Answer with an error and end the service.
`define FAIL(ERR, STAT) begin \
        resp_err_q <= (ERR); resp_stat_q <= (STAT); active_q <= 1'b0; state_q <= S_RESP0; end

    wire        all_ready   = (seen_q == 2'b11) && (need_geo_q == 2'b00);
    wire        sel_present = present_q[dsel_q];
    wire [3:0]  head_cmd    = drv_q[3:0];
    // Presence word of F006: update both drives, none has the HOB mode.
    wire [15:0] presence    = {8'h00, 1'b1, 2'b00, pres_out_q[1], 1'b1, 2'b00, pres_out_q[0]};

    always_ff @(posedge clk) begin
        mgmt_write <= 1'b0;
        mgmt_read  <= 1'b0;
        if (retry_q != 16'd0) retry_q <= retry_q - 16'd1;

        if (reset) begin
            state_q <= S_IDLE;
            bus_use <= 1'b0;
            sd_req_q <= 1'b0;
            mgmt_address <= 16'hF000;
            mgmt_writedata <= 16'h0000;
            active_q <= 1'b0;
            idx_q <= '0;
            gap_q <= '0;
            command_count <= '0;
            retry_q <= 16'd0;
        end else begin
            case (state_q)
                // ------------------------------------------------------
                S_IDLE: begin
                    if (pres_dirty_q) begin
                        svc_q <= S_PRES; state_q <= S_ACQ;
                    end else if (need_geo_q != 2'b00) begin
                        geo_u_q <= !need_geo_q[0];
                        cookie_ok_q <= 1'b1;
                        gcyl_q <= '0; gheads_q <= '0; gspt_q <= '0;
                        `SD_GO(!need_geo_q[0], size_q[!need_geo_q[0]] - 32'd1, 1'b0, 1'b1, S_GEO_DONE)
                    end else if (ide_request == 3'd6 && all_ready && retry_q == 16'd0) begin
                        svc_q <= S_RST0; state_q <= S_ACQ;
                    end else if (ide_request == 3'd4) begin
                        svc_q <= S_C0; state_q <= S_ACQ;
                    end else if (ide_request == 3'd5 && active_q) begin
                        svc_q <= is_write_q ? S_WR_PULL0 : S_RD_NEXT;
                        state_q <= S_ACQ;
                    end
                end

                S_ACQ: begin
                    if (bus_grant) begin
                        bus_use <= 1'b1;
                        state_q <= svc_q;
                    end
                end

                // A service is over: let ide_request follow the last write.
                S_FIN: begin
                    bus_use <= 1'b0;
                    gap_q <= gap_q + 4'd1;
                    if (gap_q == 4'd15) state_q <= S_IDLE;
                end

                // ------------------------------------------------------
                // Geometry: the VHD footer is the last sector
                S_GEO_DONE: begin
                    geo_total_q <= cookie_ok_q ? size_q[geo_u_q] - 32'd1 : size_q[geo_u_q];
                    if (cookie_ok_q && gheads_q != 8'd0 && gheads_q <= 8'd16 &&
                        gspt_q != 8'd0 && gspt_q <= 8'd63 && gcyl_q != 16'd0) begin
                        cyl_q[geo_u_q]   <= (gcyl_q > 16'd16383) ? 16'd16383 : gcyl_q;
                        heads_q[geo_u_q] <= gheads_q[4:0];
                        spt_q[geo_u_q]   <= gspt_q;
                        state_q <= S_GEO_FIN;
                    end else begin
                        heads_q[geo_u_q] <= 5'd16;
                        spt_q[geo_u_q]   <= 8'd63;
                        div_rem_q <= cookie_ok_q ? size_q[geo_u_q] - 32'd1 : size_q[geo_u_q];
                        div_cyl_q <= 16'd0;
                        state_q <= S_GEO_DIV;
                    end
                end

                // Cylinders of a disk without usable footer: total / 1008
                S_GEO_DIV: begin
                    if (div_rem_q >= 32'd1008 && div_cyl_q != 16'd16383) begin
                        div_rem_q <= div_rem_q - 32'd1008;
                        div_cyl_q <= div_cyl_q + 16'd1;
                    end else begin
                        cyl_q[geo_u_q] <= (div_cyl_q == 16'd0) ? 16'd1 : div_cyl_q;
                        state_q <= S_GEO_FIN;
                    end
                end

                S_GEO_FIN: begin
                    total_q[geo_u_q]   <= geo_total_q;
                    present_q[geo_u_q] <= (geo_total_q != 32'd0);
                    pres_out_q[geo_u_q] <= (geo_total_q != 32'd0);
                    cheads_q[geo_u_q]  <= heads_q[geo_u_q];
                    cspt_q[geo_u_q]    <= spt_q[geo_u_q];
                    need_geo_q[geo_u_q] <= 1'b0;
                    pres_dirty_q <= 1'b1;
                    state_q <= S_IDLE;
                end

                S_GEO_ABORT: begin
                    present_q[geo_u_q] <= 1'b0;
                    pres_out_q[geo_u_q] <= 1'b0;
                    need_geo_q[geo_u_q] <= 1'b0;
                    pres_dirty_q <= 1'b1;
                    state_q <= S_IDLE;
                end

                // ------------------------------------------------------
                // Sector transfer with the controller
                S_SD_REQ: begin
                    wd_q <= wd_q + 27'd1;
                    if (unit_ack) begin
                        sd_req_q <= 1'b0;
                        wd_q <= '0;
                        state_q <= S_SD_XFER;
                    end else if (wd_q >= 27'(TIMEOUT_CYCLES)) begin
                        sd_req_q <= 1'b0;
                        if (sd_geo_q) state_q <= S_GEO_ABORT;
                        else begin `FAIL(8'h04, 8'h55) end
                    end
                end

                S_SD_XFER: begin
                    wd_q <= wd_q + 27'd1;
                    if (sd_geo_q && sd_dout_strobe) begin
                        case (sd_buff_addr)
                            9'd0: if (sd_dout != "c") cookie_ok_q <= 1'b0;
                            9'd1: if (sd_dout != "o") cookie_ok_q <= 1'b0;
                            9'd2: if (sd_dout != "n") cookie_ok_q <= 1'b0;
                            9'd3: if (sd_dout != "e") cookie_ok_q <= 1'b0;
                            9'd4: if (sd_dout != "c") cookie_ok_q <= 1'b0;
                            9'd5: if (sd_dout != "t") cookie_ok_q <= 1'b0;
                            9'd6: if (sd_dout != "i") cookie_ok_q <= 1'b0;
                            9'd7: if (sd_dout != "x") cookie_ok_q <= 1'b0;
                            9'd56: gcyl_q[15:8] <= sd_dout;
                            9'd57: gcyl_q[7:0]  <= sd_dout;
                            9'd58: gheads_q <= sd_dout;
                            9'd59: gspt_q <= sd_dout;
                            default: ;
                        endcase
                    end
                    if (!unit_ack) begin
                        state_q <= sd_ret_q;
                    end else if (wd_q >= 27'(TIMEOUT_CYCLES)) begin
                        if (sd_geo_q) state_q <= S_GEO_ABORT;
                        else begin `FAIL(8'h04, 8'h55) end
                    end
                end

                // ------------------------------------------------------
                // Window operation
                S_OP: begin
                    op_cnt_q <= op_cnt_q + 4'd1;
                    case (op_cnt_q)
                        4'd0: begin
                            mgmt_address <= op_addr_q;
                            mgmt_writedata <= op_data_q;
                        end
                        4'd5: begin
                            if (op_wr_q) mgmt_write <= 1'b1;
                            else         mgmt_read  <= 1'b1;
                        end
                        4'd6: rd_q <= mgmt_readdata;
                        4'd10: state_q <= after_q;
                        default: ;
                    endcase
                end

                // ------------------------------------------------------
                // Reset: presence, the ATA signature, then release BSY
                S_RST0: begin
                    pres_dirty_q <= 1'b0;
                    active_q <= 1'b0;
                    for (int u = 0; u < 2; u++) begin
                        cheads_q[u] <= heads_q[u];
                        cspt_q[u]   <= spt_q[u];
                    end
                    `OP_WR(16'hF006, presence, S_RST1)
                end
                S_RST1: `OP_WR(16'hF000, 16'h0100, S_RST2)
                S_RST2: `OP_WR(16'hF001, 16'h0101, S_RST3)
                S_RST3: `OP_WR(16'hF002, 16'h0000, S_RST4)
                S_RST4: `OP_WR(16'hF003, 16'h0000, S_RST5)
                S_RST5: `OP_WR(16'hF004, 16'h0000, S_RST6)
                S_RST6: begin
                    retry_q <= 16'd65535;
                    `OP_WR(16'hF005, 16'h50A0, S_FIN)
                end

                S_PRES: begin
                    pres_dirty_q <= 1'b0;
                    `OP_WR(16'hF006, presence, S_FIN)
                end

                // ------------------------------------------------------
                // A command: cmd and drive/head, sector and count, cylinder
                S_C0: `OP_RD(16'hF005, S_C1)
                S_C1: begin
                    cmd_q <= rd_q[15:8];
                    drv_q <= rd_q[7:0];
                    dsel_q <= rd_q[4];
                    `OP_RD(16'hF001, S_C2)
                end
                S_C2: begin
                    sn_q <= rd_q[15:8];
                    sc_q <= rd_q[7:0];
                    `OP_RD(16'hF002, S_C3)
                end
                S_C3: begin
                    cyl_cmd_q <= rd_q;
                    command_count <= command_count + 16'd1;
                    state_q <= S_C4;
                end

                S_C4: begin
                    resp_err_q <= 8'h00;
                    resp_stat_q <= 8'h54;                   // DRDY DSC, IRQ14
                    remain_q <= (sc_q == 8'd0) ? 9'd256 : {1'b0, sc_q};
                    if (!sel_present) begin
                        resp_stat_q <= 8'h00;               // no device there
                        state_q <= S_RESP0;
                    end else begin
                        case (cmd_q)
                            8'h20, 8'h21: begin is_write_q <= 1'b0; state_q <= S_ADDR0; end
                            8'h30, 8'h31: begin is_write_q <= 1'b1; state_q <= S_ADDR0; end
                            8'hEC: state_q <= S_ID0;
                            8'h91: begin
                                cspt_q[dsel_q]   <= sc_q;
                                cheads_q[dsel_q] <= {1'b0, head_cmd} + 5'd1;
                                state_q <= S_RESP0;
                            end
                            8'h90: begin resp_err_q <= 8'h01; state_q <= S_RESP0; end
                            8'h40, 8'h41, 8'hEF, 8'hC6, 8'hE0, 8'hE1, 8'hE2, 8'hE3,
                            8'hE4, 8'hE5, 8'hE6, 8'hE7: state_q <= S_RESP0;
                            default: begin
                                if (cmd_q[7:4] == 4'h1 || cmd_q[7:4] == 4'h7)
                                    state_q <= S_RESP0;     // recalibrate, seek
                                else begin
                                    resp_err_q <= 8'h04;    // aborted
                                    resp_stat_q <= 8'h55;
                                    state_q <= S_RESP0;
                                end
                            end
                        endcase
                    end
                end

                // A plain answer: the error register, then status and flags
                S_RESP0: `OP_WR(16'hF000, {resp_err_q, 8'h00}, S_RESP1)
                S_RESP1: `OP_WR(16'hF005, {resp_stat_q, drv_q}, S_FIN)

                // ------------------------------------------------------
                // Where the command points: CHS translated, or LBA
                S_ADDR0: begin
                    if (drv_q[6]) begin
                        lba_q <= {4'h0, drv_q[3:0], cyl_cmd_q, sn_q};
                        state_q <= S_ADDR_CHK;
                    end else if (sn_q == 8'd0 || sn_q > cspt_q[dsel_q] ||
                                 {1'b0, head_cmd} >= cheads_q[dsel_q]) begin
                        `FAIL(8'h10, 8'h55)                 // sector not found
                    end else begin
                        m1_q <= cyl_cmd_q * cheads_q[dsel_q];
                        state_q <= S_ADDR1;
                    end
                end
                S_ADDR1: begin
                    m2_q <= (29'(m1_q) + 29'(head_cmd)) * 29'(cspt_q[dsel_q]);
                    state_q <= S_ADDR2;
                end
                S_ADDR2: begin
                    lba_q <= {3'd0, m2_q} + {24'd0, sn_q} - 32'd1;
                    state_q <= S_ADDR_CHK;
                end
                S_ADDR_CHK: begin
                    if (lba_q >= total_q[dsel_q]) begin
                        `FAIL(8'h10, 8'h55)
                    end else if (is_write_q) begin
                        state_q <= S_WR_ACK0;
                    end else begin
                        state_q <= S_RD_SD;
                    end
                end

                // ------------------------------------------------------
                // IDENTIFY DEVICE
                S_ID0: begin
                    m1_q <= cyl_q[dsel_q] * cheads_q[dsel_q];
                    state_q <= S_ID1;
                end
                S_ID1: begin
                    cap_q <= m1_q * cspt_q[dsel_q];
                    idx_q <= 8'd0;
                    state_q <= S_ID2;
                end
                S_ID2: `OP_WR(16'hF000, 16'h0001, S_ID3)
                S_ID3: `OP_WR(16'hF0FF, ident_word(idx_q), S_ID4)
                S_ID4: begin
                    idx_q <= idx_q + 8'd1;
                    if (idx_q == 8'd255) state_q <= S_ID5;
                    else                 state_q <= S_ID3;
                end
                S_ID5: `OP_WR(16'hF005, {8'h5E, drv_q}, S_FIN)

                // ------------------------------------------------------
                // READ SECTORS: one sector per block
                S_RD_NEXT: begin
                    remain_q <= remain_q - 9'd1;
                    lba_q <= lba_q + 32'd1;
                    state_q <= S_ADDR_CHK;
                end
                S_RD_SD: begin
                    active_q <= 1'b1;
                    `SD_GO(dsel_q, lba_q, 1'b0, 1'b0, S_RD_PUSH0)
                end
                S_RD_PUSH0: begin
                    idx_q <= 8'd0;
                    `OP_WR(16'hF000, 16'h0001, S_RD_PUSH1)
                end
                S_RD_PUSH1: state_q <= S_RD_PUSH2;            // the buffer read
                S_RD_PUSH2: `OP_WR(16'hF0FF, buf_q, S_RD_PUSH3)
                S_RD_PUSH3: begin
                    idx_q <= idx_q + 8'd1;
                    if (idx_q == 8'd255) state_q <= S_RD_FIN;
                    else                 state_q <= S_RD_PUSH1;
                end
                S_RD_FIN: begin
                    if (remain_q == 9'd1) active_q <= 1'b0;
                    `OP_WR(16'hF005, {(remain_q == 9'd1) ? 8'h5E : 8'h5C, drv_q}, S_FIN)
                end

                // ------------------------------------------------------
                // WRITE SECTORS: the data arrives after DRQ is up
                S_WR_ACK0: begin
                    active_q <= 1'b1;
                    wr_stat_q <= 8'h58;                       // DRDY DSC DRQ
                    `OP_WR(16'hF000, 16'h0001, S_WR_ACK1)
                end
                S_WR_ACK1: `OP_WR(16'hF005, {wr_stat_q, drv_q}, S_FIN)

                S_WR_PULL0: begin
                    idx_q <= 8'd0;
                    `OP_WR(16'hF000, 16'h0001, S_WR_PULL1)    // also zeroes the FIFO index
                end
                S_WR_PULL1: `OP_RD(16'hF0FF, S_WR_PULL2)
                S_WR_PULL2: state_q <= S_WR_PULL3;            // buffer write with rd_q
                S_WR_PULL3: begin
                    idx_q <= idx_q + 8'd1;
                    if (idx_q == 8'd255) state_q <= S_WR_SD;
                    else                 state_q <= S_WR_PULL1;
                end
                S_WR_SD: `SD_GO(dsel_q, lba_q, 1'b1, 1'b0, S_WR_DONE0)

                S_WR_DONE0: begin
                    if (remain_q == 9'd1) begin
                        active_q <= 1'b0;
                        resp_err_q <= 8'h00;
                        resp_stat_q <= 8'h54;                 // done, IRQ14
                        state_q <= S_RESP0;
                    end else begin
                        remain_q <= remain_q - 9'd1;
                        lba_q <= lba_q + 32'd1;
                        state_q <= S_WR_DONE1;
                    end
                end
                S_WR_DONE1: begin
                    if (lba_q >= total_q[dsel_q]) begin
                        `FAIL(8'h10, 8'h55)
                    end else begin
                        wr_stat_q <= 8'h5C;                   // next block: DRQ and IRQ14
                        `OP_WR(16'hF000, 16'h0001, S_WR_ACK1)
                    end
                end

                default: state_q <= S_IDLE;
            endcase
        end

        // Mount events outrank everything above.
        for (int u = 0; u < 2; u++) begin
            if (img_mounted[u]) begin
                seen_q[u] <= 1'b1;
                present_q[u] <= 1'b0;
                pres_out_q[u] <= (img_size[63:9] != 55'd0);
                size_q[u] <= img_size[40:9];
                need_geo_q[u] <= (img_size[63:9] != 55'd0);
                pres_dirty_q <= 1'b1;
            end
        end
    end
`undef OP_WR
`undef OP_RD
`undef SD_GO
`undef FAIL
endmodule
