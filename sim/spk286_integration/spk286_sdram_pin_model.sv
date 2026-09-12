`timescale 1ns/1ps

// Pin-level functional model of the x16 SDR SDRAM geometry used by KFSDRAM,
// including the MiSTer module connection between address and byte-mask pins.
// Official board: Hardware_MiSTer/releases/sdram_xsds_3.0.pdf, sheet 1,
// U1A/U2A DQML (15) = A11, DQMH (39) = A12; same on SDRAM XS 2.2.
// https://github.com/MiSTer-devel/Hardware_MiSTer/tree/master/releases
// This is deliberately not a sign-off vendor timing model. It models BL1,
// CAS latency 2, finite DQ drive, read DQM latency 2 and write DQM latency 0.
// Micron 256Mb SDRAM datasheet, CAS Latency/Figure 8: a READ sampled at T0
// with CL2 starts driving after T1 and is valid for sampling at T2.
// https://people.eecs.berkeley.edu/~kubitron/courses/cs152-S04/handouts/256MSDRAM_G.pdf
// Same explicit CL2 definition in ISSI IS42/45VM16160M, Figure 6:
// https://www.issi.com/WW/pdf/42-45VM16160M.pdf
// The full pin address is decoded. Limited storage is an explicit assertion,
// never a modulo/truncated address that could conceal an aliasing error.
module spk286_sdram_pin_model #(
    // MiSTer XS/XSDS modules connect SDRAM DQM to FPGA A12/A11. Use 0
    // for modules wired to the dedicated DQMH/DQML pins instead.
    parameter bit DQM_FROM_ADDRESS = 1'b1,
    parameter integer MEM_WORDS = 1048576,
    parameter real T_AC_NS = 6.0,
    parameter real T_OH_NS = 3.0
) (
    input wire clk,
    input wire reset,
    input wire [12:0] address,
    input wire cke,
    input wire cs_n,
    input wire ras_n,
    input wire cas_n,
    input wire we_n,
    input wire [1:0] ba,
    input wire [15:0] dq_from_controller,
    input wire controller_dq_oe,
    input wire [1:0] dqm,
    output reg [15:0] dq_to_controller,
    output reg [1:0] dq_valid = 2'b00,
    output integer read_count = 0,
    output integer write_count = 0
);
    // The Verilator simulator is two-state and cannot delay tristate assignments. Poison
    // replaces Z there, while dq_valid remains the authoritative window.
`ifdef VERILATOR
    localparam [15:0] INVALID_DATA = 16'hDEAD;
`else
    localparam [15:0] INVALID_DATA = 16'hzzzz;
`endif
    initial dq_to_controller = INVALID_DATA;
    wire [1:0] chip_dqm = DQM_FROM_ADDRESS ? address[12:11] : dqm;
    reg [15:0] mem [0:MEM_WORDS-1];
    reg [12:0] open_row [0:3];
    reg [3:0] row_open = 4'b0000;
    reg mode_loaded = 1'b0;
    reg pending_read = 1'b0;
    reg [15:0] pending_data = 16'hxxxx;
    reg [1:0] dqm_q = 2'b11;
    reg [23:0] physical_word;
    reg [15:0] next_dq;
    integer bank;

    always @(posedge clk) begin
        if (reset) begin
            row_open = 4'b0000;
            mode_loaded = 1'b0;
            pending_read <= 1'b0;
            pending_data <= 16'hxxxx;
            dqm_q <= 2'b11;
            dq_to_controller <= INVALID_DATA;
            dq_valid <= 2'b00;
            read_count = 0;
            write_count = 0;
            for (bank = 0; bank < 4; bank = bank + 1)
                open_row[bank] = 13'h0000;
        end else if (cke) begin
            // Output beat one edge after CL2 READ, then release after tOH on
            // the following edge. Delays make both early and late captures
            // visible; retaining the last read word forever would hide them.
            if (pending_read) begin
                next_dq[7:0] = dqm_q[0] ? INVALID_DATA[7:0] : pending_data[7:0];
                next_dq[15:8] = dqm_q[1] ? INVALID_DATA[15:8] : pending_data[15:8];
                dq_to_controller <= #(T_AC_NS) next_dq;
                dq_valid <= #(T_AC_NS) ~dqm_q;
            end else begin
                dq_to_controller <= #(T_OH_NS) INVALID_DATA;
                dq_valid <= #(T_OH_NS) 2'b00;
            end
            pending_read <= 1'b0;
            dqm_q <= chip_dqm;

            if ((|dq_valid) && controller_dq_oe)
                $fatal(1, "SDRAM_PIN_MODEL bus contention");

            if (!cs_n) begin
                case ({ras_n, cas_n, we_n})
                    3'b011: begin // ACTIVE
                        if (row_open[ba])
                            $fatal(1, "SDRAM_PIN_MODEL ACTIVE on open bank %0d", ba);
                        open_row[ba] = address;
                        row_open[ba] = 1'b1;
                    end
                    3'b101, 3'b100: begin // READ or WRITE
                        if (!mode_loaded || !row_open[ba])
                            $fatal(1, "SDRAM_PIN_MODEL column without MRS/ACTIVE");
                        // A12/A11 are don't-care column inputs on this x16
                        // geometry; on MiSTer they also drive the DQM nets.
                        if (address[10:9] != 2'b00)
                            $fatal(1, "SDRAM_PIN_MODEL unsupported column/AP bits %h", address);
                        physical_word = {ba, open_row[ba], address[8:0]};
                        if (physical_word >= MEM_WORDS)
                            $fatal(1, "SDRAM_PIN_MODEL address %h outside explicit storage %0d", physical_word, MEM_WORDS);
                        if (we_n) begin
                            if (controller_dq_oe)
                                $fatal(1, "SDRAM_PIN_MODEL FPGA driving during READ");
                            pending_read <= 1'b1;
                            pending_data <= mem[physical_word];
                            read_count = read_count + 1;
                        end else begin
                            if (!controller_dq_oe)
                                $fatal(1, "SDRAM_PIN_MODEL missing FPGA write drive");
                            if (!chip_dqm[0]) mem[physical_word][7:0] = dq_from_controller[7:0];
                            if (!chip_dqm[1]) mem[physical_word][15:8] = dq_from_controller[15:8];
                            write_count = write_count + 1;
                        end
                    end
                    3'b010: begin // PRECHARGE
                        if (address[10]) row_open = 4'b0000;
                        else row_open[ba] = 1'b0;
                    end
                    3'b001: begin // AUTO REFRESH
                        if (row_open != 4'b0000)
                            $fatal(1, "SDRAM_PIN_MODEL refresh with open bank");
                    end
                    3'b000: begin // MODE REGISTER SET
                        if ((address[2:0] != 3'b000) ||
                            (address[6:4] != 3'b010) || address[3] ||
                            (address[8:7] != 2'b00))
                            $fatal(1, "SDRAM_PIN_MODEL requires sequential BL1/CL2, MRS=%h", address);
                        mode_loaded = 1'b1;
                    end
                    3'b111: begin end // NOP
                    default: $fatal(1, "SDRAM_PIN_MODEL unsupported command");
                endcase
            end
        end
    end
endmodule


