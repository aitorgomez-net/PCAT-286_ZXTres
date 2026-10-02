// AT ownership request from PIT channel 1. Physical SDRAM AUTO REFRESH is
// independently scheduled by KFSDRAM. OUT1 also drives port 61h's toggle.
`timescale 1ns/1ps
module spk286_at_refresh (
    input logic clk, reset, refresh_enable, timer_1_out,
    input logic refresh_grant, refresh_accept, refresh_ready,
    output logic refresh_request, refresh_bus_valid,
    output logic [23:0] refresh_address,
    output logic refresh_complete,
    output logic [15:0] refresh_count,
    output logic protocol_error
);
    logic timer_1_q;
    logic [9:0] row_q;
    logic pending_q, active_q, accepted_q;
    wire trigger = refresh_enable && timer_1_out && !timer_1_q;
    assign refresh_request = pending_q || active_q;
    assign refresh_bus_valid = active_q;
    assign refresh_address = {14'd0, row_q};
    always_ff @(posedge clk) begin
        if (reset) begin
            timer_1_q <= 0;
            row_q <= 0;
            pending_q <= 0;
            active_q <= 0;
            accepted_q <= 0;
            refresh_complete <= 0;
            refresh_count <= 0;
            protocol_error <= 0;
        end else begin
            timer_1_q <= timer_1_out;
            refresh_complete <= 0;
            // Retain one pending request during a lock/active owner; repeated
            // triggers coalesce. Disabling suppresses new ownership but an
            // accepted active operation still drains through its endpoint.
            if (!refresh_enable) pending_q <= 0;
            else if (trigger) pending_q <= 1;
            if (!active_q && pending_q && refresh_enable && refresh_grant) begin
                active_q <= 1;
                pending_q <= trigger;
                accepted_q <= 0;
            end else if (active_q) begin
                if (!accepted_q && refresh_accept) accepted_q <= 1;
                else if (accepted_q && refresh_ready) begin
                    active_q <= 0;
                    accepted_q <= 0;
                    refresh_complete <= 1;
                    refresh_count <= refresh_count + 1'b1;
                    row_q <= row_q + 1'b1;
                end
            end
        end
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) if (!reset) begin
        assert (!(refresh_complete && refresh_bus_valid))
            else $error("AT PIT refresh completed while active");
        assert (!accepted_q || active_q)
            else $error("AT PIT refresh acceptance without ownership");
    end
`endif
endmodule
