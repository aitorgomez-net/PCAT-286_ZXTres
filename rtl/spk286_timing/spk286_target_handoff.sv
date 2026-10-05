// Qualify the historical branch-to-target allowance without executing the
// successor. The caller owns the successful redirect epoch, preview bytes,
// successor fault attribution and normal event arbitration before replay.
// Length is delivered separately from frozen source timing metadata: a late
// CODE response after functional END must still extend the source deadline.
`ifndef SPK286_TARGET_HANDOFF_SV
`define SPK286_TARGET_HANDOFF_SV
`timescale 1ns/1ps
module spk286_target_handoff (
    input logic clk, reset, historical_enable,
    input logic cancel, start_interval, source_retire,
    input logic requires_target_length, redirect_event,
    input logic preview_complete, preview_fault,
    input logic [3:0] preview_length,
    output logic pending, preview_enable,
    output logic target_length_ready,
    output logic [3:0] target_length_clocks,
    output logic target_fault_estimated
);
    logic pending_q, known_q, fault_q;
    logic [3:0] length_q;
    wire new_redirect = redirect_event && requires_target_length;
    wire valid_length = preview_length >= 4'd1 && preview_length <= 4'd10;

    assign pending = historical_enable && pending_q;
    assign preview_enable = historical_enable && pending_q && !known_q && !cancel;
    // Only retained state participates in the scheduler deadline. Feeding the
    // live redirect into readiness would close a combinational loop through
    // the EU operation permit. MC_REDIRECT precedes registered functional END
    // in the caller, so the pending token closes before any source retirement.
    // Raw functional completion never clears the target dependency.
    assign target_length_ready = !historical_enable ||
        !pending_q || known_q;
    assign target_length_clocks = historical_enable && pending_q && known_q ?
                                  length_q : 4'd0;
    assign target_fault_estimated = historical_enable && pending_q && known_q && fault_q;

    always_ff @(posedge clk) begin
        if (reset || !historical_enable || cancel || start_interval || source_retire) begin
            pending_q <= 1'b0;
            known_q <= 1'b0;
            fault_q <= 1'b0;
            length_q <= 4'd0;
        end else begin
            if (new_redirect) begin
                pending_q <= 1'b1;
                known_q <= 1'b0;
                fault_q <= 1'b0;
                length_q <= 4'd0;
            end
            // A parser terminal can remain asserted from an earlier stream.
            // The redirect edge must invalidate it, never bind it as the new
            // target. Only a later completion in this retained epoch counts.
            if (pending_q && !known_q && !new_redirect && preview_complete &&
                (preview_fault || valid_length)) begin
                pending_q <= 1'b1;
                known_q <= 1'b1;
                fault_q <= preview_fault;
                // Invalid/truncated/overlength successors have no documented
                // executed-instruction length. Release the source at its base
                // minimum using an explicit estimated policy; the caller must
                // retain and later deliver the successor's own fault/IP.
                length_q <= preview_fault ? 4'd0 : preview_length;
            end
        end
    end
endmodule
`endif
