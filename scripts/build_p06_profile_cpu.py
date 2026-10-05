#!/usr/bin/env python3
"""Generate the single selected production timing variant from frozen SPK286.

Private pilot ancestors remain frozen. Named functional corrections and shared
syntax metadata are pinned independently below. The general profile uses
Intel/native metadata, retained bus dependencies and deferred retirement. It
is provisional instruction/logical-bus timing, not an exact internal-EU or
native-pin schedule claim.
"""
import argparse
import hashlib
import json
from pathlib import Path
from p06_repeat_local import generate as generate_local_repeat_executor

ROOT = Path(__file__).resolve().parents[1]
ORIGINALS = {
    "vendor/spk286/rtl/spk286.sv": "9a04d8b46b4fab359ba6739b159444925b4118df51e26227e62f9b584db5f046",
    "vendor/spk286/rtl/spk286_events.sv": "fb5253389daf3e69338a9aed2e3dfcb0d2352a4ac1e48b07baea3c68ea60fa9d",
    "vendor/spk286/microcode/generated/spk286_microcode_pkg.sv": "fedea94b3d1435a77765aa425926ba8efecabdc0806092a7894c6a1b38d85afe",
}

# The private P06 pilot receipt remains a historical baseline. These two
# explicit production inputs implement separately verified corrections;
# do not replace hashes inside the frozen evidence to admit them.
FUNCTIONAL_UPDATES = {
    # A completed legal ten-byte instruction is not a demand for byte eleven.
    "vendor/spk286/rtl/spk286.sv": "fe945327191099b0c1580eae0819a451cd797b8b0cf3f78166e4b5eefd159b26",
    "vendor/spk286/rtl/spk286_fetch.sv": "1da4efb3273c690d97acba5f8646a3e40b9588b957e00dfc7d4aa40c66b6af3c",
    # Canonical encoding metadata adds no functional words or decoder map.
    "vendor/spk286/microcode/generated/spk286_microcode_pkg.sv": "202236c1ec93016bfb17d8a918b61de8af805dabb4ccb55c9cc1ec54875e3e10",
    "vendor/spk286/microcode/generated/spk286_microcode_rom.sv": "8861eb3eefeecc72a0e6383cf95d961c0d0cb27f76595bcb5ecc3d2ae711f519",
    "vendor/spk286/microcode/generated/spk286_microcode_sync_rom.sv": "31841a56d61b32aaf92c91afbc0258d67ce90a3c67788dc06092c8d845ec1894",
    # Default functional entries remain identical; syntax mode resolves the
    # generated acquisition shape at those same canonical decoder leaves.
    "vendor/spk286/rtl/spk286_decoder.sv": "d38849308e58512e02f7766a0aa4d513a73771915901e7dd8b44eb457f1606bb",
    "vendor/spk286/rtl/spk286_control_decode.sv": "026d3217f5290f2b3b7f14da66a660ff0e65372b6dbb11c7db6f1ae2c56b352b",
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError(f"Profile source anchor occurs {source.count(old)} times: {old[:100]}")
    return source.replace(old, new)


CONNECTION = r'''
    // The functional FSMs run at fabric speed. Only new instruction bodies,
    // repetition checkpoints and observable retire/event boundaries are timed.
    logic profile_decode_ready, profile_raw_operation_valid;
    logic profile_active;
    /* verilator lint_off UNUSEDSIGNAL */
    logic profile_body_active, profile_retire_pending;
    /* verilator lint_on UNUSEDSIGNAL */
    logic profile_head_permit, profile_deadline_ready, profile_retire_fire;
    logic profile_normal_retired_q, profile_async_enable, profile_preserve_cancel;
    logic profile_repeat_empty, profile_repeat_continue, profile_repeat_more;
    logic profile_repeat_permit, profile_repeat_checkpoint;
    logic profile_metadata_valid;
    logic profile_family_estimated;
    /* verilator lint_off UNUSEDSIGNAL */
    logic profile_metadata_estimated;
    /* verilator lint_on UNUSEDSIGNAL */
    logic profile_branch_known_q, profile_branch_taken_q, profile_count_known_q;
    logic [4:0] profile_count_q;
    logic [3:0] profile_prefix_count_q;
    logic profile_repeat_nonempty_q;
    logic [9:0] profile_base_clocks, profile_repeat_setup, profile_repeat_iteration;
    logic [2:0] profile_ea_clocks;
    logic profile_metadata_read_wait;
    logic profile_alignment_event, profile_start_interval, profile_start_body;
    logic [9:0] profile_metadata_clocks;
    logic profile_execution_metadata_valid, profile_execution_metadata_read_wait;
    logic [9:0] profile_execution_base, profile_execution_repeat_setup;
    logic [9:0] profile_execution_repeat_iteration, profile_execution_metadata_clocks;
    logic [2:0] profile_execution_ea;
    logic profile_instruction_metadata_valid, profile_instruction_metadata_read_wait;
    logic profile_event_metadata_valid, profile_event_metadata_read_wait;
    logic [9:0] profile_event_base;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [4:0] profile_execution_unused;
    logic [4:0] profile_event_unused;
    logic [9:0] profile_event_repeat_setup, profile_event_repeat_iteration;
    logic [2:0] profile_event_ea;
    /* verilator lint_on UNUSEDSIGNAL */
    /* verilator lint_off UNUSEDSIGNAL */
    logic profile_requires_modrm, profile_requires_outcome, profile_requires_count;
    logic [9:0] profile_elapsed, profile_scheduled;
    logic profile_implementation_extension;
    /* verilator lint_on UNUSEDSIGNAL */

    logic profile_requires_target_length;
    // Park only between complete instruction/event contexts. Existing BIU
    // and fetch responses continue draining on the unchanged fabric clock.
    wire profile_change_hold = (profile_change_pending === 1'b1) &&
        !micro_active && !context_active && !event_active && !profile_active &&
        !raw_retired && !event_completed && !profile_target_pending;
    assign profile_change_ready = profile_change_hold && !bus_valid && !fetch_bus_valid;
    logic profile_native_queue_valid, profile_native_queue_ready;
    logic [7:0] profile_native_queue_data;
    logic profile_target_pending, profile_target_preview_enable;
    logic profile_target_preview_start, profile_target_started_q;
    logic profile_target_preview_active, profile_target_byte_ready;
    logic profile_target_complete, profile_target_valid_length;
    /* verilator lint_off UNUSEDSIGNAL */
    logic profile_target_invalid, profile_target_unsupported;
    logic profile_target_overlength, profile_target_fetch_fault;
    /* verilator lint_on UNUSEDSIGNAL */
    logic profile_target_abort_fetch, profile_target_length_ready;
    logic [3:0] profile_target_length, profile_target_length_clocks;
    logic profile_target_replay_valid;
    logic [7:0] profile_target_replay_data;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [3:0] profile_target_replay_count;
    logic profile_target_fault_estimated;
    /* verilator lint_on UNUSEDSIGNAL */

    // A real redirect qualifies the source form. Preview starts only after
    // functional END, when no late source operand can consume target bytes.
    assign profile_target_preview_start = historical_enable && raw_retired &&
        profile_target_pending && !event_active && !profile_target_started_q;
    assign profile_target_preview_active = profile_target_started_q &&
        profile_target_preview_enable && !micro_active;
    assign profile_target_abort_fetch = !profile_native_queue_valid &&
        !fetch_response_valid && !fetch_bus_valid &&
        (fetch_blocked || protected_fetch_invalid);
    always_ff @(posedge clk) begin
        if (reset || !historical_enable || stream_restart || profile_start_interval ||
            profile_retire_fire)
            profile_target_started_q <= 1'b0;
        else if (profile_target_preview_start)
            profile_target_started_q <= 1'b1;
    end

    spk286_target_handoff profile_target_handoff (
        .clk(clk), .reset(reset), .historical_enable(historical_enable),
        .cancel(semantic_cancel || loadall_commit_valid ||
                (internal_redirect && (!profile_requires_target_length || event_active))),
        .start_interval(profile_start_interval), .source_retire(profile_retire_fire),
        .requires_target_length(profile_requires_target_length && !event_active),
        .redirect_event(internal_redirect),
        .preview_complete(profile_target_complete && profile_target_started_q),
        .preview_fault(!profile_target_valid_length), .preview_length(profile_target_length),
        .pending(profile_target_pending), .preview_enable(profile_target_preview_enable),
        .target_length_ready(profile_target_length_ready),
        .target_length_clocks(profile_target_length_clocks),
        .target_fault_estimated(profile_target_fault_estimated)
    );
    spk286_encoding_preview profile_target_preview (
        .clk(clk), .reset(reset), .cancel(!historical_enable || stream_restart),
        .start(profile_target_preview_start), .enable(profile_target_preview_active),
        .byte_valid(profile_native_queue_valid), .byte_data(profile_native_queue_data),
        .abort_fetch(profile_target_abort_fetch), .byte_ready(profile_target_byte_ready),
        .complete(profile_target_complete), .valid_length(profile_target_valid_length),
        .invalid_opcode(profile_target_invalid), .unsupported(profile_target_unsupported),
        .overlength(profile_target_overlength), .fetch_fault(profile_target_fetch_fault),
        .length(profile_target_length)
    );
    spk286_target_replay profile_target_replay (
        // A live transition to MAX must retain bytes already removed from
        // the native queue. They leave through the normal consume handshake.
        .clk(clk), .reset(reset), .cancel(stream_restart),
        .start(profile_target_preview_start),
        .capture(profile_native_queue_valid && profile_target_byte_ready),
        .capture_data(profile_native_queue_data),
        .consume(!profile_target_pending && queue_consume_valid && queue_consume_ready &&
                 profile_target_replay_valid),
        .valid(profile_target_replay_valid), .data(profile_target_replay_data),
        .count(profile_target_replay_count)
    );
    // Only replay uses the existing architectural queue handshake. Native
    // prefetch keeps its six-byte reservation and accepted-response ownership.
    assign queue_consume_valid = profile_target_pending ? 1'b0 :
        profile_target_replay_valid ? 1'b1 : profile_native_queue_valid;
    assign queue_consume_data = profile_target_replay_valid ?
        profile_target_replay_data : profile_native_queue_data;
    assign profile_native_queue_ready = profile_target_pending ? profile_target_byte_ready :
        (!profile_target_replay_valid && queue_consume_ready);

    wire profile_delivery_metadata = event_dispatch || (event_active && !event_software);
    // Candidate metadata must not depend on opcode_start/event_request: the
    // retirement deadline itself participates in event/head arbitration.
    wire profile_candidate_body = !event_active && !micro_active && !profile_body_active;
    wire [7:0] profile_metadata_opcode = profile_delivery_metadata ? 8'd0 :
                                         profile_candidate_body ? queue_consume_data : opcode_q;
    wire [spk286_microcode_pkg::MC_ADDR_WIDTH-1:0] profile_metadata_entry =
        profile_delivery_metadata ? (protected_msw[0] ?
            spk286_microcode_pkg::MC_ENTRY_EVENT_ENTRY_PROTECTED :
            spk286_microcode_pkg::MC_ENTRY_EVENT_ENTRY) :
        profile_candidate_body ? decode_entry : micro_entry;
    wire profile_is_string = !extended_opcode_active &&
        ((profile_metadata_opcode >= 8'hA4 && profile_metadata_opcode <= 8'hA7) ||
         (profile_metadata_opcode >= 8'hAA && profile_metadata_opcode <= 8'hAF) ||
         (profile_metadata_opcode >= 8'h6C && profile_metadata_opcode <= 8'h6F));
    wire profile_repeated_string = profile_is_string && repeat_kind != 0;
    // Intel LOCK has no separate execution-clock charge. 0F is an escape.
    wire profile_real_prefix = prefix_accept && queue_consume_data != 8'h0F &&
                              queue_consume_data != 8'hF0;
    wire profile_modrm_current = operand_context_valid && micro_active && !event_active;

    // Prefix correction is a nonnegative addend. For REP, the table already
    // includes one prefix: subtract it from the small prefix count before
    // adding the budget, not after a chain of wide carry-propagating sums.
    function automatic logic [9:0] profile_metadata_budget(
        input logic [9:0] base, setup_clocks, iteration_clocks,
        input logic [2:0] ea,
        input logic repeated, nonempty, delivery,
        input logic [3:0] prefixes
    );
        logic [3:0] remaining_prefixes;
        logic [11:0] first, second, prefix_clocks, sum_bits, carry_bits, full_sum;
        remaining_prefixes = prefixes == 0 ? 4'd0 : prefixes - 4'd1;
        first = {2'd0, repeated ? setup_clocks : base};
        second = repeated ? (nonempty ? {2'd0, iteration_clocks} : 12'd0) : {9'd0, ea};
        prefix_clocks = repeated ? {7'd0, remaining_prefixes, 1'b0} :
                        delivery ? 12'd0 : {7'd0, prefixes, 1'b0};
        sum_bits = first ^ second ^ prefix_clocks;
        carry_bits = (first & second) | (first & prefix_clocks) | (second & prefix_clocks);
        full_sum = sum_bits + (carry_bits << 1);
        profile_metadata_budget = |full_sum[11:10] ? 10'd1023 : full_sum[9:0];
    endfunction

    spk286_instruction_timing profile_metadata (
        .opcode(profile_metadata_opcode),
        .extended_opcode(profile_delivery_metadata ? 1'b0 : extended_opcode_active),
        .micro_entry(profile_metadata_entry),
        .modrm_valid(profile_modrm_current), .modrm_mode(operand_mode),
        .modrm_reg(operand_reg), .modrm_rm(operand_rm),
        .protected_mode(protected_msw[0]), .CPL(current_cpl),
        .operand_odd(1'b0),
        .branch_known(profile_branch_known_q), .branch_taken(profile_branch_taken_q),
        .count_known(profile_count_known_q), .count(profile_count_q),
        .repeat_kind(repeat_kind), .qualified(profile_metadata_valid),
        .estimated(profile_family_estimated),
        .requires_modrm(profile_requires_modrm), .requires_outcome(profile_requires_outcome),
        .requires_count(profile_requires_count), .base_clocks(profile_base_clocks),
        .requires_target_length(profile_requires_target_length),
        .repeat_setup_clocks(profile_repeat_setup),
        .repeat_iteration_clocks(profile_repeat_iteration),
        .permits_read_wait(profile_metadata_read_wait), .ea_clocks(profile_ea_clocks)
    );

    // Retirement/REP permission uses only retained execution context. The
    // admission lane above still captures exactly the original next-head
    // metadata, but its decoder must not feed through the deadline to EU
    // exception/head arbitration. Both lanes agree whenever body_active is
    // true; no architectural or virtual-clock boundary is added.
    // Classify retained instruction and delivery contexts in parallel. The
    // live dispatch permission selects their completed budgets below; it does
    // not traverse the instruction decoder or prefix arithmetic.
    wire [7:0] profile_execution_opcode = opcode_q;
    wire [spk286_microcode_pkg::MC_ADDR_WIDTH-1:0] profile_execution_entry = micro_entry;
    wire profile_execution_string = !extended_opcode_active &&
        ((profile_execution_opcode >= 8'hA4 && profile_execution_opcode <= 8'hA7) ||
         (profile_execution_opcode >= 8'hAA && profile_execution_opcode <= 8'hAF) ||
         (profile_execution_opcode >= 8'h6C && profile_execution_opcode <= 8'h6F));
    wire profile_execution_repeated = profile_execution_string && repeat_kind != 0;
    spk286_instruction_timing profile_execution_metadata (
        .opcode(profile_execution_opcode),
        .extended_opcode(extended_opcode_active),
        .micro_entry(profile_execution_entry),
        .modrm_valid(profile_modrm_current), .modrm_mode(operand_mode),
        .modrm_reg(operand_reg), .modrm_rm(operand_rm),
        .protected_mode(protected_msw[0]), .CPL(current_cpl), .operand_odd(1'b0),
        .branch_known(profile_branch_known_q), .branch_taken(profile_branch_taken_q),
        .count_known(profile_count_known_q), .count(profile_count_q),
        .repeat_kind(repeat_kind), .qualified(profile_instruction_metadata_valid),
        .estimated(profile_execution_unused[0]),
        .requires_modrm(profile_execution_unused[1]),
        .requires_outcome(profile_execution_unused[2]),
        .requires_count(profile_execution_unused[3]),
        .requires_target_length(profile_execution_unused[4]),
        .base_clocks(profile_execution_base),
        .repeat_setup_clocks(profile_execution_repeat_setup),
        .repeat_iteration_clocks(profile_execution_repeat_iteration),
        .permits_read_wait(profile_instruction_metadata_read_wait),
        .ea_clocks(profile_execution_ea)
    );
    // Reuse the authoritative policy table rather than duplicate event timing
    // constants. Constant event entries fold to the small delivery lane.
    spk286_instruction_timing profile_event_metadata (
        .opcode(8'd0), .extended_opcode(1'b0),
        .micro_entry(protected_msw[0] ?
            spk286_microcode_pkg::MC_ENTRY_EVENT_ENTRY_PROTECTED :
            spk286_microcode_pkg::MC_ENTRY_EVENT_ENTRY),
        .modrm_valid(profile_modrm_current), .modrm_mode(operand_mode),
        .modrm_reg(operand_reg), .modrm_rm(operand_rm),
        .protected_mode(protected_msw[0]), .CPL(current_cpl), .operand_odd(1'b0),
        .branch_known(profile_branch_known_q), .branch_taken(profile_branch_taken_q),
        .count_known(profile_count_known_q), .count(profile_count_q),
        .repeat_kind(repeat_kind), .qualified(profile_event_metadata_valid),
        .estimated(profile_event_unused[0]), .requires_modrm(profile_event_unused[1]),
        .requires_outcome(profile_event_unused[2]), .requires_count(profile_event_unused[3]),
        .requires_target_length(profile_event_unused[4]), .base_clocks(profile_event_base),
        .repeat_setup_clocks(profile_event_repeat_setup),
        .repeat_iteration_clocks(profile_event_repeat_iteration),
        .permits_read_wait(profile_event_metadata_read_wait), .ea_clocks(profile_event_ea)
    );
    assign profile_execution_metadata_valid = profile_delivery_metadata ?
        profile_event_metadata_valid : profile_instruction_metadata_valid;
    assign profile_execution_metadata_read_wait = profile_delivery_metadata ?
        profile_event_metadata_read_wait : profile_instruction_metadata_read_wait;
    assign profile_execution_metadata_clocks = profile_delivery_metadata ? profile_event_base :
        profile_metadata_budget(profile_execution_base, profile_execution_repeat_setup,
            profile_execution_repeat_iteration, profile_execution_ea, profile_execution_repeated,
            profile_repeat_nonempty_q, 1'b0, profile_prefix_count_q);

    // Odd corrections belong to each real original word reference, before the
    // BIU decomposes it into lanes. RMW therefore obtains READ +2 and WRITE +2.
    assign profile_alignment_event = historical_enable &&
        memory_request && memory_request_ready && !memory_byte && memory_address[0];
    assign profile_metadata_estimated = profile_family_estimated || profile_target_fault_estimated ||
        (!profile_delivery_metadata && profile_prefix_count_q != 0 &&
         (!profile_repeated_string || profile_prefix_count_q > 1));
    assign profile_metadata_clocks = profile_metadata_budget(profile_base_clocks,
        profile_repeat_setup, profile_repeat_iteration, profile_ea_clocks,
        profile_repeated_string,
        profile_candidate_body ? register_state[16 +: 16] != 0 : profile_repeat_nonempty_q,
        profile_delivery_metadata, profile_prefix_count_q);
    assign profile_preserve_cancel = !restart && event_cancel && event_active && event_software;
    assign profile_start_interval =
        ((!context_active && (prefix_accept || opcode_start)) ||
         (event_dispatch && !event_software));
    assign profile_start_body = opcode_start || (event_dispatch && !event_software);
    assign profile_repeat_more = repeat_kind != 0 && register_state[16 +: 16] != 0 &&
        (!string_compare || (debug_flags[6] == (repeat_kind == 2'd2)));
    assign profile_repeat_empty = profile_raw_operation_valid && repeat_kind != 0 &&
        micro_word == spk286_microcode_pkg::MC_BRANCH_REPEAT_EMPTY && register_state[16 +: 16] != 0;
    assign profile_repeat_continue = profile_raw_operation_valid && profile_repeat_more &&
        micro_word == spk286_microcode_pkg::MC_BRANCH_REPEAT_CONTINUE;
    assign profile_repeat_permit = !historical_enable ||
        (!(profile_repeat_empty || profile_repeat_continue) ||
         (cpu_boundary && (!profile_repeat_continue || profile_deadline_ready)));
    assign operation_valid = profile_raw_operation_valid && profile_repeat_permit;
    assign profile_repeat_checkpoint = historical_enable && repeat_boundary && repeat_stepped;
    assign decode_ready = profile_decode_ready &&
                          (!historical_enable || event_active || profile_head_permit);
    assign profile_async_enable = !historical_enable ||
        // Idle event selection stays at fabric speed so an edge coinciding
        // with acceptance of an older pending NMI preserves the original latch.
        // The original events/context boundary still excludes an active body;
        // dispatch starts the new budget and bus/retirement remain qualified.
        !profile_active ||
        (cpu_boundary && (!profile_active || profile_retire_fire || repeat_boundary));

    spk286_instruction_schedule profile_schedule (
        .clk(clk), .reset(reset), .historical_enable(historical_enable),
        .cpu_boundary(cpu_boundary), .cancel(semantic_cancel),
        .preserve_cancel(profile_preserve_cancel),
        .start_interval(profile_start_interval), .start_body(profile_start_body),
        .metadata_valid(profile_metadata_valid),
        .metadata_freeze(raw_retired || (software_taken && event_request)),
        .metadata_clocks(profile_metadata_clocks),
        .execution_metadata_valid(profile_execution_metadata_valid),
        .execution_metadata_clocks(profile_execution_metadata_clocks),
        .execution_read_wait_event(timing_read_wait_event && profile_execution_metadata_read_wait),
        .target_length_ready(profile_target_length_ready),
        .target_length_clocks(profile_target_length_clocks),
        .read_wait_event(timing_read_wait_event && profile_metadata_read_wait),
        .alignment_event(profile_alignment_event), .functional_retired(raw_retired),
        .repeat_checkpoint(profile_repeat_checkpoint), .repeat_next_clocks(profile_repeat_iteration),
        .active(profile_active), .body_active(profile_body_active),
        .retire_pending(profile_retire_pending), .head_permit(profile_head_permit),
        .deadline_ready(profile_deadline_ready), .retire_fire(profile_retire_fire),
        .elapsed_clocks(profile_elapsed), .scheduled_clocks(profile_scheduled),
        .implementation_extension(profile_implementation_extension)
    );

    always_ff @(posedge clk) begin
        if (reset || semantic_cancel || !historical_enable) begin
            profile_branch_known_q <= 1'b0; profile_branch_taken_q <= 1'b0;
            profile_count_known_q <= 1'b0; profile_count_q <= 5'd0;
            profile_repeat_nonempty_q <= 1'b0;
            profile_prefix_count_q <= 4'd0; profile_normal_retired_q <= 1'b0;
        end else begin
            // Preserve the public one-fabric-edge retirement pulse convention.
            profile_normal_retired_q <= profile_retire_fire && !event_active;
            if (profile_retire_fire) begin
                profile_prefix_count_q <= 4'd0;
                profile_branch_known_q <= 1'b0;
                profile_count_known_q <= 1'b0;
            end
            if (profile_real_prefix && profile_prefix_count_q != 4'd15)
                profile_prefix_count_q <= profile_prefix_count_q + 4'd1;
            if (opcode_start) begin
                profile_repeat_nonempty_q <= register_state[16 +: 16] != 0;
                // INTO uses REQUEST_EVENT, never REDIRECT. Its real condition
                // must be qualified before either software handoff or END.
                profile_branch_known_q <= queue_consume_data == 8'hCE;
                profile_branch_taken_q <= queue_consume_data == 8'hCE && debug_flags[11];
                profile_count_known_q <= !(queue_consume_data == 8'hC0 ||
                    queue_consume_data == 8'hC1 || queue_consume_data == 8'hC8);
                profile_count_q <= queue_consume_data == 8'hD0 || queue_consume_data == 8'hD1 ?
                                   5'd1 : register_state[16 +: 5];
            end
            if (operation_valid && micro_word == spk286_microcode_pkg::MC_REDIRECT) begin
                profile_branch_known_q <= 1'b1;
                profile_branch_taken_q <= branch_taken;
            end
            if (operation_valid && micro_word == spk286_microcode_pkg::MC_FETCH_IMM8_TMP1 &&
                queue_consume_valid && executor_byte_ready &&
                (opcode_q == 8'hC0 || opcode_q == 8'hC1 || opcode_q == 8'hC8)) begin
                profile_count_known_q <= 1'b1; profile_count_q <= queue_consume_data[4:0];
            end
        end
    end
'''


def build(out):
    out = Path(out)
    for name, expected in ORIGINALS.items():
        if sha(ROOT / name) != FUNCTIONAL_UPDATES.get(name, expected):
            raise ValueError(f"Frozen production source changed: {name}")
    # Unchanged pilot dependencies retain their frozen hashes. Production
    # updates are named and pinned independently, leaving old receipts intact.
    prior = json.loads((ROOT / "docs/evidence/p06-core-register-20261004/observation/receipt.json").read_text())
    for name, expected in prior["sources_sha256"].items():
        if name.startswith("vendor/spk286/") and sha(ROOT / name) != FUNCTIONAL_UPDATES.get(name, expected):
            raise ValueError(f"Frozen functional dependency changed: {name}")
    out.mkdir(parents=True, exist_ok=True)
    top = (ROOT / "vendor/spk286/rtl/spk286.sv").read_text()
    top = replace_once(top, "module spk286 (", "module spk286_profiled (")
    top = replace_once(top, "    input  logic         reset,", "    input  logic         reset,\n"
        "    input  logic         historical_enable, cpu_boundary, timing_read_wait_event,\n"
        "    input  logic         profile_change_pending,\n"
        "    output logic         profile_change_ready,")
    top = replace_once(top, "    // A CS reload requires", CONNECTION + "\n    // A CS reload requires")
    top = replace_once(top, 'assign execution_allowed = execute_enable && commit_allowed',
                       'assign execution_allowed = execute_enable && !profile_change_hold && commit_allowed')
    top = replace_once(top, 'assign fetch_request_internal = execute_enable && !event_active',
                       'assign fetch_request_internal = execute_enable && !profile_change_hold && !event_active')
    top = replace_once(top, "    spk286_micro_executor #(",
        "    spk286_profiled_micro_executor #(")
    top = replace_once(top,
        ".operation_valid(operation_valid), .operation(micro_word), .operation_done(executor_done),",
        ".operation_valid(operation_valid), .implementation_operation_valid(profile_raw_operation_valid),\n"
        "        .operation(micro_word), .operation_done(executor_done),")
    top = replace_once(top, ".start_ready(decode_ready),", ".start_ready(profile_decode_ready),")
    top = replace_once(top,
        ".consume_valid(queue_consume_valid), .consume_data(queue_consume_data),\n"
        "        .consume_ready(queue_consume_ready), .count(queue_count)",
        ".consume_valid(profile_native_queue_valid), .consume_data(profile_native_queue_data),\n"
        "        .consume_ready(profile_native_queue_ready), .count(queue_count)")
    top = replace_once(top, ".operation_valid(operation_valid), .active(micro_active),",
        ".operation_valid(profile_raw_operation_valid), .active(micro_active),")
    top = replace_once(top, ".complete(raw_retired || event_completed),",
        ".complete(profile_retire_fire || event_completed),")
    top = replace_once(top, "assign protected_fetch_fault = protected_fetch_invalid && execution_allowed && !event_active && !micro_active;",
        "assign protected_fetch_fault = protected_fetch_invalid && execution_allowed && !event_active && !micro_active &&\n"
        "                                   (!historical_enable || profile_head_permit);")
    top = replace_once(top, "assign demanded_code_fault = execution_allowed && !event_active && !raw_retired && !event_completed &&",
        "assign demanded_code_fault = execution_allowed && !event_active && !raw_retired && !event_completed &&\n"
        "                                 (!historical_enable || micro_active || profile_head_permit) &&")
    top = replace_once(top, "assign instruction_retired = (raw_retired && !event_active) || (event_completed && event_software);",
        "assign instruction_retired = historical_enable ?\n"
        "        (profile_normal_retired_q || (event_completed && event_software)) :\n"
        "        ((raw_retired && !event_active) || (event_completed && event_software));")
    top = replace_once(top, "    spk286_events events (", "    spk286_profiled_events events (")
    top = replace_once(top, ".cancel(restart), .enable(execute_enable && commit_allowed && !reset && !restart),",
        ".cancel(restart), .enable(execute_enable && commit_allowed && !reset && !restart),\n"
        "        .historical_enable(historical_enable), .async_boundary_enable(profile_async_enable),")
    top = replace_once(top, ".instruction_active(micro_active || context_active),",
        ".instruction_active(micro_active || context_active || profile_active),")
    top = replace_once(top, ".retired(raw_retired), .opcode(queue_consume_data),",
        ".retired(profile_retire_fire), .opcode(queue_consume_data),")
    top = replace_once(top, ".halt_request(halt_request), .dispatch_ready(decode_ready),",
        ".halt_request(halt_request), .dispatch_ready(profile_decode_ready),")
    events = (ROOT / "vendor/spk286/rtl/spk286_events.sv").read_text()
    events = replace_once(events, "module spk286_events (", "module spk286_profiled_events (")
    events = replace_once(events, "    input logic clk, reset, cancel, enable,",
        "    input logic clk, reset, cancel, enable,\n"
        "    input logic historical_enable, async_boundary_enable,")
    events = replace_once(events,
        "assign boundary = (!instruction_active || repeat_boundary) && !event_active && !cancel_operation;",
        "assign boundary = (!instruction_active || (historical_enable && retired) || repeat_boundary) &&\n"
        "                      !event_active && !cancel_operation;")
    events = replace_once(events, "            end else if (boundary) begin",
        "            end else if (boundary && async_boundary_enable) begin")
    local_executor, local_contract = generate_local_repeat_executor(
        (ROOT / 'vendor/spk286/rtl/spk286_micro_executor.sv').read_text(),
        (ROOT / 'vendor/spk286/microcode/generated/spk286_microcode_pkg.sv').read_text())
    generated = {
        "spk286_profiled.sv": ("SPK286_PROFILED_SV", top),
        "spk286_profiled_events.sv": ("SPK286_PROFILED_EVENTS_SV", events),
        "spk286_profiled_micro_executor.sv": ("SPK286_PROFILED_MICRO_EXECUTOR_SV", local_executor),
    }
    selected = {}
    for name, (guard, body) in generated.items():
        path = out / name
        path.write_text(f"// Generated by scripts/build_p06_profile_cpu.py. Do not edit.\n"
                        f"`ifndef {guard}\n`define {guard}\n" + body + "\n`endif\n", newline="\n")
        selected[name] = path
    sources = {**{name: FUNCTIONAL_UPDATES.get(name, expected) for name, expected in prior["sources_sha256"].items()
                 if name.startswith("vendor/spk286/")},
        **ORIGINALS, **FUNCTIONAL_UPDATES, "scripts/build_p06_profile_cpu.py": sha(Path(__file__)),
        "rtl/spk286_timing/spk286_instruction_schedule.sv": sha(ROOT / "rtl/spk286_timing/spk286_instruction_schedule.sv"),
        "rtl/spk286_timing/spk286_target_handoff.sv": sha(ROOT / "rtl/spk286_timing/spk286_target_handoff.sv"),
        "rtl/spk286_timing/spk286_target_replay.sv": sha(ROOT / "rtl/spk286_timing/spk286_target_replay.sv"),
        "vendor/spk286/rtl/spk286_encoding_preview.sv": sha(ROOT / "vendor/spk286/rtl/spk286_encoding_preview.sv"),
        "vendor/spk286/tools/microcode/compile_microcode.py": sha(ROOT / "vendor/spk286/tools/microcode/compile_microcode.py"),
        "vendor/spk286/microcode/generated/spk286_microcode_validation.json": sha(ROOT / "vendor/spk286/microcode/generated/spk286_microcode_validation.json"),
        "rtl/spk286_timing/spk286_instruction_timing.sv": sha(ROOT / "rtl/spk286_timing/spk286_instruction_timing.sv"),
        "scripts/p06_repeat_local.py": sha(ROOT / "scripts/p06_repeat_local.py")}
    manifest = {"status": "PROFILED_CPU_GENERATED_NOT_ACCEPTED", "sources_sha256": sources,
        "generated_sha256": {name: sha(path) for name, path in selected.items()},
        "scope": "Single selected functional core with reserved READY chaining and historical source-retirement target encoding handoff; provisional instruction intervals and logical bus supplied by integration; private pilot evidence unchanged"}
    (out / "generation.json").write_text(json.dumps(manifest, indent=2) + "\n", newline="\n")
    (out / "repeat-local-contract.json").write_text(json.dumps(local_contract, indent=2) + "\n", newline="\n")
    return selected


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "vendor/spk286/rtl/timed")
    args = parser.parse_args()
    for name, path in build(args.output).items():
        print(name, sha(path))
