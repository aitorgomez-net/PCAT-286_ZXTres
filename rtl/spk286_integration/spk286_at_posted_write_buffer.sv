`timescale 1ns/1ps

// One retained write below both coherent caches. Experimental integration:
// their completion edge updates matching data and invalidates code before a
// later CPU hit can complete. Every request that reaches this boundary waits
// for the older write to drain. No forwarding, merging or second queue slot.
// CPU-local cancellation never discards a locally accepted write. Global
// reset clears this block together with its physical owner; it does not replay.
module spk286_at_posted_write_buffer #(
    parameter logic ENABLE = 1'b1
) (
    input logic clk, reset, cancel_cpu, cpu_lock,
    input logic in_valid, in_command_valid,
    input logic [1:0] in_owner,
    input logic in_write, in_refresh, in_code_fetch, in_burst,
    input logic [3:0] in_cycle_class,
    input logic [24:0] in_address,
    input logic [1:0] in_byte_enable,
    input logic [15:0] in_data_out,
    output logic in_accept, in_ready,
    output logic [15:0] in_read_data,
    output logic in_read_data_valid,
    output logic out_valid, out_command_valid,
    output logic [1:0] out_owner,
    output logic out_write, out_refresh, out_code_fetch, out_burst,
    output logic [3:0] out_cycle_class,
    output logic [24:0] out_address,
    output logic [1:0] out_byte_enable,
    output logic [15:0] out_data_out,
    input logic out_accept, out_ready,
    input logic [15:0] out_read_data,
    input logic out_read_data_valid,
    output logic pending_write, idle, protocol_error,
    output logic [31:0] debug_post_count, debug_drain_count, debug_stall_count
);
    localparam logic [1:0] IDLE = 2'd0, POSTED = 2'd1, BYPASS = 2'd2;
    logic [1:0] state_q, owner_q;
    logic issued_q, ack_q;
    logic write_q, refresh_q, code_q, burst_q;
    logic [3:0] class_q;
    logic [24:0] address_q;
    logic [1:0] lanes_q;
    logic [15:0] data_q;

    wire ram_address = in_address < 25'h00A0000 ||
                       (in_address >= 25'h0100000 && in_address < 25'h11E0000);
    wire candidate = ENABLE && in_owner == 2'd0 && in_write &&
                     !in_refresh && !in_code_fetch && !in_burst &&
                     in_cycle_class == 4'h6 && |in_byte_enable &&
                     ram_address && !cpu_lock;
    wire presented = in_valid && in_command_valid && !reset &&
                     !(cancel_cpu && in_owner == 2'd0);
    wire complete = issued_q && out_ready &&
                    (write_q || refresh_q || out_read_data_valid);
    assign pending_write = state_q == POSTED;
    assign idle = state_q == IDLE;

    always_comb begin
        in_accept = 1'b0;
        in_ready = 1'b0;
        in_read_data = out_read_data;
        in_read_data_valid = 1'b0;
        out_valid = state_q != IDLE && !reset;
        out_command_valid = out_valid && !issued_q;
        out_owner = owner_q;
        out_write = write_q;
        out_refresh = refresh_q;
        out_code_fetch = code_q;
        out_burst = burst_q;
        out_cycle_class = class_q;
        out_address = address_q;
        out_byte_enable = lanes_q;
        out_data_out = data_q;
        // The idle payload does not depend on admission through upstream
        // buffers. It is consumed only with out_valid; retained ownership
        // still selects the frozen record throughout posting and drain.
        if (state_q == IDLE) begin
            out_owner = in_owner;
            out_write = in_write;
            out_refresh = in_refresh;
            out_code_fetch = in_code_fetch;
            out_burst = in_burst;
            out_cycle_class = in_cycle_class;
            out_address = in_address;
            out_byte_enable = in_byte_enable;
            out_data_out = in_data_out;
        end
        if (!reset) begin
            case (state_q)
                IDLE: if (presented) begin
                    // Launch on the capture edge when physically possible.
                    // A posted record may instead wait here for refresh/end
                    // recovery. Logical READY appears only after retention.
                    out_valid = 1'b1;
                    out_command_valid = 1'b1;
                    in_accept = candidate || out_accept;
                end
                POSTED: begin
                    // Exactly one logical completion. Physical READY is
                    // consumed privately and never completes a later request.
                    in_ready = ack_q;
                end
                BYPASS: begin
                    in_ready = complete;
                    // Intermediate code-fill beats precede final READY.
                    in_read_data_valid = issued_q && !write_q && !refresh_q &&
                                         out_read_data_valid;
                end
                default: begin end
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= IDLE;
            issued_q <= 1'b0;
            ack_q <= 1'b0;
            owner_q <= 2'd0;
            write_q <= 1'b0;
            refresh_q <= 1'b0;
            code_q <= 1'b0;
            burst_q <= 1'b0;
            class_q <= 4'd0;
            address_q <= 25'd0;
            lanes_q <= 2'd0;
            data_q <= 16'd0;
            protocol_error <= 1'b0;
            debug_post_count <= 0;
            debug_drain_count <= 0;
            debug_stall_count <= 0;
        end else begin
            if (out_accept && !out_command_valid) protocol_error <= 1'b1;
            if (state_q == IDLE && in_accept) begin
                state_q <= candidate ? POSTED : BYPASS;
                issued_q <= out_accept;
                ack_q <= candidate;
                owner_q <= in_owner;
                write_q <= in_write;
                refresh_q <= in_refresh;
                code_q <= in_code_fetch;
                burst_q <= in_burst;
                class_q <= in_cycle_class;
                address_q <= in_address;
                lanes_q <= in_byte_enable;
                data_q <= in_data_out;
                if (candidate) debug_post_count <= debug_post_count + 1;
            end else if (state_q != IDLE) begin
                ack_q <= 1'b0;
                if (!issued_q && out_accept) issued_q <= 1'b1;
                if (state_q == POSTED && in_valid && in_command_valid)
                    debug_stall_count <= debug_stall_count + 1;
                if (complete) begin
                    state_q <= IDLE;
                    issued_q <= 1'b0;
                    if (state_q == POSTED)
                        debug_drain_count <= debug_drain_count + 1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) if (!reset) begin
        assert (!in_accept || state_q == IDLE)
            else $error("Posted buffer accepted while occupied");
        assert (!out_command_valid || out_valid)
            else $error("Posted buffer command without valid record");
        assert (!(state_q == POSTED && in_read_data_valid))
            else $error("Posted write exposed read data");
        assert (!(state_q == POSTED && (!write_q || refresh_q || burst_q)))
            else $error("Posted record is not an ordinary write");
    end
`endif
endmodule
