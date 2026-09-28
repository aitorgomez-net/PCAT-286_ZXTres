`timescale 1ns/1ps

// HPS download sequencer for the normalized AT memory owner.
//
// The legacy pcat_rom_loader targets the XT chipset's serialized byte write
// protocol.  This block keeps the MiSTer ioctl contract at the edge and emits
// one retained 16-bit loader transaction per incoming WIDE word.  It is
// intentionally independent of the active XT top level until an AT profile
// selects it as the reset-time memory owner.

module spk286_at_hps_rom_loader (
    input  logic        clk,
    input  logic        reset,
    input  logic        sdram_initialized,
    input  logic        ioctl_download,
    input  logic [7:0]  ioctl_index,
    input  logic        ioctl_wr,
    input  logic [24:0] ioctl_addr,
    input  logic [15:0] ioctl_data,

    output logic        ioctl_wait,
    output logic        loader_valid,
    output logic        loader_write,
    output logic [23:0] loader_address,
    output logic [1:0]  loader_byte_enable,
    output logic [15:0] loader_data_out,
    input  logic        loader_accept,
    input  logic        loader_ready,

    output logic [2:0]  bios_protect_flag,
    output logic        main_rom_loaded,
    output logic        ega_rom_loaded,
    output logic        load_active,
    output logic        protocol_error
);

    localparam logic [1:0] TARGET_MAIN  = 2'd0;
    localparam logic [1:0] TARGET_EGA   = 2'd1;

    localparam logic [1:0] STATE_IDLE       = 2'd0;
    localparam logic [1:0] STATE_WAIT_ACCEPT = 2'd1;
    localparam logic [1:0] STATE_WAIT_READY  = 2'd2;

    logic [1:0]  state_q;
    logic [1:0]  target_q;
    logic [23:0] address_q;
    logic [15:0] data_q;
    logic        main_seen_q;
    logic        ega_seen_q;
    logic        ega_overflow_q;
    logic [1:0]  download_active;
    logic [1:0]  download_active_q;

    logic        select_main;
    logic        select_ega;
    logic        selected_download;
    logic        oversized_ega_write;
    logic [1:0]  selected_target;
    logic [23:0] selected_address;

    // File-start detection must not depend on ioctl_addr: HPS may still
    // present the previous file's final address when download rises.
    assign download_active[0] = ioctl_download && (ioctl_index[5:0] == 6'd0);
    assign download_active[1] = ioctl_download && (ioctl_index[5:0] == 6'd3);

    always_comb begin
        select_main = (ioctl_index[5:0] == 6'd0) &&
                      (ioctl_addr[24:16] == 9'b000000000);
        // The EGA option ROM occupies C0000-C7FFF so its image must fit
        // below the always-on UMB beginning at C8000.
        select_ega = (ioctl_index[5:0] == 6'd3) &&
                     (ioctl_addr[24:15] == 10'b0000000000) &&
                     !ioctl_addr[0];
        selected_download = ioctl_download &&
                            (select_main || select_ega);
        oversized_ega_write = ioctl_download && ioctl_wr &&
                              (ioctl_index[5:0] == 6'd3) &&
                              ((ioctl_addr[24:15] != 10'b0000000000) ||
                               ioctl_addr[0]);

        if (select_main) begin
            selected_target = TARGET_MAIN;
            selected_address = 24'h0F0000 + {8'h00, ioctl_addr[15:0]};
        end else if (select_ega) begin
            selected_target = TARGET_EGA;
            selected_address = 24'h0C0000 + {8'h00, ioctl_addr[15:0]};
        end else begin
            selected_target = TARGET_MAIN;
            selected_address = 24'h000000;
        end

        loader_valid      = (state_q != STATE_IDLE);
        loader_write      = 1'b1;
        loader_address    = address_q;
        loader_byte_enable = 2'b11;
        loader_data_out   = data_q;
        load_active       = loader_valid;

        // HPS must hold the current word while the loader is busy or while a
        // selected write waits for its first acceptance edge.
        ioctl_wait = !sdram_initialized || loader_valid ||
                     (selected_download && ioctl_wr);

        // ROMs are write-enabled only while an explicit download is active.
        // The AT memory decoder remains independently read-only at runtime.
        bios_protect_flag = (loader_valid || selected_download) ?
                            3'b000 : 3'b011;
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state_q          <= STATE_IDLE;
            target_q         <= TARGET_MAIN;
            address_q        <= 24'h000000;
            data_q           <= 16'h0000;
            main_seen_q      <= 1'b0;
            download_active_q <= 2'b00;
            ega_seen_q       <= 1'b0;
            ega_overflow_q   <= 1'b0;
            main_rom_loaded  <= 1'b0;
            ega_rom_loaded   <= 1'b0;
            protocol_error   <= 1'b0;
        end else if (!sdram_initialized) begin
            state_q          <= STATE_IDLE;
            main_seen_q      <= 1'b0;
            download_active_q <= 2'b00;
            ega_seen_q       <= 1'b0;
            ega_overflow_q   <= 1'b0;
            main_rom_loaded  <= 1'b0;
            ega_rom_loaded   <= 1'b0;
        end else begin
            download_active_q <= download_active;
            // Replacing a file invalidates its previous presence.
            // A word captured on this same edge sets seen again below.
            if (download_active[0] && !download_active_q[0]) begin
                main_seen_q <= 1'b0;
                main_rom_loaded <= 1'b0;
            end
            if (download_active[1] && !download_active_q[1]) begin
                ega_seen_q <= 1'b0;
                ega_rom_loaded <= 1'b0;
                ega_overflow_q <= 1'b0;
            end
            if (oversized_ega_write) begin
                ega_overflow_q <= 1'b1;
                protocol_error <= 1'b1;
            end
            if (state_q == STATE_IDLE && selected_download && ioctl_wr) begin
                state_q   <= STATE_WAIT_ACCEPT;
                target_q  <= selected_target;
                address_q <= selected_address;
                data_q    <= ioctl_data;
                if (selected_target == TARGET_MAIN)
                    main_seen_q <= 1'b1;
                else if (selected_target == TARGET_EGA)
                    ega_seen_q <= 1'b1;
            end else if (state_q == STATE_WAIT_ACCEPT) begin
                if (loader_accept)
                    state_q <= STATE_WAIT_READY;
            end else if (state_q == STATE_WAIT_READY) begin
                if (loader_ready) begin
                    state_q <= STATE_IDLE;
                    if (target_q == TARGET_MAIN && !ioctl_download)
                        main_rom_loaded <= 1'b1;
                    else if (target_q == TARGET_EGA && !ioctl_download &&
                             !ega_overflow_q)
                        ega_rom_loaded <= 1'b1;
                end
            end

            // Presence is latched only after the corresponding download has
            // ended AND the final accepted SDRAM write has completed. An
            // early HPS end-of-file cannot release CPU reset while it drains.
            if (!ioctl_download && (state_q == STATE_IDLE)) begin
                if (main_seen_q)
                    main_rom_loaded <= 1'b1;
                if (ega_seen_q && !ega_overflow_q)
                    ega_rom_loaded <= 1'b1;
            end

            if (loader_ready && state_q != STATE_WAIT_READY)
                protocol_error <= 1'b1;
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset) begin
            assert (!(loader_valid && loader_byte_enable == 2'b00))
                else $error("AT HPS loader emitted an empty byte lane mask");
            assert (!(loader_ready && state_q == STATE_IDLE))
                else $error("AT HPS loader completed while idle");
        end
    end
`endif

endmodule
