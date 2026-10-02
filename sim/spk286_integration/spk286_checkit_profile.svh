// Simulation-only observers, included inside spk286_checkit_workload_tb.
// No force, delayed signal assignment or production RTL instrumentation.
integer profile_enable = 0;
integer profile_bucket_cycles [0:6] = '{default:0};
integer profile_bucket_bus_wait [0:6] = '{default:0};
integer profile_bus_phase [0:4] = '{default:0};
integer profile_opcode_retired [0:255] = '{default:0};
integer profile_opcode_active [0:255] = '{default:0};
integer profile_micro_internal [0:spk286_microcode_pkg::MC_DEPTH-1] = '{default:0};
integer profile_latency_count [0:4] = '{default:0};
integer profile_latency_total [0:4] = '{default:0};
integer profile_latency_front [0:4] = '{default:0};
integer profile_latency_backend [0:4] = '{default:0};
integer profile_latency_return [0:4] = '{default:0};
integer profile_latency_max [0:4] = '{default:0};
integer profile_owner_count [0:2] = '{default:0};
integer profile_owner_latency [0:2] = '{default:0};
integer profile_queue_empty_not_demanded = 0;
integer profile_data_wait_for_code = 0;
integer profile_code_wait_for_data = 0;
integer profile_data_admission = 0;
integer profile_data_response = 0;
integer profile_code_transfers = 0;
integer profile_code_bytes = 0;
integer profile_consumed_bytes = 0;
integer profile_flushed_bytes = 0;
integer profile_redirects = 0;
integer profile_code_cancelled = 0;
integer profile_fast_register_ops = 0;
integer profile_owner_refresh_cycles = 0;
integer profile_transaction_start = -1;
integer profile_transaction_accept = -1;
integer profile_transaction_response = -1;
integer profile_transaction_kind = 0;
integer profile_owner_start = -1;
integer profile_owner_kind = 0;

function automatic string profile_bucket_name(input integer bucket);
    case (bucket)
        0: return "opcode_starved";
        1: return "instruction_byte_starved";
        2: return "operand_service";
        3: return "internal_microcode";
        4: return "dispatch_or_prefix";
        5: return "retirement_boundary";
        default: return "other";
    endcase
endfunction

function automatic string profile_transaction_name(input integer kind);
    case (kind)
        0: return "code_hit";
        1: return "code_miss";
        2: return "code_bypass";
        3: return "data_read";
        default: return "data_write";
    endcase
endfunction

task automatic profile_tick;
    integer bucket, phase, latency;
    logic opcode_demand, byte_demand, operand_demand;
    begin
        // Demand must be independent of queue valid. queue_consume_ready
        // alone cannot detect opcode starvation: opcode_start requires valid.
        opcode_demand = cpu.cpu.decode_ready && !cpu.cpu.event_active &&
            !cpu.cpu.event_request && !cpu.cpu.event_completed &&
            !cpu.cpu.raw_retired && !cpu.cpu.unsupported_q &&
            !cpu.cpu.length_fault && !cpu.cpu.queue_consume_valid;
        byte_demand = cpu.cpu.micro_active && cpu.cpu.executor_byte_ready &&
            !cpu.cpu.queue_consume_valid && !cpu.cpu.operation_done;
        operand_demand = cpu.cpu.micro_active && cpu.cpu.operand_request &&
            cpu.cpu.operand.is_memory && !cpu.cpu.operand_check &&
            !cpu.cpu.operand_done;
        if ((opcode_demand && byte_demand) ||
            (operand_demand && (opcode_demand || byte_demand)))
            $fatal(1, "PROFILE overlapping demand categories");
        if (opcode_demand) bucket = 0;
        else if (byte_demand) bucket = 1;
        else if (operand_demand) bucket = 2;
        else if (cpu.cpu.micro_active) bucket = 3;
        else if (cpu.cpu.opcode_start || cpu.cpu.prefix_accept) bucket = 4;
        else if (cpu.cpu.raw_retired) bucket = 5;
        else bucket = 6;
        profile_bucket_cycles[bucket]++;
        if (bus_valid && !ready) profile_bucket_bus_wait[bucket]++;
        if (prefetch_count == 0 && !opcode_demand && !byte_demand)
            profile_queue_empty_not_demanded++;
        if (operand_demand) begin
            if (bus_valid && bus_status == 4'hD) profile_data_wait_for_code++;
            if (!cpu.cpu.operand.pending_q) profile_data_admission++;
            else profile_data_response++;
        end
        if ((opcode_demand || byte_demand) && bus_valid && bus_status != 4'hD)
            profile_code_wait_for_data++;
        if (cpu.cpu.micro_active) profile_opcode_active[cpu.cpu.opcode_q]++;
        if (retired) profile_opcode_retired[cpu.cpu.opcode_q]++;
        if (bucket == 3) profile_micro_internal[cpu.cpu.micro_pc]++;
        if (cpu.cpu.operation_valid && cpu.cpu.operation_done && cpu.cpu.operation_retire)
            profile_fast_register_ops++;
        if (cpu.cpu.queue_consume_valid && cpu.cpu.queue_consume_ready)
            profile_consumed_bytes++;
        if (cpu.cpu.queue_flush) begin
            profile_redirects++;
            profile_flushed_bytes += int'(prefetch_count);
        end
        if (owner.kf_refresh_mode) profile_owner_refresh_cycles++;

        // These five bins partition bus_valid && !ready, not CPU stalls.
        if (bus_valid && !ready) begin
            if (bridge.state_q <= bridge.STATE_ADDRESS) phase = 0;
            else if (bridge.state_q == bridge.STATE_COMMAND) phase = 1;
            else if (bridge.state_q == bridge.STATE_WAIT && !at_ready) phase = 2;
            else if (bridge.state_q == bridge.STATE_WAIT && at_ready) phase = 3;
            else phase = 4;
            profile_bus_phase[phase]++;
        end

        // One CPU bus transaction at a time; timestamps are sampling edges.
        // Completion minus start equals the number of preceding wait edges.
        if (bus_valid && profile_transaction_start < 0) begin
            profile_transaction_start = cycles;
            profile_transaction_accept = -1;
            profile_transaction_response = -1;
            profile_transaction_kind = bus_status == 4'hD ? 2 : bus_write ? 4 : 3;
        end
        if (at_command && at_accept) begin
            if (profile_transaction_start < 0 || profile_transaction_accept >= 0)
                $fatal(1, "PROFILE unexpected AT acceptance (requires native words)");
            profile_transaction_accept = cycles;
            if (at_code && p03_enable != 0)
                profile_transaction_kind = p03_buffer.cache_hit ? 0 : 1;
        end
        if (bridge.completion_valid) profile_transaction_response = cycles;
        if (bus_valid && ready) begin
            if (profile_transaction_start < 0 || profile_transaction_accept < 0 ||
                profile_transaction_response < 0)
                $fatal(1, "PROFILE completion without full transaction history");
            latency = cycles - profile_transaction_start;
            profile_latency_count[profile_transaction_kind]++;
            profile_latency_total[profile_transaction_kind] += latency;
            profile_latency_front[profile_transaction_kind] +=
                profile_transaction_accept - profile_transaction_start;
            profile_latency_backend[profile_transaction_kind] +=
                profile_transaction_response - profile_transaction_accept;
            profile_latency_return[profile_transaction_kind] +=
                cycles - profile_transaction_response;
            if (latency > profile_latency_max[profile_transaction_kind])
                profile_latency_max[profile_transaction_kind] = latency;
            if (bus_status == 4'hD) begin
                profile_code_transfers++;
                profile_code_bytes += (!address[0] && !bus_bhe_n) ? 2 : 1;
                if (cpu.cpu.fetch.canceled_q || cpu.cpu.stream_restart)
                    profile_code_cancelled++;
            end
            profile_transaction_start = -1;
        end
        if (memory_out_command && memory_out_accept) begin
            if (profile_owner_start >= 0) $fatal(1, "PROFILE owner overlap");
            profile_owner_start = cycles;
            profile_owner_kind = memory_out_write ? 2 : memory_out_burst ? 0 : 1;
        end
        if (memory_out_ready) begin
            if (profile_owner_start < 0) $fatal(1, "PROFILE owner orphan response");
            profile_owner_count[profile_owner_kind]++;
            profile_owner_latency[profile_owner_kind] += cycles-profile_owner_start;
            profile_owner_start = -1;
        end
    end
endtask

task automatic profile_report;
    integer total, wait_total, bus_total, transfers;
    logic [63:0] memory_hash;
    begin
        total = 0; wait_total = 0; bus_total = 0; transfers = 0;
        for (integer i = 0; i < 7; i++) begin
            total += profile_bucket_cycles[i];
            wait_total += profile_bucket_bus_wait[i];
            $display("PROFILE_CPU bucket=%s cycles=%0d bus_wait_overlap=%0d",
                profile_bucket_name(i), profile_bucket_cycles[i], profile_bucket_bus_wait[i]);
        end
        for (integer i = 0; i < 5; i++) begin
            bus_total += profile_bus_phase[i];
            transfers += profile_latency_count[i];
            if (profile_latency_total[i] != profile_latency_front[i] +
                profile_latency_backend[i] + profile_latency_return[i])
                $fatal(1, "PROFILE latency sum mismatch");
            $display("PROFILE_BUS phase=%0d cycles=%0d", i, profile_bus_phase[i]);
            $display("PROFILE_LATENCY kind=%s count=%0d total=%0d front=%0d backend=%0d return=%0d max=%0d",
                profile_transaction_name(i), profile_latency_count[i], profile_latency_total[i],
                profile_latency_front[i], profile_latency_backend[i], profile_latency_return[i],
                profile_latency_max[i]);
        end
        if (total != cycles || wait_total != external_wait || bus_total != external_wait ||
            transfers != reads + writes)
            $fatal(1, "PROFILE accounting mismatch");
        for (integer i = 0; i < 3; i++)
            $display("PROFILE_OWNER kind=%0d count=%0d latency=%0d",
                i, profile_owner_count[i], profile_owner_latency[i]);
        for (integer i = 0; i < 256; i++)
            if (profile_opcode_retired[i] != 0 || profile_opcode_active[i] != 0)
                $display("PROFILE_OPCODE opcode=%02x retired=%0d active=%0d",
                    8'(i), profile_opcode_retired[i], profile_opcode_active[i]);
        for (integer i = 0; i < spk286_microcode_pkg::MC_DEPTH; i++)
            if (profile_micro_internal[i] != 0)
                $display("PROFILE_MICRO pc=%0d internal=%0d", i, profile_micro_internal[i]);
        $display("PROFILE_MISC queue_empty_not_demanded=%0d data_wait_for_code=%0d code_wait_for_data=%0d data_admission=%0d data_response=%0d code_transfers=%0d code_bytes=%0d consumed_bytes=%0d flushed_bytes=%0d redirects=%0d cancelled_code=%0d fast_register_ops=%0d owner_refresh=%0d",
            profile_queue_empty_not_demanded, profile_data_wait_for_code, profile_code_wait_for_data,
            profile_data_admission, profile_data_response, profile_code_transfers, profile_code_bytes,
            profile_consumed_bytes, profile_flushed_bytes, profile_redirects, profile_code_cancelled,
            profile_fast_register_ops, profile_owner_refresh_cycles);
        $display("PROFILE_ACCOUNTING_PASS cycles=%0d external_wait=%0d transfers=%0d",
            total, wait_total, transfers);
        memory_hash = 64'hcbf29ce484222325;
        for (integer i = 0; i < dram.MEM_WORDS; i++) begin
            memory_hash = (memory_hash ^ {56'd0, dram.mem[i][7:0]}) * 64'h100000001b3;
            memory_hash = (memory_hash ^ {56'd0, dram.mem[i][15:8]}) * 64'h100000001b3;
        end
        $display("PROFILE_SIGNATURE gpr=%032h flags=%04h memory=%016h ideal_owner=%0d",
            gpr, cpu.cpu.debug_flags, memory_hash, ideal_owner_mode);
        $display("PROFILE_DATA_CACHE words=512 hits=%0d misses=%0d write_updates=%0d",
            data_cache_hits, data_cache_misses, data_cache_write_updates);
    end
endtask
