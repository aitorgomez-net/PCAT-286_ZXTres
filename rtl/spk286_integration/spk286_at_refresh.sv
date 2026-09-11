// Functional refresh requester for the AT ownership boundary.
`timescale 1ns/1ps

module spk286_at_refresh #(
    parameter integer REFRESH_INTERVAL = 32
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        refresh_enable,
    input  logic        refresh_grant,
    input  logic        refresh_accept,
    input  logic        refresh_ready,
    output logic        refresh_request,
    output logic        refresh_bus_valid,
    output logic [23:0] refresh_address,
    output logic        refresh_complete,
    output logic [15:0] refresh_count,
    output logic        protocol_error
);
    logic [31:0] interval_q;
    logic [9:0] row_q;
    logic pending_q;
    logic active_q;
    logic accepted_q;

    assign refresh_request = pending_q || active_q;
    assign refresh_bus_valid = active_q;
    assign refresh_address = {14'h0000, row_q};

    always_ff @(posedge clk) begin
        if (reset) begin
            interval_q <= '0;
            row_q <= 10'h000;
            pending_q <= 1'b0;
            active_q <= 1'b0;
            accepted_q <= 1'b0;
            refresh_complete <= 1'b0;
            refresh_count <= 16'h0000;
            protocol_error <= 1'b0;
        end else begin
            refresh_complete <= 1'b0;

            if (refresh_enable && !pending_q && !active_q) begin
                if (interval_q == REFRESH_INTERVAL - 1) begin
                    interval_q <= '0;
                    pending_q <= 1'b1;
                end else
                    interval_q <= interval_q + 1'b1;
            end else if (!refresh_enable) begin
                interval_q <= '0;
                pending_q <= 1'b0;
            end

            if (!active_q && pending_q && refresh_grant) begin
                active_q <= 1'b1;
                pending_q <= 1'b0;
                accepted_q <= 1'b0;
            end else if (active_q) begin
                if (!accepted_q && refresh_accept)
                    accepted_q <= 1'b1;
                else if (accepted_q && refresh_ready) begin
                    active_q <= 1'b0;
                    accepted_q <= 1'b0;
                    refresh_complete <= 1'b1;
                    refresh_count <= refresh_count + 1'b1;
                    row_q <= row_q + 1'b1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset)
            assert (!(refresh_complete && refresh_bus_valid))
                else $error("AT refresh completed while bus-valid remained asserted");
    end
`endif
endmodule
