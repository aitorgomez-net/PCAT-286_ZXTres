// Normalized AT serial devices.
//
// The source profile uses the 16750 UART implementation for COM1/COM2 and a
// small MPU-401 front end for the MIDI port at 330h.  This adapter presents
// those devices to the serialized AT bus used by the SPK286 profile.  The
// Quartus build uses the imported source UART/MPU blocks; simulation opts into
// the compact SystemVerilog model below so the AT regressions remain
// tool-neutral.  Do not key this on SYNTHESIS: Quartus does not guarantee that
// preprocessor symbol, and silently selecting the model in the bitstream makes
// the MPU appear to work in simulation while no real MIDI UART is synthesized.
`timescale 1ns/1ps

`ifndef ENABLE_MIDI
`define ENABLE_MIDI 0
`endif

module spk286_at_serial #(
    parameter bit MPU_MODE = 1'b0
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        baudce,
    input  logic        request_valid,
    input  logic        request_command_valid,
    input  logic        request_write,
    input  logic        request_io,
    input  logic [23:0] request_address,
    input  logic [1:0]  request_byte_enable,
    input  logic [15:0] request_data_out,
    output logic        request_accept,
    output logic        request_ready,
    output logic [15:0] request_read_data,
    output logic        request_read_data_valid,
    input  logic        rx,
    input  logic        cts_n,
    input  logic        dsr_n,
    input  logic        dcd_n,
    output logic        tx,
    output logic        rts_n,
    output logic        dtr_n,
    output logic        irq,
    output logic [15:0] side_effect_count,
    output logic        protocol_error
);
    logic active_q;
    logic issued_q;
    logic request_seen_q;
    logic write_q;
    logic read_q;
    logic [2:0] address_q;
    logic [1:0] byte_enable_q;
    logic [7:0] data_out_q;
    logic       init_done_q;
    logic [6:0] init_count_q;
    logic       lane_valid;
    logic [7:0] core_readdata;

    assign lane_valid = ((request_address[0] == 1'b0) &&
                         (request_byte_enable == 2'b01)) ||
                        ((request_address[0] == 1'b1) &&
                         (request_byte_enable == 2'b10));

    // MPU-401 reset-time UART setup is performed by the imported mpu401
    // block. Keep its ISA ports quiescent for the same short interval in the
    // normalized endpoint, so an early BIOS probe cannot race that setup.
    assign request_accept = !active_q && !request_seen_q && init_done_q && lane_valid &&
                            request_valid && request_command_valid &&
                            request_io;
    assign request_ready = active_q && issued_q;
    assign request_read_data = byte_enable_q[1] ?
                               {core_readdata, 8'h00} :
                               {8'h00, core_readdata};
    assign request_read_data_valid = request_ready && read_q;
    assign side_effect_count = 16'h0000;
    assign protocol_error = 1'b0;

    always_ff @(posedge clk) begin
        if (reset) begin
            active_q     <= 1'b0;
            issued_q     <= 1'b0;
            request_seen_q <= 1'b0;
            write_q      <= 1'b0;
            read_q       <= 1'b0;
            address_q    <= 3'b000;
            byte_enable_q <= 2'b00;
            data_out_q   <= 8'h00;
            init_count_q <= 7'd0;
            init_done_q  <= !MPU_MODE;
        end else begin
            if (!request_valid)
                request_seen_q <= 1'b0;
            if (!init_done_q) begin
                if (init_count_q == 7'd63)
                    init_done_q <= 1'b1;
                else
                    init_count_q <= init_count_q + 1'b1;
            end

            if (!active_q) begin
                if (request_accept) begin
                    active_q      <= 1'b1;
                    request_seen_q <= 1'b1;
                    issued_q      <= 1'b0;
                    write_q       <= request_write;
                    read_q        <= !request_write;
                    address_q     <= MPU_MODE ?
                                     {2'b00, request_address[0]} :
                                     request_address[2:0];
                    byte_enable_q <= request_byte_enable;
                    data_out_q    <= request_byte_enable[1] ?
                                     request_data_out[15:8] :
                                     request_data_out[7:0];
                end
            end else if (!issued_q) begin
                // The core sees a one-clock CS/read/write pulse while the
                // endpoint remains active for the following READY interval.
                issued_q <= 1'b1;
            end else begin
                active_q <= 1'b0;
            end
        end
    end

    wire core_cs = active_q && !issued_q;
    wire core_wr = core_cs && write_q;
    wire core_rd = core_cs && read_q;

`ifndef SPK286_AT_SIM_MODEL
    generate
        if (MPU_MODE) begin : GEN_MPU_SOURCE
            mpu401 u_mpu401 (
                .clk      (clk),
                .reset    (reset),
                .baudce   (baudce),
                .address  (address_q[0]),
                .write    (core_wr),
                .writedata(data_out_q),
                .read     (core_rd),
                .readdata (core_readdata),
                .cs       (core_cs),
                .midi_tx  (tx),
                .midi_rx  (rx),
                .irq      (irq)
            );
            assign rts_n = 1'b1;
            assign dtr_n = 1'b1;
        end else begin : GEN_UART_SOURCE
            uart u_uart (
                .clk      (clk),
                .reset    (reset),
                .address  (address_q),
                .write    (core_wr),
                .writedata(data_out_q),
                .read     (core_rd),
                .readdata (core_readdata),
                .cs       (core_cs),
                .br_clk   (baudce),
                .rx       (rx),
                .tx       (tx),
                .cts_n    (cts_n),
                .dcd_n    (dcd_n),
                .dsr_n    (dsr_n),
                .ri_n     (1'b1),
                .rts_n    (rts_n),
                .br_out   (),
                .dtr_n    (dtr_n),
                .irq      (irq)
            );
        end
    endgenerate
`else
    spk286_at_serial_model #(
        .MPU_MODE(MPU_MODE)
    ) u_serial_model (
        .clk      (clk),
        .reset    (reset),
        .baudce   (baudce),
        .address  (address_q),
        .write    (core_wr),
        .writedata(data_out_q),
        .read     (core_rd),
        .readdata (core_readdata),
        .cs       (core_cs),
        .rx       (rx),
        .cts_n    (cts_n),
        .dsr_n    (dsr_n),
        .dcd_n    (dcd_n),
        .tx       (tx),
        .rts_n    (rts_n),
        .dtr_n    (dtr_n),
        .irq      (irq)
    );
`endif
endmodule

// A small, deterministic 8N1 UART model for Icarus/Verilator. It covers the
// registers used by DOS serial and MPU-401 UART-mode drivers, including TX,
// RX, modem outputs, status and interrupt generation. The FPGA build selects
// the source 16750/MPU implementation above.
module spk286_at_serial_model #(
    parameter bit MPU_MODE = 1'b0
) (
    input  logic       clk,
    input  logic       reset,
    input  logic       baudce,
    input  logic [2:0] address,
    input  logic       write,
    input  logic [7:0] writedata,
    input  logic       read,
    output logic [7:0] readdata,
    input  logic       cs,
    input  logic       rx,
    input  logic       cts_n,
    input  logic       dsr_n,
    input  logic       dcd_n,
    output logic       tx,
    output logic       rts_n,
    output logic       dtr_n,
    output logic       irq
);
    logic [7:0] rx_data_q;
    logic       rx_ready_q;
    logic [7:0] ier_q;
    logic [7:0] lcr_q;
    logic [7:0] mcr_q;
    logic [7:0] scr_q;
    logic [7:0] divisor_lo_q;
    logic [7:0] divisor_hi_q;
    logic       tx_busy_q;
    logic [9:0] tx_shift_q;
    logic [3:0] tx_bit_q;
    logic       mpu_ack_q;
    logic       mpu_dumb_q;

    logic       rx_prev_q;
    logic       rx_busy_q;
    logic [3:0] rx_tick_q;
    logic [3:0] rx_bit_q;
    logic [7:0] rx_shift_q;

    wire tx_ready = !tx_busy_q;
    wire rx_irq = rx_ready_q;
    wire mpu_rx_ready = rx_ready_q & mpu_dumb_q;

    assign rts_n = !mcr_q[1];
    assign dtr_n = !mcr_q[0];
    // Command ACKs are polled from the MPU data/status ports.  Only received
    // MIDI bytes raise IRQ9 after the 3Fh UART-mode command, so enabling the
    // card cannot strand a running DOS/debug session in an unhandled IRQ.
    assign irq = MPU_MODE ? mpu_rx_ready :
                 ((ier_q[0] && rx_ready_q) || (ier_q[1] && tx_ready));

    always_ff @(posedge clk) begin
        if (reset) begin
            rx_data_q    <= 8'h00;
            rx_ready_q   <= 1'b0;
            ier_q        <= 8'h00;
            lcr_q        <= 8'h03;
            mcr_q        <= 8'h00;
            scr_q        <= 8'h00;
            divisor_lo_q <= 8'h01;
            divisor_hi_q <= 8'h00;
            tx_busy_q    <= 1'b0;
            tx_shift_q   <= 10'h3ff;
            tx_bit_q     <= 4'd0;
            tx           <= 1'b1;
            readdata     <= 8'h00;
            mpu_ack_q    <= 1'b0;
            mpu_dumb_q   <= 1'b0;
            rx_prev_q    <= 1'b1;
            rx_busy_q    <= 1'b0;
            rx_tick_q    <= 4'd0;
            rx_bit_q     <= 4'd0;
            rx_shift_q   <= 8'h00;
        end else begin
            if (cs && write) begin
                if (MPU_MODE) begin
                    if (!address[0]) begin
                        tx_shift_q <= {1'b1, writedata, 1'b0};
                        tx_bit_q   <= 4'd0;
                        tx_busy_q  <= 1'b1;
                        tx         <= 1'b0;
                    end else begin
                        mpu_ack_q <= !mpu_dumb_q;
                        if (writedata == 8'hff)
                            mpu_dumb_q <= 1'b0;
                        if (writedata == 8'h3f)
                            mpu_dumb_q <= 1'b1;
                    end
                end else begin
                    case (address)
                        3'd0: begin
                            if (lcr_q[7])
                                divisor_lo_q <= writedata;
                            else begin
                                tx_shift_q <= {1'b1, writedata, 1'b0};
                                tx_bit_q   <= 4'd0;
                                tx_busy_q  <= 1'b1;
                                tx         <= 1'b0;
                            end
                        end
                        3'd1: if (lcr_q[7]) divisor_hi_q <= writedata;
                              else ier_q <= writedata;
                        3'd3: lcr_q <= writedata;
                        3'd4: mcr_q <= writedata;
                        3'd7: scr_q <= writedata;
                        default: ;
                    endcase
                end
            end

            if (cs && read) begin
                if (MPU_MODE) begin
                    if (address[0])
                        readdata <= {!(mpu_ack_q | mpu_rx_ready),
                                     !tx_ready, 6'd0};
                    else
                        readdata <= mpu_ack_q ? 8'hfe : rx_data_q;
                    // A status read only observes the pending command ACK.
                    // MPU-401 consumes that ACK on the following data-port
                    // read; clearing it here makes the normal poll sequence
                    // (poll 331h, then read FEh from 330h) return stale data.
                    if (!address[0] && mpu_ack_q)
                        mpu_ack_q <= 1'b0;
                    else if (!address[0])
                        rx_ready_q <= 1'b0;
                end else begin
                    case (address)
                        3'd0: begin
                            readdata <= lcr_q[7] ? divisor_lo_q : rx_data_q;
                            if (!lcr_q[7])
                                rx_ready_q <= 1'b0;
                        end
                        3'd1: readdata <= lcr_q[7] ? divisor_hi_q : ier_q;
                        3'd2: readdata <= rx_ready_q ? 8'hc4 :
                                                  tx_ready ? 8'hc2 : 8'hc1;
                        3'd3: readdata <= lcr_q;
                        3'd4: readdata <= mcr_q;
                        3'd5: readdata <= {1'b0, 1'b0, tx_ready, tx_ready,
                                             1'b0, 1'b0, 1'b0, rx_ready_q};
                        3'd6: readdata <= {dcd_n, 1'b0, dsr_n, cts_n,
                                             1'b0, 1'b0, 1'b0, 1'b0};
                        3'd7: readdata <= scr_q;
                        default: readdata <= 8'hff;
                    endcase
                end
            end

            if (baudce && tx_busy_q) begin
                tx_shift_q <= {1'b1, tx_shift_q[9:1]};
                if (tx_bit_q == 4'd9) begin
                    tx_busy_q <= 1'b0;
                    tx        <= 1'b1;
                end else begin
                    tx_bit_q <= tx_bit_q + 1'b1;
                    tx        <= tx_shift_q[1];
                end
            end

            rx_prev_q <= rx;
            if (!rx_busy_q) begin
                if (rx_prev_q && !rx) begin
                    rx_busy_q <= 1'b1;
                    rx_tick_q <= 4'd0;
                    rx_bit_q  <= 4'd0;
                end
            end else if (baudce) begin
                if (rx_bit_q == 4'd0) begin
                    if (rx_tick_q == 4'd7) begin
                        if (rx) begin
                            rx_busy_q <= 1'b0;
                        end else begin
                            rx_tick_q <= 4'd0;
                            rx_bit_q  <= 4'd1;
                        end
                    end else begin
                        rx_tick_q <= rx_tick_q + 1'b1;
                    end
                end else if (rx_tick_q == 4'd15) begin
                    rx_tick_q <= 4'd0;
                    if (rx_bit_q <= 4'd8) begin
                        rx_shift_q[rx_bit_q - 1'b1] <= rx;
                        rx_bit_q <= rx_bit_q + 1'b1;
                    end else begin
                        if (rx) begin
                            rx_data_q  <= rx_shift_q;
                            rx_ready_q <= 1'b1;
                        end
                        rx_busy_q <= 1'b0;
                    end
                end else begin
                    rx_tick_q <= rx_tick_q + 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire
