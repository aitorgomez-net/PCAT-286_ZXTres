`timescale 1ns/1ps

// Physical SDRAM owner for the normalized AT memory backend.
//
// The upstream spk286_at_mister_memory_port guarantees one serialized
// transaction.  This block turns that transaction into one KFSDRAM access and
// exposes the lower-level MiSTer SDRAM pins.  KFSDRAM owns its own SDRAM
// refresh cadence; an abstract AT refresh request is therefore acknowledged
// when the controller is idle, while enable_refresh remains asserted so the
// physical controller can issue its periodic refresh commands.
//
// The normalized address is a byte address.  KFSDRAM addresses physical
// 16-bit words, so the AT owner maps A >> 1 and selects the byte lane with
// DQM.  This keeps the 16-bit SDRAM geometry aligned with the AT bus while
// retaining the board's existing KFSDRAM wiring.

module spk286_at_mister_sdram_owner #(
    parameter logic        SDRAM_NO_REFRESH = 1'b0,
    parameter logic [15:0] SDRAM_INIT_WAIT  = 16'd10000,
    parameter logic [15:0] SDRAM_REFRESH_CYCLE = 16'd100,
    parameter logic [15:0] SDRAM_FORCE_REFRESH = 16'd400
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        request_valid,
    input  logic        request_command_valid,
    input  logic        request_owner_refresh,
    input  logic        request_write,
    input  logic        request_code_fetch,
    // P03 line fills use one owner transaction for four consecutive reads.
    // Existing clients leave this optional input open, which means one word.
    input  logic        request_burst,
    input  logic [3:0]  request_cycle_class,
    input  logic [24:0] request_address,
    input  logic [1:0]  request_byte_enable,
    input  logic [15:0] request_data_out,
    output logic        request_accept,
    output logic        request_ready,
    output logic [15:0] request_read_data,
    output logic        request_read_data_valid,
    output logic        physical_idle,
    output logic [7:0]  debug_state,
    output logic        protocol_error,

    output logic [12:0] sdram_address,
    output logic        sdram_cke,
    output logic        sdram_cs,
    output logic        sdram_ras,
    output logic        sdram_cas,
    output logic        sdram_we,
    output logic [1:0]  sdram_ba,
    input  logic [15:0] sdram_dq_in,
    output logic [15:0] sdram_dq_out,
    output logic        sdram_dq_io,
    output logic        sdram_ldqm,
    output logic        sdram_udqm
);

    logic        active_q;
    logic        issued_q;
    logic        owner_refresh_q;
    logic        write_q;
    logic [24:0] address_q;
    logic [1:0]  byte_enable_q;
    logic [15:0] data_out_q;
    logic        response_pending_q;
    logic [15:0] response_data_q;
    logic        response_data_valid_q;
    logic        burst_q;
    logic [2:0]  read_beat_count_q;

    logic [23:0] kf_address;
    logic [15:0] kf_data_in;
    logic [15:0] kf_data_out;
    logic        kf_write_request;
    logic        kf_read_request;
    logic        kf_write_flag;
    logic        kf_read_flag;
    logic        kf_refresh_mode;
    logic        kf_idle;
    logic        kf_dq_io;
    logic [15:0] kf_dq_out;

    assign debug_state = {active_q, write_q, response_pending_q,
                          response_data_valid_q, kf_idle, kf_write_flag,
                          kf_read_flag, kf_refresh_mode};

    logic        launch_request;
    logic        physical_write;
    logic [1:0]  physical_byte_enable;
    logic [8:0]  kf_access_num;

    // The machine has already resolved CPU aliases and the EMS RAM shift.
    // Backend FF0000h-FFFFFFh is RAM, not the CPU's high BIOS alias.
    assign physical_idle = kf_idle && !active_q;
    assign request_accept = !active_q && request_valid &&
                            request_command_valid && kf_idle &&
                            (request_byte_enable != 2'b00);
    assign launch_request = active_q && !issued_q && !owner_refresh_q && kf_idle;

    // An ordinary write starts KFSDRAM on its accepting edge. The first
    // registered ACTIVE command uses the accepted incoming address; later
    // column/data commands use the retained transaction. Completion still
    // follows the full write/recovery/precharge path. Reads and refresh
    // retain their registered launch, and no write is posted to the AT bus.
    logic write_admission;
    assign write_admission = request_accept && request_write &&
                             !request_owner_refresh;
    assign kf_write_request = (launch_request && write_q) || write_admission;
    assign kf_read_request  = launch_request && !write_q;

    // KFSDRAM presents read_flag/data_out at its internal sampling boundary.
    // Capture that pair first, then expose a stable response to the AT bus.
    // This prevents the CPU-facing ready/data path from depending on the
    // same-cycle combinational propagation of the SDRAM controller outputs.
    assign request_ready = active_q &&
                           (owner_refresh_q ? kf_idle :
                            (write_q ? (issued_q && kf_idle) : response_pending_q));
    assign request_read_data = response_data_q;
    assign request_read_data_valid = active_q && !owner_refresh_q &&
                                     !write_q && response_data_valid_q;

    assign kf_access_num = burst_q ? 9'd4 : 9'd1;

    // KFSDRAM is word-addressed while the AT boundary is byte-addressed.
    // Map the logical byte address to its physical 16-bit word with A >> 1;
    // DQM below then selects the requested low/high byte lane.  This is a
    // packed word layout.  The old {mapped_address[23:1], 1'b0} expression
    // aligned a byte address down and produced a sparse word layout; it was
    // not a left shift.  Loader and CPU share this mapper in either layout.
    // An idle inactive owner uses the live payload for immediate write
    // admission; launched commands use the retained record. Outside IDLE,
    // retain the address even after early read completion.
    assign kf_address = (kf_idle && !active_q)
                      ? request_address[24:1] : address_q[24:1];
    assign kf_data_in = data_out_q;

    always_comb begin
        physical_write       = 1'b0;
        physical_byte_enable = 2'b00;
        if (active_q) begin
            physical_write       = !owner_refresh_q && write_q;
            physical_byte_enable = byte_enable_q;
        end

        // DQM is active high.  Reads leave both lanes enabled; writes mask
        // only the byte lanes that were not requested.  Refresh and idle
        // cycles mask both lanes to avoid any accidental data drive.
        if (physical_write) begin
            sdram_ldqm = !physical_byte_enable[0];
            sdram_udqm = !physical_byte_enable[1];
        end else if (active_q && !owner_refresh_q) begin
            sdram_ldqm = 1'b0;
            sdram_udqm = 1'b0;
        end else begin
            sdram_ldqm = 1'b1;
            sdram_udqm = 1'b1;
        end
    end

    // MiSTer SDRAM XS/XSDS boards wire chip DQMH/DQML to FPGA A12/A11.
    // KFSDRAM does not generate those masks: its column command sets the
    // unused address bits to zero. Drive the same byte masks on both sets
    // of pins during READ/WRITE. ACTIVE must retain the full row address.
    // See Hardware_MiSTer/releases/sdram_xsds_3.0.pdf (U1A/U2A pins 15/39).
    assign sdram_address = (!kf_sdram_cs && kf_sdram_ras && !kf_sdram_cas)
                         ? {sdram_udqm, sdram_ldqm, kf_sdram_address[10:0]}
                         : kf_sdram_address;
    assign sdram_cke     = kf_sdram_cke;
    assign sdram_cs      = kf_sdram_cs;
    assign sdram_ras     = kf_sdram_ras;
    assign sdram_cas     = kf_sdram_cas;
    assign sdram_we      = kf_sdram_we;
    assign sdram_ba      = kf_sdram_ba;
    assign sdram_dq_out  = kf_dq_out;
    assign sdram_dq_io   = kf_dq_io;

    logic [12:0] kf_sdram_address;
    logic        kf_sdram_cke;
    logic        kf_sdram_cs;
    logic        kf_sdram_ras;
    logic        kf_sdram_cas;
    logic        kf_sdram_we;
    logic [1:0]  kf_sdram_ba;

    KFSDRAM #(
        .sdram_no_refresh     (SDRAM_NO_REFRESH),
        .sdram_init_wait      (SDRAM_INIT_WAIT),
        .sdram_refresh_cycle  (SDRAM_REFRESH_CYCLE),
        .sdram_force_refresh  (SDRAM_FORCE_REFRESH),
        .use_column_address_input(1'b1)
    ) u_KFSDRAM (
        .sdram_clock    (clk),
        .sdram_reset    (reset),
        .address        (kf_address),
        .access_num     (kf_access_num),
        // READ/WRITE cannot admit a new command: request_accept requires
        // KFSDRAM IDLE. Their column base is the retained address, so this
        // removes the late live-command mux without a new register/cycle.
        .column_address (address_q[9:1]),
        .data_in        (kf_data_in),
        .data_out       (kf_data_out),
        .write_request  (kf_write_request),
        .read_request   (kf_read_request),
        .enable_refresh (1'b1),
        .write_flag     (kf_write_flag),
        .read_flag      (kf_read_flag),
        .refresh_mode   (kf_refresh_mode),
        .idle           (kf_idle),
        .sdram_address  (kf_sdram_address),
        .sdram_cke      (kf_sdram_cke),
        .sdram_cs       (kf_sdram_cs),
        .sdram_ras      (kf_sdram_ras),
        .sdram_cas      (kf_sdram_cas),
        .sdram_we       (kf_sdram_we),
        .sdram_ba       (kf_sdram_ba),
        .sdram_dq_in    (sdram_dq_in),
        .sdram_dq_out   (kf_dq_out),
        .sdram_dq_io    (kf_dq_io)
    );

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            active_q       <= 1'b0;
            issued_q       <= 1'b0;
            owner_refresh_q <= 1'b0;
            write_q        <= 1'b0;
            address_q      <= 25'h0000000;
            byte_enable_q  <= 2'b00;
            data_out_q     <= 16'h0000;
            response_pending_q <= 1'b0;
            response_data_q <= 16'h0000;
            response_data_valid_q <= 1'b0;
            burst_q         <= 1'b0;
            read_beat_count_q <= 3'd0;
            protocol_error <= 1'b0;
        end else begin
            response_data_valid_q <= 1'b0;
            if (request_valid && request_command_valid &&
                (request_byte_enable == 2'b00))
                protocol_error <= 1'b1;

            // Sample payload while idle without the long admission enable.
            // The accepting edge captures the same fields; active_q then
            // freezes them until the accepted physical work has drained.
            if (!active_q) begin
                address_q       <= request_address;
                byte_enable_q   <= request_byte_enable;
                data_out_q      <= request_data_out;
                burst_q         <= (request_burst === 1'b1);
            end

            if (request_accept) begin
                active_q        <= 1'b1;
                issued_q        <= write_admission;
                owner_refresh_q <= request_owner_refresh;
                write_q         <= request_write;
                response_pending_q <= 1'b0;
                response_data_valid_q <= 1'b0;
                read_beat_count_q <= 3'd0;
            end else if (launch_request) begin
                issued_q <= 1'b1;
            end else if (active_q && issued_q && !owner_refresh_q && !write_q &&
                         kf_read_flag && !response_pending_q) begin
                response_data_q <= kf_data_out;
                response_data_valid_q <= 1'b1;
                read_beat_count_q <= read_beat_count_q + 3'd1;
                if (burst_q ? (read_beat_count_q == 3'd3) : 1'b1)
                    response_pending_q <= 1'b1;
            end else if (active_q && request_ready) begin
                active_q <= 1'b0;
                issued_q <= 1'b0;
                response_pending_q <= 1'b0;
                response_data_valid_q <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset) begin
            assert (!(request_ready && !active_q))
                else $error("AT SDRAM owner completed without an active request");
            assert (!(request_read_data_valid && write_q))
                else $error("AT SDRAM owner returned read data for a write");
            assert (burst_q || !request_read_data_valid || request_ready)
                else $error("AT SDRAM owner returned single-read data without ready");
        end
    end
`endif

endmodule
