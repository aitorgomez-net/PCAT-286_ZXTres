// Floppy drives for the PC/AT guest on boards without an HPS. The machine's
// floppy controller (rtl/common/floppy.v) is served through its management
// window F200-F2FF the way MiSTer's Main serves it; the sectors come from two
// MiST block devices (user_io sd_*, units 3 and 4 of the guest), which the
// DeMiSTify firmware fills from the images chosen in the OSD.
//
// The window, as floppy.v defines it (one word per access; bit 7 of the
// address picks drive A or B for the media registers):
//   F2x0  write bit 0: media present        read {drive, sector[14:0]}
//   F2x1  bit 0: write protect (from the host; the OSD adds its own)
//   F2x2  cylinders       F2x3  sectors per track
//   F2x4  total sectors   F2x5  heads (1 or 2)
//   F20F  the sector FIFO, 512 bytes, one byte per access
// floppy_request says what the controller wants: bit 0 a sector to read
// (this module fills the FIFO), bit 1 a sector to write or format (this
// module empties the FIFO). F2x0 then says which sector of which drive.
//
// The geometry of a mounted image comes from its size: 160K to 2.88M, and
// the 1.68M DMF; a size in between is rounded up to the next format. An image
// of size zero is an eject.
//
// The management window is shared with the other masters through bus_req,
// bus_grant and bus_use, the way zxtres_ide_store.sv does it.
`timescale 1ns/1ps
module zxtres_fdd_store #(
    parameter int TIMEOUT_CYCLES = 100_000_000      // 2 s at 50 MHz
) (
    input  logic        clk,
    input  logic        reset,

    // user_io block devices for drive A and B
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
    input  logic [1:0]  floppy_request,

    output logic [15:0] sector_count      // sectors served
);
    // ------------------------------------------------------------------
    // Media: what each drive holds
    logic [1:0]  media_dirty_q = 2'b00;     // geometry still to be told
    logic [31:0] size_q   [0:1];            // 512-byte sectors in the image
    logic [7:0]  cyl_q    [0:1];
    logic [7:0]  spt_q    [0:1];
    logic [1:0]  heads_q  [0:1];
    logic [15:0] total_q  [0:1];
    logic        media_u_q = 1'b0;

    initial begin
        for (int u = 0; u < 2; u++) begin
            size_q[u] = '0; cyl_q[u] = '0; spt_q[u] = '0;
            heads_q[u] = '0; total_q[u] = '0;
        end
    end

    // The format an image size stands for: 160K 40/8/1, 180K 40/9/1,
    // 320K 40/8/2, 360K 40/9/2, 720K 80/9/2, 1.2M 80/15/2, 1.44M 80/18/2,
    // DMF 80/21/2, 2.88M 80/36/2. Sizes are in 512-byte sectors.
    function automatic logic [17:0] format_of(input logic [31:0] n);
        // {cylinders[7:0], sectors per track[7:0], heads[1:0]}
        begin
            if      (n <= 32'd320)  format_of = {8'd40, 8'd8,  2'd1};
            else if (n <= 32'd360)  format_of = {8'd40, 8'd9,  2'd1};
            else if (n <= 32'd640)  format_of = {8'd40, 8'd8,  2'd2};
            else if (n <= 32'd720)  format_of = {8'd40, 8'd9,  2'd2};
            else if (n <= 32'd1440) format_of = {8'd80, 8'd9,  2'd2};
            else if (n <= 32'd2400) format_of = {8'd80, 8'd15, 2'd2};
            else if (n <= 32'd2880) format_of = {8'd80, 8'd18, 2'd2};
            else if (n <= 32'd3360) format_of = {8'd80, 8'd21, 2'd2};
            else                    format_of = {8'd80, 8'd36, 2'd2};
        end
    endfunction

    // ------------------------------------------------------------------
    // Sector buffer: one sector as 512 bytes, used in both directions
    logic [7:0] buf_mem [0:511];
    logic [7:0] buf_q;
    logic [8:0] idx_q;

    typedef enum logic [5:0] {
        S_IDLE, S_ACQ, S_FIN,
        // sector transfer with the controller
        S_SD_REQ, S_SD_XFER,
        // management window operation
        S_OP,
        // media registers of a mounted image
        S_M0, S_M1, S_M2, S_M3, S_M4, S_M5, S_M6,
        // a request: which sector of which drive
        S_Q0, S_Q1,
        // read: the image to the controller's FIFO
        S_RD_SD, S_RD_P0, S_RD_P1, S_RD_P2, S_RD_P3,
        // write or format: the controller's FIFO to the image
        S_WR_P0, S_WR_P1, S_WR_P2, S_WR_P3, S_WR_SD
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
    logic        sd_req_q = 1'b0, sd_is_wr_q = 1'b0;
    logic        sd_unit_q = 1'b0;
    logic [31:0] sd_lba_q = '0;
    logic [26:0] wd_q = '0;

    // Request in progress
    logic        write_q = 1'b0;
    logic        unit_q = 1'b0;
    logic [14:0] sector_q = '0;
    logic [4:0]  gap_q = 5'd0;

    assign bus_req = bus_use || (state_q == S_ACQ);

    // ------------------------------------------------------------------
    // Sector buffer ports
    wire we_sd   = (state_q == S_SD_XFER) && !sd_is_wr_q && sd_dout_strobe;
    wire we_fifo = (state_q == S_WR_P2);
    wire sd_xfer = (state_q == S_SD_REQ) || (state_q == S_SD_XFER);
    wire [8:0] buf_raddr = (sd_xfer && sd_is_wr_q) ? sd_buff_addr : idx_q;

    always_ff @(posedge clk) begin
        if (we_sd)        buf_mem[sd_buff_addr] <= sd_dout;
        else if (we_fifo) buf_mem[idx_q]        <= rd_q[7:0];
        buf_q <= buf_mem[buf_raddr];
    end
    assign sd_din = buf_q;

    // ------------------------------------------------------------------
    // Block-device request lines
    assign sd_rd  = (sd_req_q && !sd_is_wr_q) ? (2'b01 << sd_unit_q) : 2'b00;
    assign sd_wr  = (sd_req_q &&  sd_is_wr_q) ? (2'b01 << sd_unit_q) : 2'b00;
    assign sd_lba = sd_lba_q;
    wire   unit_ack = sd_ack[sd_unit_q];

    // ------------------------------------------------------------------
    // A window operation takes 11 clocks, as in zxtres_ide_store.sv
`define OP_WR(A, D, NEXT) begin \
        op_wr_q <= 1'b1; op_addr_q <= (A); op_data_q <= (D); op_cnt_q <= 4'd0; \
        after_q <= (NEXT); state_q <= S_OP; end
`define OP_RD(A, NEXT) begin \
        op_wr_q <= 1'b0; op_addr_q <= (A); op_data_q <= 16'h0000; op_cnt_q <= 4'd0; \
        after_q <= (NEXT); state_q <= S_OP; end
    // A block transfer; RET is where it goes when the controller is done.
`define SD_GO(UNIT, LBA, WR, RET) begin \
        sd_unit_q <= (UNIT); sd_lba_q <= (LBA); sd_is_wr_q <= (WR); \
        sd_ret_q <= (RET); sd_req_q <= 1'b1; wd_q <= '0; state_q <= S_SD_REQ; end

    // Media registers of drive media_u_q: F2x0.. with bit 7 the drive
    wire [15:0] media_base = {8'hF2, media_u_q, 7'd0};
    wire [17:0] media_fmt  = format_of(size_q[media_u_q]);

    always_ff @(posedge clk) begin
        mgmt_write <= 1'b0;
        mgmt_read  <= 1'b0;

        if (reset) begin
            state_q <= S_IDLE;
            bus_use <= 1'b0;
            sd_req_q <= 1'b0;
            mgmt_address <= 16'hF200;
            mgmt_writedata <= 16'h0000;
            idx_q <= '0;
            gap_q <= '0;
            sector_count <= '0;
        end else begin
            case (state_q)
                // ------------------------------------------------------
                S_IDLE: begin
                    if (media_dirty_q != 2'b00) begin
                        media_u_q <= !media_dirty_q[0];
                        svc_q <= S_M0; state_q <= S_ACQ;
                    end else if (floppy_request[1]) begin
                        write_q <= 1'b1;
                        svc_q <= S_Q0; state_q <= S_ACQ;
                    end else if (floppy_request[0]) begin
                        write_q <= 1'b0;
                        svc_q <= S_Q0; state_q <= S_ACQ;
                    end
                end

                S_ACQ: begin
                    if (bus_grant) begin
                        bus_use <= 1'b1;
                        state_q <= svc_q;
                    end
                end

                // A service is over: let floppy_request follow the last access.
                S_FIN: begin
                    bus_use <= 1'b0;
                    gap_q <= gap_q + 5'd1;
                    if (gap_q == 5'd31) state_q <= S_IDLE;
                end

                // ------------------------------------------------------
                // Block transfer
                S_SD_REQ: begin
                    wd_q <= wd_q + 27'd1;
                    if (unit_ack) begin
                        sd_req_q <= 1'b0;
                        wd_q <= '0;
                        state_q <= S_SD_XFER;
                    end else if (wd_q >= 27'(TIMEOUT_CYCLES)) begin
                        sd_req_q <= 1'b0;
                        state_q <= sd_ret_q;    // the controller must be answered
                    end
                end

                S_SD_XFER: begin
                    wd_q <= wd_q + 27'd1;
                    if (!unit_ack || wd_q >= 27'(TIMEOUT_CYCLES))
                        state_q <= sd_ret_q;
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
                // Media registers: geometry first, then the presence bit,
                // so that the controller raises its media change last
                S_M0: begin
                    media_dirty_q[media_u_q] <= 1'b0;
                    if (size_q[media_u_q] == 32'd0) begin
                        total_q[media_u_q] <= 16'd0;
                        `OP_WR(media_base | 16'h0000, 16'h0000, S_FIN)      // eject
                    end else begin
                        cyl_q[media_u_q]   <= media_fmt[17:10];
                        spt_q[media_u_q]   <= media_fmt[9:2];
                        heads_q[media_u_q] <= media_fmt[1:0];
                        state_q <= S_M1;
                    end
                end
                S_M1: begin
                    total_q[media_u_q] <= cyl_q[media_u_q] * spt_q[media_u_q] *
                                          {14'd0, heads_q[media_u_q]};
                    state_q <= S_M2;
                end
                S_M2: `OP_WR(media_base | 16'h0002, {8'h00, cyl_q[media_u_q]}, S_M3)
                S_M3: `OP_WR(media_base | 16'h0003, {8'h00, spt_q[media_u_q]}, S_M4)
                S_M4: `OP_WR(media_base | 16'h0004, total_q[media_u_q], S_M5)
                S_M5: `OP_WR(media_base | 16'h0005, {14'd0, heads_q[media_u_q]}, S_M6)
                S_M6: `OP_WR(media_base | 16'h0000, 16'h0001, S_FIN)        // present

                // ------------------------------------------------------
                // A request: which sector of which drive
                S_Q0: `OP_RD(16'hF200, S_Q1)
                S_Q1: begin
                    unit_q   <= rd_q[15];
                    sector_q <= rd_q[14:0];
                    sector_count <= sector_count + 16'd1;
                    idx_q <= '0;
                    if (write_q) state_q <= S_WR_P0;
                    else         state_q <= S_RD_SD;
                end

                // ------------------------------------------------------
                // Read: the sector from the image, then 512 bytes into the FIFO
                S_RD_SD: `SD_GO(unit_q, {17'd0, sector_q}, 1'b0, S_RD_P0)
                S_RD_P0: begin
                    idx_q <= 9'd0;
                    state_q <= S_RD_P1;
                end
                S_RD_P1: state_q <= S_RD_P2;                 // the buffer read
                S_RD_P2: `OP_WR(16'hF20F, {8'h00, buf_q}, S_RD_P3)
                S_RD_P3: begin
                    idx_q <= idx_q + 9'd1;
                    if (idx_q == 9'd511) state_q <= S_FIN;
                    else                 state_q <= S_RD_P1;
                end

                // ------------------------------------------------------
                // Write or format: 512 bytes out of the FIFO, then the image
                S_WR_P0: `OP_RD(16'hF20F, S_WR_P1)
                S_WR_P1: state_q <= S_WR_P2;                 // rd_q is settled
                S_WR_P2: state_q <= S_WR_P3;                 // buffer write with rd_q
                S_WR_P3: begin
                    idx_q <= idx_q + 9'd1;
                    if (idx_q == 9'd511) state_q <= S_WR_SD;
                    else                 state_q <= S_WR_P0;
                end
                S_WR_SD: `SD_GO(unit_q, {17'd0, sector_q}, 1'b1, S_FIN)

                default: state_q <= S_IDLE;
            endcase
        end

        // Mount events outrank everything above.
        for (int u = 0; u < 2; u++) begin
            if (img_mounted[u]) begin
                size_q[u] <= img_size[40:9];
                media_dirty_q[u] <= 1'b1;
            end
        end
    end
`undef OP_WR
`undef OP_RD
`undef SD_GO
endmodule
