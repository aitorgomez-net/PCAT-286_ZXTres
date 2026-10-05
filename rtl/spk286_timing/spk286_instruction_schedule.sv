// Provisional instruction-interval scheduler. Functional services stay on the
// fabric clock; this module qualifies observable instruction/event boundaries.
// The metadata budget is independent of micro-operation implementation count.
`ifndef SPK286_INSTRUCTION_SCHEDULE_SV
`define SPK286_INSTRUCTION_SCHEDULE_SV
`timescale 1ns/1ps
module spk286_instruction_schedule #(
    parameter bit EXECUTION_METADATA_CARRY_SAVE = 1'b0
) (
    input logic clk, reset, historical_enable, cpu_boundary,
    input logic cancel, preserve_cancel,
    input logic start_interval, start_body,
    input logic metadata_valid, metadata_freeze,
    input logic [9:0] metadata_clocks,
    // Admission metadata may inspect the next queue byte. The execution lane
    // must match it while body_active is asserted, and uses retained context.
    input logic execution_metadata_valid, execution_read_wait_event,
    input logic [9:0] execution_metadata_clocks,
    // The production execution lane can retain the unsaturated metadata
    // compressor outputs. Their sum is the same nonnegative budget before
    // its 1023 clamp. Legacy callers continue using metadata_clocks above.
    input logic [11:0] execution_metadata_sum_bits, execution_metadata_carry_bits,
    input logic target_length_ready,
    input logic [3:0] target_length_clocks,
    input logic read_wait_event, alignment_event,
    input logic functional_retired,
    input logic repeat_checkpoint,
    input logic [9:0] repeat_next_clocks,
    output logic active, body_active, retire_pending,
    output logic head_permit, deadline_ready, retire_fire,
    output logic [9:0] elapsed_clocks, scheduled_clocks,
    output logic implementation_extension
);
    logic active_q, body_q, pending_q, qualified_q, frozen_q, admission_window_q;
    logic [9:0] elapsed_q, base_q, extra_q;
    logic [10:0] elapsed_next, effective_base, extra_next;
    logic [11:0] total;
    logic [12:0] execution_budget_sum, execution_budget_carry;
    logic [12:0] execution_adjustment_sum, execution_adjustment_carry;
    logic [12:0] execution_adjustment;
    logic [12:0] execution_compare_sum, execution_compare_carry, execution_difference;
    logic execution_productive_boundary, execution_elapsed_saturated;
    logic execution_metadata_available;

    always_comb begin
        // Extra READ waits can be arbitrarily long. Count productive CPU
        // boundaries instead of accumulating an unbounded wait-state debt:
        // elapsed_real >= base + READ_waits iff productive >= base.
        elapsed_next = {1'b0, elapsed_q} + 11'(cpu_boundary && !read_wait_event);
        if (elapsed_next > 11'd1023) elapsed_next = 11'd1023;
        effective_base = (!frozen_q && metadata_valid) ?
                         {1'b0, metadata_clocks} : {1'b0, base_q};
        extra_next = {1'b0, extra_q} + (alignment_event ? 11'd2 : 11'd0);
        if (extra_next > 11'd1023) extra_next = 11'd1023;
        // Current bus admissions may depend on an EU checkpoint permit. They
        // update the retained budget at this edge, never feed that permit
        // combinationally. Every reference precedes its functional retirement.
        // The source's base freezes at functional END. Its independently
        // qualified target encoding may arrive later, so this allowance must
        // never be frozen with the earlier base or charged to the successor.
        total = {1'b0, effective_base} + {2'd0, extra_q} + {8'd0, target_length_clocks};
        if (total > 12'd1023) total = 12'd1023;
        // Cut the admission-byte classifier out of retirement/EU backpressure.
        // This is a parallel combinational lane, not a delayed pipeline stage.
        execution_budget_sum = {3'd0, base_q};
        execution_budget_carry = 13'd0;
        if (!frozen_q && execution_metadata_valid) begin
            if (EXECUTION_METADATA_CARRY_SAVE) begin
                execution_budget_sum = {1'b0, execution_metadata_sum_bits};
                execution_budget_carry = {execution_metadata_carry_bits, 1'b0};
            end else execution_budget_sum = {3'd0, execution_metadata_clocks};
        end
        // This arithmetic lane depends only on retained age/alignment/target
        // context. Keep its carry propagation parallel to metadata decoding.
        execution_adjustment_sum = {3'd0, extra_q} ^ {9'd0, target_length_clocks} ^
                                   ~{3'd0, elapsed_q};
        execution_adjustment_carry = ({3'd0, extra_q} & {9'd0, target_length_clocks}) |
                                     ({3'd0, extra_q} & ~{3'd0, elapsed_q}) |
                                     ({9'd0, target_length_clocks} & ~{3'd0, elapsed_q});
        execution_adjustment = execution_adjustment_sum + (execution_adjustment_carry << 1);
        execution_compare_sum = execution_budget_sum ^ execution_budget_carry ^ execution_adjustment;
        execution_compare_carry = (execution_budget_sum & execution_budget_carry) |
                                  (execution_budget_sum & execution_adjustment) |
                                  (execution_budget_carry & execution_adjustment);
        execution_difference = execution_compare_sum + (execution_compare_carry << 1);
        // difference is budget+extra+target-age-1 modulo 8192. Its true range
        // is -1024..3113, so bit12 is the exact signed comparison result.
        // A productive boundary also permits equality with age+1. At age1023
        // the existing saturation override remains unconditional; removing
        // the earlier metadata clamp is exact because all extras are >=0.
        execution_productive_boundary = cpu_boundary && !execution_read_wait_event;
        execution_elapsed_saturated = elapsed_q == 10'd1023 ||
                                      (execution_productive_boundary && elapsed_q == 10'd1022);
        execution_metadata_available = qualified_q || (!frozen_q && execution_metadata_valid);
    end
    assign active = historical_enable && active_q;
    assign body_active = historical_enable && body_q;
    assign retire_pending = historical_enable && pending_q;
    assign head_permit = !historical_enable ||
                         ((cpu_boundary || admission_window_q) &&
                          (!active_q || !body_q) && !pending_q);
    assign deadline_ready = !historical_enable ||
                            (active_q && body_q && execution_metadata_available && target_length_ready &&
                             (execution_elapsed_saturated || execution_difference[12] ||
                              (execution_productive_boundary && execution_difference == 13'd0)));
    assign retire_fire = !historical_enable ? functional_retired :
                         !reset && !cancel && cpu_boundary && deadline_ready &&
                         (pending_q || functional_retired);
    assign elapsed_clocks = elapsed_q;
    assign scheduled_clocks = total[9:0];

    always_ff @(posedge clk) begin
        if (reset || !historical_enable || (cancel && !preserve_cancel)) begin
            active_q <= 1'b0; body_q <= 1'b0; pending_q <= 1'b0;
            qualified_q <= 1'b0; frozen_q <= 1'b0;
            admission_window_q <= 1'b0;
            elapsed_q <= 10'd0; base_q <= 10'd0; extra_q <= 10'd0;
            implementation_extension <= 1'b0;
        end else begin
            if (active_q) begin
                elapsed_q <= elapsed_next[9:0];
                extra_q <= extra_next[9:0];
                if (!frozen_q && metadata_valid) begin
                    base_q <= metadata_clocks;
                    qualified_q <= 1'b1;
                end
                if (metadata_freeze) frozen_q <= 1'b1;
                if (functional_retired) pending_q <= 1'b1;
                if (cpu_boundary && !read_wait_event && deadline_ready &&
                    !pending_q && !functional_retired && !repeat_checkpoint)
                    implementation_extension <= 1'b1;
            end
            if (retire_fire) begin
                active_q <= 1'b0; body_q <= 1'b0; pending_q <= 1'b0;
                qualified_q <= 1'b0; frozen_q <= 1'b0;
                // The interval opens at this virtual boundary. Its next head
                // is consumed after the old context has cleared, on a fabric
                // edge in the same virtual interval, without adding a CPU tick.
                admission_window_q <= 1'b1;
                elapsed_q <= 10'd0; base_q <= 10'd0; extra_q <= 10'd0;
            end
            if (repeat_checkpoint) begin
                active_q <= 1'b1; body_q <= 1'b1; pending_q <= 1'b0;
                qualified_q <= 1'b1; frozen_q <= 1'b1;
                elapsed_q <= 10'd0; base_q <= repeat_next_clocks; extra_q <= 10'd0;
            end
            if (start_body) begin body_q <= 1'b1; admission_window_q <= 1'b0; end
            if (start_interval) begin
                active_q <= 1'b1; body_q <= start_body; pending_q <= 1'b0;
                qualified_q <= metadata_valid; frozen_q <= 1'b0;
                elapsed_q <= 10'd0; base_q <= metadata_clocks; extra_q <= 10'd0;
                implementation_extension <= 1'b0;
            end
        end
    end
endmodule
`endif
