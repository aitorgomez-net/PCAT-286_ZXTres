// Reset-applied CPU profile selector on the common 50 MHz fabric clock.
// These outputs are synchronous enables, never generated clocks. The CPU
// timing policy must schedule instruction/bus milestones independently.
`timescale 1ns/1ps
`ifndef SPK286_AT_CPU_PROFILE_SV
`define SPK286_AT_CPU_PROFILE_SV
module spk286_at_cpu_profile (
    input  logic       clk,
    input  logic       reset,
    input  logic [2:0] requested,
    output logic [2:0] active,
    output logic       pending,
    output logic       historical,
    output logic       phase_enable,
    output logic       phase_two,
    output logic       cpu_boundary
);
    // Stable OSD encoding: an old configuration with zero new bits uses MAX.
    // 0=MAX, 1=6, 2=8, 3=10, 4=12.5, 5=16, 6=20, 7=25 MHz.
    logic [5:0] phase_accumulator_q;
    logic phase_parity_q;
    logic [2:0] requested_normalized;
    logic [5:0] phase_increment;
    wire [6:0] phase_sum = {1'b0, phase_accumulator_q} +
                          {1'b0, phase_increment};
    wire phase_carry = phase_sum >= 7'd50;

    // Omitted legacy fixture ports must resolve to MAX in four-state
    // simulation. Every real three-bit hardware encoding is valid.
    always_comb begin
        case (requested)
            3'd0, 3'd1, 3'd2, 3'd3, 3'd4, 3'd5, 3'd6, 3'd7:
                requested_normalized = requested;
            default: requested_normalized = 3'd0;
        endcase
    end

    always_comb begin
        case (active)
            3'd1: phase_increment = 6'd12;
            3'd2: phase_increment = 6'd16;
            3'd3: phase_increment = 6'd20;
            3'd4: phase_increment = 6'd25;
            3'd5: phase_increment = 6'd32;
            3'd6: phase_increment = 6'd40;
            3'd7: phase_increment = 6'd50;
            default: phase_increment = 6'd0;
        endcase
    end

    assign pending = requested_normalized != active;
    assign historical = active != 3'd0;
    assign phase_enable = !reset && historical && phase_carry;
    assign phase_two = phase_enable && phase_parity_q;
    // MAX has no historical phase interpretation or imposed CPU delay.
    assign cpu_boundary = !reset && (!historical || phase_two);

    always_ff @(posedge clk) begin
        if (reset) begin
            active <= requested_normalized;
            phase_accumulator_q <= 6'd0;
            phase_parity_q <= 1'b0;
        end else if (historical) begin
            phase_accumulator_q <= phase_carry ?
                6'(phase_sum - 7'd50) : phase_sum[5:0];
            if (phase_carry) phase_parity_q <= !phase_parity_q;
        end else begin
            phase_accumulator_q <= 6'd0;
            phase_parity_q <= 1'b0;
        end
    end
endmodule
`endif
