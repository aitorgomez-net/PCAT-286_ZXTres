// Functional 80286-to-chipset bridge for the AT machine profile.
//
// This is a normalized machine-side boundary.  It deliberately does not
// model historical Ts/Tc timing or an 82288/82289 pin-level implementation.
// The CPU request is retained until a chipset command is accepted and the
// accepted beat reports READY (and read data, for reads). Aligned words use
// one x16 beat when the memory target permits it. Byte-wide targets still
// receive two beats; an already odd, single-lane CPU beat is never split again.
`timescale 1ns/1ps

module spk286_at_bus_bridge (
    input  logic         clk,
    input  logic         reset,

    input  logic         cpu_bus_valid,
    input  logic [23:0]  cpu_address,
    input  logic [15:0]  cpu_data_out,
    input  logic         cpu_data_oe,
    input  logic         cpu_bus_write,
    input  logic         cpu_bus_bhe_n,
    input  logic [3:0]   cpu_bus_status,
    input  logic         cpu_bus_lock,
    // Board address decode, sampled with the CPU request. I/O and INTA
    // always retain byte-wide sequencing regardless of this input.
    input  logic         cpu_memory_word_capable,
    output logic         cpu_ready,
    output logic [15:0]  cpu_data_in,

    // Normalized AT-side transaction record.  at_valid exposes the retained
    // metadata during address, command and wait phases.  The consumer may
    // decode the full cycle class before asserting at_command_valid/accept.
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
    output logic         protocol_error
);
`ifdef SPK286_P01_FAST_MEMORY_START
    localparam logic FAST_MEMORY_START = 1'b1;
`else
    localparam logic FAST_MEMORY_START = 1'b0;
`endif

    localparam logic [3:0] STATE_IDLE     = 4'd0;
    localparam logic [3:0] STATE_SNAPSHOT = 4'd1;
    localparam logic [3:0] STATE_DECODE   = 4'd2;
    localparam logic [3:0] STATE_ADDRESS  = 4'd3;
    localparam logic [3:0] STATE_COMMAND  = 4'd4;
    localparam logic [3:0] STATE_WAIT     = 4'd5;
    localparam logic [3:0] STATE_COMPLETE = 4'd6;

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
    logic        beat_high_q;
    logic [7:0]  read_low_byte_q;

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
    wire native_word_request = cpu_memory_word_capable &&
                               ((cpu_bus_status == 4'h5) ||
                                (cpu_bus_status == 4'h6) ||
                                (cpu_bus_status == 4'hD)) &&
                               !cpu_address[0] && !cpu_bus_bhe_n;

    logic [23:0] beat_address;
    logic [1:0]   beat_byte_enable;

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

    assign at_valid          = (state_q == STATE_ADDRESS) ||
                               (state_q == STATE_COMMAND) ||
                               (state_q == STATE_WAIT);
    assign at_command_valid  = (state_q == STATE_COMMAND);
    assign at_owner          = OWNER_CPU;
    assign at_cycle_class    = request_status_q;
    assign at_address        = beat_address;
    assign at_a0             = request_is_inta ? 1'b0 : beat_address[0];
    assign at_bhe_n          = request_is_inta ? 1'b1 : !beat_byte_enable[1];
    assign at_byte_enable    = beat_byte_enable;
    assign at_data_out       = request_native_word_q ? request_data_q :
                               beat_byte_enable[1] ?
                               {request_data_q[15:8], 8'h00} :
                               {8'h00, request_data_q[7:0]};
    assign at_data_oe        = at_valid && request_write_q &&
                               ((state_q == STATE_COMMAND) ||
                                (state_q == STATE_WAIT));
    assign at_write          = at_valid && request_write_q;
    assign at_io             = at_valid && request_is_io;
    assign at_inta           = at_valid && request_is_inta;
    assign at_code_fetch     = at_valid && request_is_code;
    // Keep LOCK asserted through the CPU completion interval.  The owner is
    // released only when the CPU has observed cpu_ready and the bridge returns
    // to IDLE on the following edge.
    assign at_lock           = (state_q != STATE_IDLE) && request_lock_q;
    assign at_accepted       = (state_q == STATE_COMMAND) && at_accept;
    assign at_completed      = completion_valid;
    assign at_response_valid = (state_q == STATE_COMPLETE);
    assign cpu_ready         = (state_q == STATE_COMPLETE);
    assign bridge_idle       = (state_q == STATE_IDLE);

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
            beat_high_q        <= 1'b0;
            read_low_byte_q    <= 8'd0;
            cpu_data_in        <= 16'd0;
            protocol_error     <= 1'b0;
        end else begin
            case (state_q)
                STATE_IDLE: begin
                    if (cpu_bus_valid) begin
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
                        beat_high_q          <= 1'b0;
                        read_low_byte_q      <= 8'd0;
                        cpu_data_in          <= 16'd0;
                        if (live_request_valid)
                            // P01 removes two bookkeeping-only states for
                            // decoded RAM/ROM. The complete request is already
                            // retained above; I/O, INTA, EGA and unmapped
                            // accesses preserve the reference sequence.
                            state_q <= fast_memory_request ? STATE_ADDRESS :
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
                                cpu_data_in <= {8'h00, at_read_data[7:0]};
                            else if (request_native_word_q)
                                cpu_data_in <= at_read_data;
                            else if (beat_byte_enable[1]) begin
                                if (request_two_beats_q)
                                    cpu_data_in <= {at_read_data[15:8],
                                                    read_low_byte_q};
                                else
                                    cpu_data_in <= {at_read_data[15:8], 8'h00};
                            end else begin
                                if (request_two_beats_q)
                                    read_low_byte_q <= at_read_data[7:0];
                                else
                                    cpu_data_in <= {8'h00, at_read_data[7:0]};
                            end
                        end

                        if (request_two_beats_q && !beat_high_q) begin
                            beat_high_q <= 1'b1;
                            state_q <= STATE_ADDRESS;
                        end else begin
                            state_q <= STATE_COMPLETE;
                        end
                    end
                end

                STATE_COMPLETE:
                    state_q <= STATE_IDLE;

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
endmodule
