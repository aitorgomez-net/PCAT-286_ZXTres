// Functional 80286-to-chipset bridge for the AT machine profile.
//
// This is a normalized machine-side boundary.  It deliberately does not
// model historical Ts/Tc timing or an 82288/82289 pin-level implementation.
// The CPU request is retained until a chipset command is accepted and the
// accepted beat reports READY (and read data, for reads). Aligned words use
// one x16 beat when the memory target permits it. Byte-wide targets still
// receive two beats; an already odd, single-lane CPU beat is never split again.
`timescale 1ns/1ps

module spk286_at_bus_bridge #(
    parameter logic COMPLETE_ON_CPU_SAMPLE = 1'b0
) (
    input  logic         clk,
    input  logic         reset,
    // Pulse in this clock domain on an edge at which the CPU can sample
    // READY. It is used only when the CPU runs from a related slower clock.
    input  logic         cpu_sample_edge,
    // Clock enables on the SAME 50 MHz fabric, never a divided clock.
    // Unconnected legacy fixtures retain the MAX transaction path.
    input  logic         timing_historical,
    input  logic         timing_cpu_boundary,
    output logic         timing_deadline_miss,

    input  logic         cpu_bus_valid,
    input  logic [23:0]  cpu_address,
    input  logic [15:0]  cpu_data_out,
    input  logic         cpu_data_oe,
    input  logic         cpu_bus_write,
    input  logic         cpu_bus_bhe_n,
    input  logic [3:0]   cpu_bus_status,
    input  logic         cpu_bus_lock,
    input  logic         memory_drain_pending,
    // Board address decode, sampled with the CPU request. Memory width and
    // selected ISA16 I/O width are separate so ordinary ISA peripherals
    // retain byte-wide sequencing.
    input  logic         cpu_memory_word_capable,
    // Selected I/O targets may advertise a native x16 transfer. This is
    // intentionally separate from the memory-width decode because most ISA
    // peripherals remain byte-wide.
    input  logic         cpu_io_word_capable,
    output logic         cpu_ready,
    output logic [15:0]  cpu_data_in,

    // Normalized AT-side transaction record. P06 exposes the initial memory
    // address while both ends capture it. Common-clock native memory can
    // accept its command on that edge; later COMMAND/WAIT use retained data.
    output logic         at_valid,
    output logic         at_command_valid,
    output logic [2:0]   at_owner,
    output logic [3:0]   at_cycle_class,
    output logic [23:0]  at_address,
    output logic         at_a0,
    output logic         at_bhe_n,
    output logic [1:0]   at_byte_enable,
    output logic [15:0]  at_data_out,
    output logic         at_data_oe,
    output logic         at_write,
    output logic         at_io,
    output logic         at_inta,
    output logic         at_code_fetch,
    output logic         at_lock,
    output logic         at_accepted,
    output logic         at_completed,
    output logic         at_response_valid,

    // The chipset owns the acceptance/completion edge.  at_ready while no
    // accepted command is pending is intentionally ignored.  Read completion
    // additionally requires at_read_data_valid so an idle/stale data bus can
    // never acknowledge a read.
    input  logic         at_accept,
    input  logic         at_ready,
    input  logic [15:0]  at_read_data,
    input  logic         at_read_data_valid,

    output logic         bridge_idle,
    output logic [3:0]   debug_state,
    // Retained transaction view: no new registers or stages.
    output logic         retained_io_command,
    output logic [23:0]  retained_io_address,
    output logic         retained_io_write,
    output logic [1:0]   retained_io_byte_enable,
    output logic [15:0]  retained_io_data_out,
    output logic         retained_io_data_oe,
    output logic         protocol_error
);
    localparam logic FAST_MEMORY_START = 1'b1;
    localparam logic EARLY_MEMORY_ADDRESS = 1'b1;

    localparam logic [3:0] STATE_IDLE     = 4'd0;
    localparam logic [3:0] STATE_SNAPSHOT = 4'd1;
    localparam logic [3:0] STATE_DECODE   = 4'd2;
    localparam logic [3:0] STATE_ADDRESS  = 4'd3;
    localparam logic [3:0] STATE_COMMAND  = 4'd4;
    localparam logic [3:0] STATE_WAIT     = 4'd5;
    localparam logic [3:0] STATE_COMPLETE = 4'd6;
    localparam logic [3:0] STATE_ALIGN    = 4'd7;

    // The owner encoding is shared by future arbitration records.  CPU is
    // the only owner this bridge can emit; DMA, refresh and loader arbitration
    // remain outside this CPU-facing block.
    localparam logic [2:0] OWNER_CPU = 3'd0;

    logic [3:0]  state_q;
    logic [23:0] request_address_q;
    logic [15:0] request_data_q;
    logic        request_write_q;
    logic [3:0]  request_status_q;
    logic        request_lock_q;
    logic        request_two_beats_q;
    logic        request_native_word_q;
    logic        request_native_memory_q;
    logic        beat_high_q;
    logic [7:0]  read_low_byte_q;
    logic        complete_sampled_q;
    logic [15:0] cpu_data_in_q;
    logic        timing_tc_q;
    logic        timing_active_q;
    logic        timing_admission_window_q;
    wire historical = timing_historical === 1'b1;
    wire timing_admit = !historical || timing_cpu_boundary || timing_admission_window_q;
    // Admission is the beginning of Ts. The following boundary begins Tc;
    // the next boundary is the earliest terminal READY sample (two clocks).
    wire timing_terminal = !historical ||
                           (timing_cpu_boundary && timing_active_q && timing_tc_q);

    logic request_status_valid;
    logic request_lane_valid;
    logic request_direction_valid;
    logic live_request_valid;
    logic request_is_io;
    logic request_is_inta;
    logic request_is_code;
    logic request_is_read;
    logic completion_valid;
    wire fast_memory_request = FAST_MEMORY_START &&
                               cpu_memory_word_capable &&
                               ((cpu_bus_status == 4'h5) ||
                                (cpu_bus_status == 4'h6) ||
                                (cpu_bus_status == 4'hD));
    wire memory_native_word_request = cpu_memory_word_capable &&
                                      ((cpu_bus_status == 4'h5) ||
                                       (cpu_bus_status == 4'h6) ||
                                       (cpu_bus_status == 4'hD));
    // Case equality makes an omitted legacy testbench connection behave as
    // the conservative byte-wide default instead of propagating X/Z into
    // the bridge's transaction-shape state.
    wire io_native_word_request = (cpu_io_word_capable === 1'b1) &&
                                  ((cpu_bus_status == 4'h9) ||
                                   (cpu_bus_status == 4'hA));
    wire native_word_request = (memory_native_word_request ||
                                io_native_word_request) &&
                               !cpu_address[0] && !cpu_bus_bhe_n;

    wire drain_pending = memory_drain_pending === 1'b1;
    wire drain_barrier = drain_pending &&
                         (cpu_bus_lock || !memory_native_word_request);

    logic [23:0] beat_address;
    logic [1:0]   beat_byte_enable;
    // Let the downstream memory owner capture its address record on the same
    // edge as this bridge. Only decoded x16 memory targets qualify. In the
    // common clock, command acceptance may share that edge; synchronous RAM
    // and all completions still use the retained accepted record afterwards.
    wire early_memory_address = EARLY_MEMORY_ADDRESS && !reset &&
                                (state_q == STATE_IDLE) && timing_admit && cpu_bus_valid &&
                                memory_native_word_request && live_request_valid && !drain_barrier;
    // Related slower CPU clocks keep the registered command sequence.
    wire early_memory_command = early_memory_address && !COMPLETE_ON_CPU_SAMPLE;
    wire [1:0] early_byte_enable = native_word_request ? 2'b11 :
                                  cpu_address[0] ? 2'b10 : 2'b01;
    wire [15:0] early_data = native_word_request ? cpu_data_out :
                             cpu_address[0] ? {cpu_data_out[15:8], 8'h00} :
                                              {8'h00, cpu_data_out[7:0]};

    always_comb begin
        // 0xF is passive and must not become a machine transaction merely
        // because bus_valid is asserted incorrectly.
        case (cpu_bus_status)
            4'h0, 4'h5, 4'h6, 4'h9, 4'hA, 4'hD:
                request_status_valid = 1'b1;
            default:
                request_status_valid = 1'b0;
        endcase

        // INTA is a command without ordinary A0/BHE lane semantics.  All
        // other classes require at least one selected byte lane.
        request_lane_valid = (cpu_bus_status == 4'h0) ||
                             !((cpu_address[0] == 1'b1) && cpu_bus_bhe_n);

        case (cpu_bus_status)
            4'h6, 4'hA:
                request_direction_valid = cpu_bus_write && cpu_data_oe;
            4'h0, 4'h5, 4'h9, 4'hD:
                request_direction_valid = !cpu_bus_write && !cpu_data_oe;
            default:
                request_direction_valid = 1'b0;
        endcase

        live_request_valid = request_status_valid && request_lane_valid &&
                             request_direction_valid;
    end

    assign request_is_io    = (request_status_q == 4'h9) ||
                              (request_status_q == 4'hA);
    assign request_is_inta  = (request_status_q == 4'h0);
    assign request_is_code  = (request_status_q == 4'hD);
    assign request_is_read  = !request_write_q;
    assign beat_address     = request_address_q +
                              (beat_high_q ? 24'd1 : 24'd0);

    always_comb begin
        if (request_is_inta)
            beat_byte_enable = 2'b00;
        else if (request_native_word_q)
            beat_byte_enable = 2'b11;
        else if (request_two_beats_q)
            beat_byte_enable = beat_high_q ? 2'b10 : 2'b01;
        else if (request_address_q[0])
            beat_byte_enable = 2'b10;
        else
            beat_byte_enable = 2'b01;
    end

    // INTA is the one read-like cycle whose first completion deliberately
    // carries no data.  The PIC owns that two-beat sequence; the CPU must
    // still observe READY for the first acknowledge so it can issue the
    // second one.  Ordinary reads continue to require explicit data-valid.
    assign completion_valid = (state_q == STATE_WAIT) && at_ready &&
                              (!request_is_read || request_is_inta ||
                               at_read_data_valid);

    // RAM/ROM responses already come from a retained backend transaction.
    // In the common clock domain, let the CPU consume that response on the
    // same edge as the bridge. Byte requests still select their retained
    // lane; split and peripheral cycles keep the registered completion path.
    // The divided CPU clock keeps its explicit READY alignment/hold interval.
    wire direct_memory_wait = !COMPLETE_ON_CPU_SAMPLE && !reset &&
                              request_native_memory_q && !request_two_beats_q &&
                              (state_q == STATE_WAIT);
    wire direct_memory_response = direct_memory_wait && completion_valid && timing_terminal;
    wire [15:0] direct_memory_data = request_native_word_q ? at_read_data :
                                     beat_byte_enable[1] ?
                                     {at_read_data[15:8], 8'h00} :
                                     {8'h00, at_read_data[7:0]};

    assign at_valid          = early_memory_address || (state_q == STATE_ADDRESS) ||
                               (state_q == STATE_COMMAND) ||
                               (state_q == STATE_WAIT);
    assign at_command_valid  = early_memory_command || (state_q == STATE_COMMAND);
    assign at_owner          = OWNER_CPU;
    assign at_cycle_class    = early_memory_address ? cpu_bus_status : request_status_q;
    assign at_address        = early_memory_address ? cpu_address : beat_address;
    assign at_a0             = early_memory_address ? cpu_address[0] : request_is_inta ? 1'b0 : beat_address[0];
    assign at_bhe_n          = early_memory_address ? !early_byte_enable[1] : request_is_inta ? 1'b1 : !beat_byte_enable[1];
    assign at_byte_enable    = early_memory_address ? early_byte_enable : beat_byte_enable;
    assign at_data_out       = early_memory_address ? early_data : request_native_word_q ? request_data_q :
                               beat_byte_enable[1] ?
                               {request_data_q[15:8], 8'h00} :
                               {8'h00, request_data_q[7:0]};
    assign at_data_oe        = early_memory_command ? cpu_data_oe :
                               at_valid && request_write_q &&
                               ((state_q == STATE_COMMAND) ||
                                (state_q == STATE_WAIT));
    assign at_write          = at_valid && (early_memory_address ? cpu_bus_write : request_write_q);
    assign at_io             = at_valid && !early_memory_address && request_is_io;
    assign at_inta           = at_valid && !early_memory_address && request_is_inta;
    assign at_code_fetch     = at_valid && (early_memory_address ? cpu_bus_status == 4'hD : request_is_code);
    // Keep LOCK asserted through the CPU completion interval.  The owner is
    // released only when the CPU has observed cpu_ready and the bridge returns
    // to IDLE on the following edge.
    assign at_lock           = early_memory_address ? cpu_bus_lock : (state_q != STATE_IDLE) && request_lock_q;
    assign at_accepted       = at_command_valid && at_accept;
    assign at_completed      = completion_valid;
    assign at_response_valid = ((state_q == STATE_COMPLETE) && timing_terminal) || direct_memory_response;
    assign cpu_ready         = at_response_valid;
    // This is a fabric/backend deadline miss, NOT an external board READY
    // wait state. It must never be used to infer a motherboard wait setting.
    assign timing_deadline_miss = !reset && historical && timing_terminal &&
                                  state_q != STATE_IDLE && !cpu_ready;
    // Select the retained lane path independently of READY/data-valid. The
    // CPU consumes it only with cpu_ready, keeping completion qualification
    // out of the 16-bit response-data mux.
    assign cpu_data_in       = direct_memory_wait && request_is_read ?
                               direct_memory_data : cpu_data_in_q;
    assign bridge_idle       = (state_q == STATE_IDLE) && !early_memory_address && !drain_pending;
    assign debug_state       = state_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q             <= STATE_IDLE;
            request_address_q  <= 24'd0;
            request_data_q     <= 16'd0;
            request_write_q    <= 1'b0;
            request_status_q   <= 4'hF;
            request_lock_q     <= 1'b0;
            request_two_beats_q <= 1'b0;
            request_native_word_q <= 1'b0;
            request_native_memory_q <= 1'b0;
            beat_high_q        <= 1'b0;
            read_low_byte_q    <= 8'd0;
            complete_sampled_q <= 1'b0;
            cpu_data_in_q      <= 16'd0;
            timing_tc_q        <= 1'b0;
            timing_active_q    <= 1'b0;
            timing_admission_window_q <= 1'b0;
            protocol_error     <= 1'b0;
        end else begin
            if (timing_cpu_boundary || !historical)
                timing_admission_window_q <= 1'b0;
            if (historical && timing_active_q && timing_cpu_boundary)
                timing_tc_q <= 1'b1;
            if (cpu_ready) begin
                timing_active_q <= 1'b0;
                timing_tc_q <= 1'b0;
                // A level-held BIU presents the NEXT request after this edge.
                // Admit it on a subsequent fabric edge in this same virtual
                // interval, never by replaying the just-completed request.
                timing_admission_window_q <= historical;
            end
            if (state_q != STATE_COMPLETE)
                complete_sampled_q <= 1'b0;
            case (state_q)
                STATE_IDLE: begin
                    if (cpu_bus_valid && timing_admit && !drain_barrier) begin
                        timing_active_q <= historical;
                        timing_tc_q <= 1'b0;
                        timing_admission_window_q <= 1'b0;
                        // Snapshot is performed once per request.  No edge or
                        // payload comparison is used as a delimiter, so an
                        // identical request held back-to-back is accepted.
                        request_address_q    <= cpu_address;
                        request_data_q       <= cpu_data_out;
                        request_write_q      <= cpu_bus_write;
                        request_status_q     <= cpu_bus_status;
                        request_lock_q       <= cpu_bus_lock && live_request_valid;
                        request_two_beats_q  <= live_request_valid &&
                                                !native_word_request &&
                                                (cpu_bus_status != 4'h0) &&
                                                !cpu_address[0] &&
                                                !cpu_bus_bhe_n;
                        request_native_word_q <= live_request_valid &&
                                                 native_word_request;
                        request_native_memory_q <= live_request_valid &&
                                                   memory_native_word_request;
                        beat_high_q          <= 1'b0;
                        read_low_byte_q      <= 8'd0;
                         cpu_data_in_q        <= 16'd0;
                        if (live_request_valid)
                            // P01 removes two bookkeeping-only states for
                            // decoded RAM/ROM. The complete request is already
                            // retained above; I/O, INTA, EGA and unmapped
                            // accesses preserve the reference sequence.
                            state_q <= early_memory_command && at_accept ? STATE_WAIT :
                                       early_memory_address ? STATE_COMMAND :
                                       fast_memory_request ? STATE_ADDRESS :
                                       STATE_SNAPSHOT;
                        else begin
                            protocol_error <= 1'b1;
                            state_q <= STATE_COMPLETE;
                        end
                    end
                end

                STATE_SNAPSHOT:
                    state_q <= STATE_DECODE;

                STATE_DECODE:
                    state_q <= STATE_ADDRESS;

                STATE_ADDRESS:
                    state_q <= STATE_COMMAND;

                STATE_COMMAND: begin
                    // at_accept is the only command acceptance edge.  A
                    // permanently high at_ready cannot complete a command
                    // which has not reached this accepted state.
                    if (at_accept)
                        state_q <= STATE_WAIT;
                end

                STATE_WAIT: begin
                    if (completion_valid) begin
                        if (request_is_read) begin
                            if (request_is_inta)
                                cpu_data_in_q <= {8'h00, at_read_data[7:0]};
                            else if (request_native_word_q)
                                cpu_data_in_q <= at_read_data;
                            else if (beat_byte_enable[1]) begin
                                if (request_two_beats_q)
                                    cpu_data_in_q <= {at_read_data[15:8],
                                                    read_low_byte_q};
                                else
                                    cpu_data_in_q <= {at_read_data[15:8], 8'h00};
                            end else begin
                                if (request_two_beats_q)
                                    read_low_byte_q <= at_read_data[7:0];
                                else
                                    cpu_data_in_q <= {8'h00, at_read_data[7:0]};
                            end
                        end

                        if (request_two_beats_q && !beat_high_q) begin
                            beat_high_q <= 1'b1;
                            state_q <= STATE_ADDRESS;
                        end else if (direct_memory_response) begin
                            // READY is sampled now. The BIU presents its next
                            // request after this edge, so only IDLE may capture
                            // it on the next edge; recapturing here would replay
                            // the request that just completed.
                            state_q <= STATE_IDLE;
                        end else begin
                            // Never launch READY on the same parent edge that
                            // launches the divided CPU clock. Align it to the
                            // intervening 50 MHz edge so setup is unambiguous.
                            state_q <= COMPLETE_ON_CPU_SAMPLE && cpu_sample_edge ?
                                       STATE_ALIGN : STATE_COMPLETE;
                        end
                    end
                end

                STATE_ALIGN:
                    state_q <= STATE_COMPLETE;

                STATE_COMPLETE: begin
                    // A debug build may run the CPU from a related /2 clock.
                    // Keep READY stable through a CPU sampling edge, then
                    // release it on the following 50 MHz edge. This provides
                    // half a CPU cycle of hold time and avoids a second READY
                    // sample. The CPU may chain cycles without dropping valid,
                    // so bus_valid cannot acknowledge this state.
                    if (historical) begin
                        if (timing_terminal)
                            state_q <= STATE_IDLE;
                    end else if (!COMPLETE_ON_CPU_SAMPLE)
                        state_q <= STATE_IDLE;
                    else if (!complete_sampled_q && cpu_sample_edge)
                        complete_sampled_q <= 1'b1;
                    else if (complete_sampled_q && !cpu_sample_edge) begin
                        complete_sampled_q <= 1'b0;
                        state_q <= STATE_IDLE;
                    end
                end

                default: begin
                    state_q <= STATE_IDLE;
                    protocol_error <= 1'b1;
                end
            endcase
        end
    end

`ifndef SYNTHESIS
    // These checks are intentionally local to the normalized boundary.  They
    // catch the two most damaging integration mistakes without making a
    // historical electrical-timing claim.
    always_ff @(posedge clk) begin
        if (!reset) begin
            assert (!(at_accepted && !at_command_valid))
                else $error("AT bridge accepted outside COMMAND phase");
            assert (!(at_completed && !at_valid))
                else $error("AT bridge completed outside an active beat");
            assert (!(at_data_oe && !at_write))
                else $error("AT bridge drove data for a non-write");
        end
    end
`endif
    assign retained_io_command = (state_q == STATE_COMMAND) && request_is_io;
    assign retained_io_address = beat_address;
    assign retained_io_write = request_write_q;
    assign retained_io_byte_enable = beat_byte_enable;
    assign retained_io_data_out = request_native_word_q ? request_data_q :
                                  beat_byte_enable[1] ?
                                  {request_data_q[15:8], 8'h00} :
                                  {8'h00, request_data_q[7:0]};
    assign retained_io_data_oe = request_write_q &&
                                 ((state_q == STATE_COMMAND) || (state_q == STATE_WAIT));

endmodule
