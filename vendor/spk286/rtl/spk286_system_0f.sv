// Real-mode 80286 system instructions introduced by the 0F escape.
//
// This is intentionally a small, explicit service rather than a generic
// "accept every 0F" path.  The 286 uses 0F 01 /0-/6 for the descriptor-table
// and machine-status instructions that prepare protected mode.  The service
// performs the real memory transactions for the six-byte pseudo-descriptors;
// protected-mode descriptor checks remain a separate architectural block.
`timescale 1ns/1ps

module spk286_system_0f (
    input  logic        clk,
    input  logic        reset,
    input  logic        cancel,
    input  logic        start,
    input  logic        byte_valid,
    input  logic [7:0]  byte_data,
    output logic        byte_ready,
    output logic        active,
    output logic        retired,
    output logic        fault,
    output logic        decode_enable,
    input  logic        decode_done,
    input  logic        decode_byte_ready,
    input  logic [2:0]  operand_reg,
    input  logic [2:0]  operand_rm,
    input  logic        operand_register_direct,
    input  logic [15:0] operand_offset,
    input  logic [23:0] segment_base,
    input  logic [15:0] rm_read_data,
    input  logic [15:0] msw,
    input  logic [15:0] gdtr_limit,
    input  logic [23:0] gdtr_base,
    input  logic [15:0] idtr_limit,
    input  logic [23:0] idtr_base,
    output logic        gpr_write_en,
    output logic [2:0]  gpr_write_index,
    output logic [15:0] gpr_write_data,
    output logic        msw_write_en,
    output logic [15:0] msw_write_data,
    output logic        memory_request,
    input  logic        memory_request_ready,
    output logic        memory_write,
    output logic        memory_byte,
    output logic [23:0] memory_address,
    output logic [15:0] memory_write_data,
    input  logic        memory_response_valid,
    output logic        memory_response_ready,
    input  logic [15:0] memory_read_data,
    output logic        gdtr_write_en,
    output logic [15:0] gdtr_limit_data,
    output logic [23:0] gdtr_base_data,
    output logic        idtr_write_en,
    output logic [15:0] idtr_limit_data,
    output logic [23:0] idtr_base_data
);
    typedef enum logic [3:0] {
        S_IDLE, S_SECONDARY, S_DECODE, S_WRITE0, S_WRITE1, S_WRITE2,
        S_READ0, S_READ1, S_READ2, S_SMSW_REG, S_SMSW_MEM,
        S_LMSW_REG, S_LMSW_MEM, S_LMSW_COMMIT, S_DONE, S_FAULT
    } state_t;
    state_t state_q;
    logic [7:0] secondary_q;
    logic [2:0] operation_q;
    logic [15:0] temporary_q, limit_q;
    logic [23:0] base_low_q;
    logic pending_q;
    logic allowed;
    logic memory_state, write_state, read_state;

    assign allowed = !reset && !cancel;
    assign active = state_q != S_IDLE;
    assign retired = state_q == S_DONE;
    assign fault = state_q == S_FAULT;
    assign decode_enable = allowed && state_q == S_DECODE;
    assign byte_ready = allowed && ((state_q == S_SECONDARY) ||
                                    (state_q == S_DECODE && decode_byte_ready));

    assign memory_state = state_q == S_WRITE0 || state_q == S_WRITE1 ||
                          state_q == S_WRITE2 || state_q == S_SMSW_MEM ||
                          state_q == S_LMSW_MEM || state_q == S_READ0 ||
                          state_q == S_READ1 || state_q == S_READ2;
    assign write_state = state_q == S_WRITE0 || state_q == S_WRITE1 ||
                         state_q == S_WRITE2 || state_q == S_SMSW_MEM;
    assign read_state = state_q == S_READ0 || state_q == S_READ1 ||
                        state_q == S_READ2 || state_q == S_LMSW_MEM;
    assign memory_request = allowed && memory_state && !pending_q;
    assign memory_response_ready = allowed && memory_state && pending_q;
    assign memory_write = write_state;
    assign memory_byte = state_q == S_WRITE2 || state_q == S_READ2;
    assign memory_address = segment_base + {8'h00, operand_offset +
                           ((state_q == S_WRITE1 || state_q == S_READ1) ? 16'd2 :
                            ((state_q == S_WRITE2 || state_q == S_READ2) ? 16'd4 : 16'd0))};
    assign memory_write_data = state_q == S_WRITE0 ?
                               (operation_q == 3'd0 ? gdtr_limit : idtr_limit) :
                               state_q == S_WRITE1 ?
                               (operation_q == 3'd0 ? gdtr_base[15:0] : idtr_base[15:0]) :
                               state_q == S_WRITE2 ?
                               {8'h00, (operation_q == 3'd0 ? gdtr_base[23:16] : idtr_base[23:16])} :
                               msw;

    assign gpr_write_en = allowed && state_q == S_SMSW_REG;
    assign gpr_write_index = operand_rm;
    assign gpr_write_data = msw;
    assign msw_write_en = allowed && (state_q == S_LMSW_REG || state_q == S_LMSW_COMMIT);
    assign msw_write_data = state_q == S_LMSW_REG ? rm_read_data : temporary_q;

    // The final byte of the pseudo-descriptor is presented directly to the
    // architectural register writeback on the same edge as the BIU response.
    assign gdtr_write_en = allowed && state_q == S_READ2 && pending_q && memory_response_valid && operation_q == 3'd2;
    assign gdtr_limit_data = limit_q;
    assign gdtr_base_data = {memory_read_data[7:0], base_low_q[15:0]};
    assign idtr_write_en = allowed && state_q == S_READ2 && pending_q && memory_response_valid && operation_q == 3'd3;
    assign idtr_limit_data = limit_q;
    assign idtr_base_data = {memory_read_data[7:0], base_low_q[15:0]};

    always_ff @(posedge clk) begin
        if (reset || cancel) begin
            state_q <= S_IDLE;
            secondary_q <= 8'h00;
            operation_q <= 3'd0;
            temporary_q <= 16'h0000;
            limit_q <= 16'h0000;
            base_low_q <= 24'h000000;
            pending_q <= 1'b0;
        end else begin
            case (state_q)
                S_IDLE: if (start) state_q <= S_SECONDARY;
                S_SECONDARY: if (byte_valid && byte_ready) begin
                    secondary_q <= byte_data;
                    state_q <= byte_data == 8'h01 ? S_DECODE : S_FAULT;
                end
                S_DECODE: if (decode_done) begin
                    // 0F 01 /0-/3 are memory-only; /4 and /6 accept either
                    // a register or memory source.  /5 and /7 are undefined
                    // on the 80286 and must retain architectural #UD.
                    if (secondary_q != 8'h01 ||
                        (operand_reg != 3'd0 && operand_reg != 3'd1 &&
                         operand_reg != 3'd2 && operand_reg != 3'd3 &&
                         operand_reg != 3'd4 && operand_reg != 3'd6) ||
                        (operand_reg < 3'd4 && operand_register_direct)) begin
                        state_q <= S_FAULT;
                    end else begin
                        operation_q <= operand_reg;
                        case (operand_reg)
                            3'd0, 3'd1: state_q <= S_WRITE0;
                            3'd2, 3'd3: state_q <= S_READ0;
                            3'd4: state_q <= operand_register_direct ? S_SMSW_REG : S_SMSW_MEM;
                            default: state_q <= operand_register_direct ? S_LMSW_REG : S_LMSW_MEM;
                        endcase
                    end
                end
                S_WRITE0, S_WRITE1, S_WRITE2, S_SMSW_MEM,
                S_READ0, S_READ1, S_READ2, S_LMSW_MEM: begin
                    if (memory_request && memory_request_ready) pending_q <= 1'b1;
                    if (memory_response_ready && memory_response_valid) begin
                        pending_q <= 1'b0;
                        case (state_q)
                            S_WRITE0: state_q <= S_WRITE1;
                            S_WRITE1: state_q <= S_WRITE2;
                            S_WRITE2, S_SMSW_MEM: state_q <= S_DONE;
                            S_READ0: begin limit_q <= memory_read_data; state_q <= S_READ1; end
                            S_READ1: begin base_low_q[15:0] <= memory_read_data; state_q <= S_READ2; end
                            S_READ2: begin base_low_q[23:16] <= memory_read_data[7:0]; state_q <= S_DONE; end
                            S_LMSW_MEM: begin temporary_q <= memory_read_data; state_q <= S_LMSW_COMMIT; end
                            default: state_q <= S_FAULT;
                        endcase
                    end
                end
                S_SMSW_REG, S_LMSW_REG, S_LMSW_COMMIT: state_q <= S_DONE;
                S_DONE: state_q <= S_IDLE;
                default: state_q <= state_q;
            endcase
        end
    end
endmodule
