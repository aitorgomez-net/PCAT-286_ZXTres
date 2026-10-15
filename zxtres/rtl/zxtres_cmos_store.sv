// CMOS persistence for the PC/AT guest on boards without an HPS: one MiST
// block device (user_io sd_*) holds a 512-byte file, and the RTC/CMOS is
// reached through its management window (F400-F47F,
// spk286_at_rtc_cmos.sv), as MiSTer's Main does.
//
// File layout: bytes 0-127 are the CMOS image (offset = CMOS index), bytes
// 128-135 the signature "PCATCMOS", byte 136 the version (1); the rest is
// zero. A file without the signature (a new, all-zero file) is not
// restored.
//
// When the image is mounted the sector is read and, when it is signed,
// CMOS 10h-7Fh are written back while `busy` holds the machine in reset.
// The clock and status registers (00h-0Fh) are neither restored nor
// watched: the board has no real-time clock, so the user sets the time,
// and software changes registers A/B (periodic interrupts), 0Eh and the
// shutdown byte 0Fh at run time, which would otherwise rewrite the card.
//
// Afterwards the module reads the CMOS continuously, one byte per clock.
// When 10h-7Fh differ from the last image read or written and have stayed
// unchanged for QUIET_CYCLES, the sector is written. The CMOS is read
// directly while the controller fetches the sector, so the file holds the
// values of that moment.
`timescale 1ns/1ps
module zxtres_cmos_store #(
    parameter int QUIET_CYCLES = 50_000_000    // 1 s at 50 MHz
) (
    input  logic        clk,
    input  logic        reset,

    // One user_io block device. sd_ack is this image's transfer window
    // (user_io sd_ack_x for its index).
    input  logic        img_mounted,
    input  logic [63:0] img_size,
    output logic        sd_rd,
    output logic        sd_wr,
    input  logic        sd_ack,
    input  logic [8:0]  sd_buff_addr,
    input  logic [7:0]  sd_dout,
    input  logic        sd_dout_strobe,
    output logic [7:0]  sd_din,

    // RTC/CMOS management window. mgmt_readdata follows mgmt_address
    // combinationally and has no side effects.
    output logic [15:0] mgmt_address,
    output logic [15:0] mgmt_writedata,
    output logic        mgmt_write,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [15:0] mgmt_readdata,     // CMOS bytes use bits 7:0
    /* verilator lint_on UNUSEDSIGNAL */

    output logic        busy,          // reading or restoring: hold the machine
    output logic        restored,      // the last mount restored a signed image
    output logic [15:0] save_count     // sectors written since configuration
);
    localparam logic [7:0] VERSION = 8'h01;
    localparam logic [6:0] FIRST_KEPT = 7'h10;

    typedef enum logic [2:0] {
        S_IDLE, S_READ_REQ, S_READ, S_RESTORE, S_SCAN, S_WRITE_REQ, S_WRITE
    } state_t;
    state_t state_q = S_IDLE;

    logic [7:0]  image_q [0:127];
    logic        signature_ok_q = 1'b0;
    logic [6:0]  index_q = '0;
    logic        scan_dirty_q = 1'b0;
    logic [15:0] scan_hash_q = '0;
    logic [15:0] last_hash_q = '0;
    logic [31:0] quiet_q = '0;

    initial restored = 1'b0;
    initial save_count = '0;

    function automatic logic [7:0] signature_byte(input logic [8:0] address);
        case (address)
            9'd128: signature_byte = "P";
            9'd129: signature_byte = "C";
            9'd130: signature_byte = "A";
            9'd131: signature_byte = "T";
            9'd132: signature_byte = "C";
            9'd133: signature_byte = "M";
            9'd134: signature_byte = "O";
            9'd135: signature_byte = "S";
            9'd136: signature_byte = VERSION;
            default: signature_byte = 8'h00;
        endcase
    endfunction

    // During the scan mgmt_address holds the byte under test, and its value
    // is on mgmt_readdata in the same clock.
    wire [6:0]  probe = mgmt_address[6:0];
    wire        probe_kept = (probe >= FIRST_KEPT);
    wire [7:0]  cmos_byte = mgmt_readdata[7:0];
    wire        probe_differs = probe_kept && (cmos_byte != image_q[probe]);
    wire [15:0] hash_next = probe_kept ? ({scan_hash_q[14:0], scan_hash_q[15]} ^ {8'h00, cmos_byte})
                                       : scan_hash_q;

    assign busy = (state_q == S_READ_REQ) || (state_q == S_READ) || (state_q == S_RESTORE);
    // The controller fetches sd_din by sd_buff_addr; mgmt_address follows it
    // one clock later, like a block RAM read.
    assign sd_din = (sd_buff_addr[8] || sd_buff_addr[7]) ? signature_byte(sd_buff_addr) : cmos_byte;

    always_ff @(posedge clk) begin
        mgmt_write <= 1'b0;
        if (reset) begin
            state_q <= S_IDLE;
            sd_rd <= 1'b0;
            sd_wr <= 1'b0;
            mgmt_address <= 16'hF400;
            mgmt_writedata <= 16'h0000;
            index_q <= '0;
        end else if (img_mounted) begin
            // A new mount (or an unmount, size 0) restarts from the file.
            sd_rd <= 1'b0;
            sd_wr <= 1'b0;
            restored <= 1'b0;
            signature_ok_q <= 1'b1;
            state_q <= (img_size >= 64'd512) ? S_READ_REQ : S_IDLE;
        end else begin
            case (state_q)
                S_IDLE: ;

                S_READ_REQ: begin
                    sd_rd <= 1'b1;
                    if (sd_ack) begin
                        sd_rd <= 1'b0;
                        state_q <= S_READ;
                    end
                end

                // sd_buff_addr is the address of the byte on sd_dout while
                // sd_dout_strobe is high.
                S_READ: begin
                    if (sd_dout_strobe) begin
                        if (!sd_buff_addr[8] && !sd_buff_addr[7])
                            image_q[sd_buff_addr[6:0]] <= sd_dout;
                        else if (sd_buff_addr <= 9'd136 &&
                                 sd_dout != signature_byte(sd_buff_addr))
                            signature_ok_q <= 1'b0;
                    end
                    if (!sd_ack) begin
                        index_q <= FIRST_KEPT;
                        state_q <= S_RESTORE;
                    end
                end

                // One management write per clock for 10h-7Fh.
                S_RESTORE: begin
                    if (signature_ok_q) begin
                        mgmt_address <= {9'b1111_0100_0, index_q};
                        mgmt_writedata <= {8'h00, image_q[index_q]};
                        mgmt_write <= 1'b1;
                    end
                    index_q <= index_q + 7'd1;
                    if (index_q == 7'h7F) begin
                        restored <= signature_ok_q;
                        state_q <= S_SCAN;
                        mgmt_address <= 16'hF400;
                        quiet_q <= '0;
                        scan_dirty_q <= 1'b0;
                        scan_hash_q <= '0;
                    end
                end

                S_SCAN: begin
                    mgmt_address <= {9'b1111_0100_0, probe + 7'd1};
                    if (quiet_q < QUIET_CYCLES)
                        quiet_q <= quiet_q + 32'd1;
                    if (probe != 7'h7F) begin
                        scan_dirty_q <= scan_dirty_q || probe_differs;
                        scan_hash_q <= hash_next;
                    end else begin
                        // End of a pass: a changed hash restarts the quiet
                        // period; a stable image that differs from the
                        // file is written.
                        if (hash_next != last_hash_q) begin
                            last_hash_q <= hash_next;
                            quiet_q <= '0;
                        end else if ((scan_dirty_q || probe_differs) && quiet_q >= QUIET_CYCLES) begin
                            state_q <= S_WRITE_REQ;
                        end
                        scan_dirty_q <= 1'b0;
                        scan_hash_q <= '0;
                    end
                end

                S_WRITE_REQ: begin
                    sd_wr <= 1'b1;
                    mgmt_address <= 16'hF400;
                    if (sd_ack) begin
                        sd_wr <= 1'b0;
                        state_q <= S_WRITE;
                    end
                end

                // The image keeps what was sent: each byte as it is read for
                // the controller.
                S_WRITE: begin
                    mgmt_address <= {9'b1111_0100_0, sd_buff_addr[6:0]};
                    if (!sd_buff_addr[8] && !sd_buff_addr[7] && probe == sd_buff_addr[6:0])
                        image_q[probe] <= cmos_byte;
                    if (!sd_ack) begin
                        save_count <= save_count + 16'd1;
                        state_q <= S_SCAN;
                        mgmt_address <= 16'hF400;
                        quiet_q <= '0;
                        scan_dirty_q <= 1'b0;
                        scan_hash_q <= '0;
                    end
                end

                default: state_q <= S_IDLE;
            endcase
        end
    end
endmodule
