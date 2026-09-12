// IBM AT system control port B, 61h (separate from the 8042 at 60h/64h).
// Write bits 3/2: disable and clear channel-check / RAM parity latches.
// Read bits 7/6: RAM parity / channel-check; 5: OUT2; 4: refresh toggle.
// Bits 1/0: speaker data enable / GATE2. Upper write bits have no effect.
`timescale 1ns/1ps
module spk286_at_system_control (
    input logic clk, reset,
    input logic request_valid, request_command_valid, request_write, request_io,
    input logic [23:0] request_address,
    input logic [1:0] request_byte_enable,
    input logic [15:0] request_data_out,
    output logic request_accept, request_ready,
    output logic [15:0] request_read_data,
    output logic request_read_data_valid,
    input logic timer_1_out, timer_2_out, parity_event, channel_check_event,
    output logic timer_2_gate, speaker_enable, check_pending,
    output logic [7:0] port_b,
    output logic protocol_error
);
    logic busy_q, read_q;
    logic [7:0] read_data_q;
    logic [3:0] control_q;
    logic parity_q, channel_q, refresh_q, timer_1_q;
    wire selected = request_valid && request_command_valid && request_io && request_address[15:0]==16'h61;
    wire write_control = request_accept && request_write;
    wire [3:0] controls = write_control ? request_data_out[11:8] : control_q;
    assign request_accept = selected && !busy_q && request_byte_enable==2'b10;
    assign request_ready = busy_q;
    assign request_read_data_valid = busy_q && read_q;
    assign request_read_data = {read_data_q,8'h00};
    assign timer_2_gate = control_q[0];
    assign speaker_enable = control_q[1];
    assign check_pending = parity_q || channel_q;
    assign port_b = {parity_q,channel_q,timer_2_out,refresh_q,control_q};
    always_ff @(posedge clk) begin
        if(reset) begin
            busy_q<=0; read_q<=0; read_data_q<=0; control_q<=4'hc;
            parity_q<=0; channel_q<=0; refresh_q<=0; timer_1_q<=0;
            protocol_error<=0;
        end else begin
            busy_q <= request_accept;
            if(request_accept) begin
                read_q <= !request_write;
                read_data_q <= port_b;
                if(request_write) control_q <= request_data_out[11:8];
            end
            // Each refresh request from OUT1 changes the diagnostic toggle.
            // Physical SDRAM AUTO REFRESH remains independently scheduled.
            timer_1_q <= timer_1_out;
            if(timer_1_out && !timer_1_q) refresh_q <= ~refresh_q;
            if(controls[2]) parity_q <= 0;
            else if(parity_event) parity_q <= 1;
            if(controls[3]) channel_q <= 0;
            else if(channel_check_event) channel_q <= 1;
            if(selected && request_byte_enable!=2'b10) protocol_error<=1;
        end
    end
endmodule
