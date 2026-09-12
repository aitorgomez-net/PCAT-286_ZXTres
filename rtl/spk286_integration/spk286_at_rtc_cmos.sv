// IBM AT compatible MC146818 RTC/CMOS boundary.
//
// Port 70h selects one of 128 CMOS bytes and carries the NMI mask. Port 71h
// reads or writes the selected byte. MiSTer's hps_ext transport supplies the
// host date/time and CMOS defaults with writes in the F4xx management window,
// matching the convention used by the ao486 and z486 cores.
//
// The first AT memory profile contains exactly 1 MiB of RAM: 640 KiB at
// 000000h-09FFFFh plus 384 KiB at 100000h-15FFFFh. The corresponding CMOS
// fields are fixed here and included in the standard 10h-2Dh checksum.
`timescale 1ns/1ps

module spk286_at_rtc_cmos (
    input  logic        clk,
    input  logic        reset,

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

    input  logic [15:0] mgmt_address,
    input  logic [15:0] mgmt_writedata,
    input  logic        mgmt_write,

    input  logic        periodic_tick,
    input  logic        second_tick,
    output logic        irq8,
    output logic        nmi_mask,
    output logic [15:0] side_effect_count,
    output logic [6:0]  selected_index,
    output logic        protocol_error
);
    localparam logic IO_IDLE = 1'b0;
    localparam logic IO_DONE = 1'b1;

    localparam logic [7:0] CMOS_BASE_LOW       = 8'h80; // 640 KiB = 0280h
    localparam logic [7:0] CMOS_BASE_HIGH      = 8'h02;
    localparam logic [7:0] CMOS_EXTENDED_LOW   = 8'h80; // 384 KiB = 0180h
    localparam logic [7:0] CMOS_EXTENDED_HIGH  = 8'h01;
    localparam logic [15:0] CMOS_INITIAL_SUM   = 16'h0103;

    logic       io_state_q;
    logic [1:0] io_byte_enable_q;
    logic [7:0] io_read_data_q;
    logic       io_read_data_valid_q;
    logic [6:0] index_q;
    logic       nmi_mask_q;
    logic       irq8_q;
    logic       status_c_periodic_q;
    logic       status_c_alarm_q;
    logic       status_c_update_q;
    logic [15:0] checksum_q;
    logic [7:0] cmos_q [0:127];
    logic [7:0] request_byte;
    logic [7:0] current_read_data;
    logic       port_selected;
    logic       lane_valid;
    logic       cpu_data_write;
    logic       mgmt_rtc_write;
    integer i;

    function automatic logic [7:0] bcd_to_binary(input logic [7:0] value);
        begin
            bcd_to_binary = ({4'h0, value[7:4]} * 8'd10) +
                            {4'h0, value[3:0]};
        end
    endfunction

    function automatic logic [7:0] binary_to_bcd(input logic [7:0] value);
        logic [7:0] tens;
        logic [7:0] ones;
        begin
            tens = value / 8'd10;
            ones = value % 8'd10;
            binary_to_bcd = {tens[3:0], ones[3:0]};
        end
    endfunction

    function automatic logic [7:0] decode_number(
        input logic [7:0] value,
        input logic       binary_mode
    );
        begin
            decode_number = binary_mode ? value : bcd_to_binary(value);
        end
    endfunction

    function automatic logic [7:0] encode_number(
        input logic [7:0] value,
        input logic       binary_mode
    );
        begin
            encode_number = binary_mode ? value : binary_to_bcd(value);
        end
    endfunction

    function automatic logic [7:0] decode_hour(
        input logic [7:0] value,
        input logic       binary_mode,
        input logic       mode_24_hour
    );
        logic [7:0] hour_value;
        begin
            hour_value = decode_number({1'b0, value[6:0]}, binary_mode);
            if (mode_24_hour)
                decode_hour = hour_value;
            else if (value[7])
                decode_hour = (hour_value == 8'd12) ? 8'd12 :
                              hour_value + 8'd12;
            else
                decode_hour = (hour_value == 8'd12) ? 8'd0 : hour_value;
        end
    endfunction

    function automatic logic [7:0] encode_hour(
        input logic [7:0] value,
        input logic       binary_mode,
        input logic       mode_24_hour
    );
        logic [7:0] hour_12;
        logic [7:0] encoded_hour;
        begin
            if (mode_24_hour)
                encode_hour = encode_number(value, binary_mode);
            else begin
                if (value == 8'd0)
                    hour_12 = 8'd12;
                else if (value > 8'd12)
                    hour_12 = value - 8'd12;
                else
                    hour_12 = value;
                encoded_hour = encode_number(hour_12, binary_mode);
                encode_hour = {value >= 8'd12, encoded_hour[6:0]};
            end
        end
    endfunction

    function automatic logic is_checksum_address(input logic [6:0] address);
        begin
            is_checksum_address = (address >= 7'h10) && (address <= 7'h2D);
        end
    endfunction

    function automatic logic is_fixed_memory_address(input logic [6:0] address);
        begin
            is_fixed_memory_address = (address == 7'h15) ||
                                      (address == 7'h16) ||
                                      (address == 7'h17) ||
                                      (address == 7'h18) ||
                                      (address == 7'h30) ||
                                      (address == 7'h31) ||
                                      (address == 7'h34) ||
                                      (address == 7'h35);
        end
    endfunction

    function automatic logic alarm_field_matches(
        input logic [7:0] alarm_value,
        input logic [7:0] clock_value
    );
        begin
            alarm_field_matches = (alarm_value[7:6] == 2'b11) ||
                                  (alarm_value == clock_value);
        end
    endfunction

    function automatic logic [7:0] days_in_month(
        input logic [7:0] month_value,
        input logic [7:0] year_value,
        input logic [7:0] century_value
    );
        logic leap_year;
        begin
            // For a two-digit year, divisibility by four is carried by the
            // year byte. At xx00, Gregorian centuries are leap years only
            // when the century number itself is divisible by four.
            leap_year = (year_value[1:0] == 2'b00) &&
                        ((year_value != 8'd0) ||
                         (century_value[1:0] == 2'b00));
            case (month_value)
                8'd2: days_in_month = leap_year ? 8'd29 : 8'd28;
                8'd4, 8'd6, 8'd9, 8'd11: days_in_month = 8'd30;
                default: days_in_month = 8'd31;
            endcase
        end
    endfunction

    wire binary_mode = cmos_q[7'h0B][2];
    wire mode_24_hour = cmos_q[7'h0B][1];
    wire rtc_clock_running = !cmos_q[7'h0B][7] &&
                             (cmos_q[7'h0A][6:5] != 2'b11);
    wire [7:0] second_binary = decode_number(cmos_q[7'h00], binary_mode);
    wire [7:0] minute_binary = decode_number(cmos_q[7'h02], binary_mode);
    wire [7:0] hour_binary = decode_hour(cmos_q[7'h04], binary_mode,
                                         mode_24_hour);
    wire [7:0] weekday_binary = decode_number(cmos_q[7'h06], binary_mode);
    wire [7:0] day_binary = decode_number(cmos_q[7'h07], binary_mode);
    wire [7:0] month_binary = decode_number(cmos_q[7'h08], binary_mode);
    wire [7:0] year_binary = decode_number(cmos_q[7'h09], binary_mode);
    wire [7:0] century_binary = decode_number(cmos_q[7'h32], binary_mode);

    wire second_rollover = second_binary >= 8'd59;
    wire minute_rollover = second_rollover && (minute_binary >= 8'd59);
    wire hour_rollover = minute_rollover && (hour_binary >= 8'd23);
    wire day_rollover = hour_rollover &&
                        (day_binary >= days_in_month(month_binary,
                                                    year_binary,
                                                    century_binary));
    wire month_rollover = day_rollover && (month_binary >= 8'd12);
    wire year_rollover = month_rollover && (year_binary >= 8'd99);

    wire [7:0] next_second_clock = encode_number(
        second_rollover ? 8'd0 : second_binary + 8'd1, binary_mode);
    wire [7:0] next_minute_clock = minute_rollover ?
        encode_number(8'd0, binary_mode) :
        (second_rollover ? encode_number(minute_binary + 8'd1, binary_mode) :
                           cmos_q[7'h02]);
    wire [7:0] next_hour_clock = hour_rollover ?
        encode_hour(8'd0, binary_mode, mode_24_hour) :
        (minute_rollover ? encode_hour(hour_binary + 8'd1, binary_mode,
                                       mode_24_hour) : cmos_q[7'h04]);
    wire alarm_match_next_second =
        alarm_field_matches(cmos_q[7'h01], next_second_clock) &&
        alarm_field_matches(cmos_q[7'h03], next_minute_clock) &&
        alarm_field_matches(cmos_q[7'h05], next_hour_clock);

    always_comb begin
        port_selected = request_valid && request_command_valid && request_io &&
                        ((request_address[15:0] == 16'h0070) ||
                         (request_address[15:0] == 16'h0071));
        lane_valid = ((request_address[0] == 1'b0) &&
                      (request_byte_enable == 2'b01)) ||
                     ((request_address[0] == 1'b1) &&
                      (request_byte_enable == 2'b10));
        request_byte = request_byte_enable[1] ?
                       request_data_out[15:8] : request_data_out[7:0];
        selected_index = index_q;
        cpu_data_write = request_accept && request_write &&
                         (request_address[15:0] == 16'h0071);
        mgmt_rtc_write = mgmt_write &&
                         (mgmt_address[15:8] == 8'hF4) &&
                         !mgmt_address[7];

        if (request_address[15:0] == 16'h0070)
            current_read_data = {nmi_mask_q, index_q};
        else begin
            case (index_q)
                7'h0A: current_read_data = {1'b0, cmos_q[7'h0A][6:0]};
                7'h0C: current_read_data = {irq8_q,
                                            status_c_periodic_q,
                                            status_c_alarm_q,
                                            status_c_update_q,
                                            4'b0000};
                7'h0D: current_read_data = 8'h80;
                7'h15, 7'h16, 7'h17, 7'h18,
                7'h30, 7'h31, 7'h34, 7'h35:
                    current_read_data = cmos_q[index_q];
                7'h2E: current_read_data = checksum_q[15:8];
                7'h2F: current_read_data = checksum_q[7:0];
                7'h37: current_read_data = cmos_q[7'h32];
                default: current_read_data = cmos_q[index_q];
            endcase
        end
    end

    assign request_accept = (io_state_q == IO_IDLE) && port_selected &&
                            lane_valid;
    assign request_ready = (io_state_q == IO_DONE);
    assign request_read_data_valid = request_ready && io_read_data_valid_q;
    assign request_read_data = io_byte_enable_q[1] ?
                               {io_read_data_q, 8'h00} :
                               {8'h00, io_read_data_q};
    assign irq8 = irq8_q;
    assign nmi_mask = nmi_mask_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            io_state_q <= IO_IDLE;
            io_byte_enable_q <= 2'b00;
            io_read_data_q <= 8'h00;
            io_read_data_valid_q <= 1'b0;
            protocol_error <= 1'b0;
            index_q <= 7'h00;
            nmi_mask_q <= 1'b1;
            irq8_q <= 1'b0;
            status_c_periodic_q <= 1'b0;
            status_c_alarm_q <= 1'b0;
            status_c_update_q <= 1'b0;
            checksum_q <= CMOS_INITIAL_SUM;
            side_effect_count <= 16'h0000;
            for (i = 0; i < 128; i = i + 1)
                cmos_q[i] = 8'h00;
            cmos_q[7'h00] <= 8'h00;
            cmos_q[7'h02] <= 8'h00;
            cmos_q[7'h04] <= 8'h00;
            cmos_q[7'h06] <= 8'h07;
            cmos_q[7'h07] <= 8'h01;
            cmos_q[7'h08] <= 8'h01;
            cmos_q[7'h09] <= 8'h00;
            cmos_q[7'h0A] <= 8'h26;
            cmos_q[7'h0B] <= 8'h02;
            cmos_q[7'h15] <= CMOS_BASE_LOW;
            cmos_q[7'h16] <= CMOS_BASE_HIGH;
            cmos_q[7'h17] <= CMOS_EXTENDED_LOW;
            cmos_q[7'h18] <= CMOS_EXTENDED_HIGH;
            cmos_q[7'h30] <= CMOS_EXTENDED_LOW;
            cmos_q[7'h31] <= CMOS_EXTENDED_HIGH;
            cmos_q[7'h32] <= 8'h20;
        end else begin
            if (io_state_q == IO_DONE)
                io_state_q <= IO_IDLE;

            if (request_accept) begin
                io_state_q <= IO_DONE;
                io_byte_enable_q <= request_byte_enable;
                io_read_data_valid_q <= !request_write;
                side_effect_count <= side_effect_count + 16'h0001;

                if (!request_write) begin
                    io_read_data_q <= current_read_data;
                    if ((request_address[15:0] == 16'h0071) &&
                        (index_q == 7'h0C)) begin
                        status_c_periodic_q <= 1'b0;
                        status_c_alarm_q <= 1'b0;
                        status_c_update_q <= 1'b0;
                        irq8_q <= 1'b0;
                    end
                end else if (request_address[15:0] == 16'h0070) begin
                    index_q <= request_byte[6:0];
                    nmi_mask_q <= request_byte[7];
                end
            end

            // CPU and HPS writes share the same CMOS state. Management has
            // priority if both sources target the data array in one cycle.
            if (mgmt_rtc_write) begin
                if ((mgmt_address[6:0] != 7'h0C) &&
                    (mgmt_address[6:0] != 7'h0D) &&
                    (mgmt_address[6:0] != 7'h2E) &&
                    (mgmt_address[6:0] != 7'h2F) &&
                    !is_fixed_memory_address(mgmt_address[6:0])) begin
                    cmos_q[mgmt_address[6:0]] <= mgmt_writedata[7:0];
                    if (mgmt_address[6:0] == 7'h37)
                        cmos_q[7'h32] <= mgmt_writedata[7:0];
                    if (is_checksum_address(mgmt_address[6:0]))
                        checksum_q <= checksum_q -
                                      {8'h00, cmos_q[mgmt_address[6:0]]} +
                                      {8'h00, mgmt_writedata[7:0]};
                end
            end else if (cpu_data_write &&
                         (index_q != 7'h0C) && (index_q != 7'h0D)) begin
                // 2Eh/2Fh are ordinary CMOS RAM on real hardware. BIOS code
                // computes and writes the checksum; Landmark also includes
                // both bytes in its 10h-3Fh RAM pattern test.
                if (index_q == 7'h2E)
                    checksum_q[15:8] <= request_byte;
                else if (index_q == 7'h2F)
                    checksum_q[7:0] <= request_byte;
                else begin
                    cmos_q[index_q] <= request_byte;
                    if (index_q == 7'h37)
                        cmos_q[7'h32] <= request_byte;
                    if (is_checksum_address(index_q))
                        checksum_q <= checksum_q -
                                      {8'h00, cmos_q[index_q]} +
                                      {8'h00, request_byte};
                end
            end

            if (periodic_tick && cmos_q[7'h0B][6]) begin
                status_c_periodic_q <= 1'b1;
                irq8_q <= 1'b1;
            end

            if (second_tick && rtc_clock_running) begin
                cmos_q[7'h00] <= next_second_clock;
                status_c_update_q <= 1'b1;
                if (cmos_q[7'h0B][4])
                    irq8_q <= 1'b1;

                if (alarm_match_next_second) begin
                    status_c_alarm_q <= 1'b1;
                    if (cmos_q[7'h0B][5])
                        irq8_q <= 1'b1;
                end

                if (second_rollover) begin
                    if (minute_binary >= 8'd59)
                        cmos_q[7'h02] <= encode_number(8'd0, binary_mode);
                    else
                        cmos_q[7'h02] <= encode_number(minute_binary + 8'd1,
                                                       binary_mode);
                end
                if (minute_rollover) begin
                    if (hour_binary >= 8'd23)
                        cmos_q[7'h04] <= encode_hour(8'd0, binary_mode,
                                                     mode_24_hour);
                    else
                        cmos_q[7'h04] <= encode_hour(hour_binary + 8'd1,
                                                     binary_mode,
                                                     mode_24_hour);
                end
                if (hour_rollover) begin
                    cmos_q[7'h06] <= encode_number(
                        (weekday_binary >= 8'd7) ? 8'd1 :
                                                   weekday_binary + 8'd1,
                        binary_mode);
                    if (day_rollover)
                        cmos_q[7'h07] <= encode_number(8'd1, binary_mode);
                    else
                        cmos_q[7'h07] <= encode_number(day_binary + 8'd1,
                                                       binary_mode);
                end
                if (day_rollover) begin
                    if (month_binary >= 8'd12)
                        cmos_q[7'h08] <= encode_number(8'd1, binary_mode);
                    else
                        cmos_q[7'h08] <= encode_number(month_binary + 8'd1,
                                                       binary_mode);
                end
                if (month_rollover) begin
                    if (year_binary >= 8'd99)
                        cmos_q[7'h09] <= encode_number(8'd0, binary_mode);
                    else
                        cmos_q[7'h09] <= encode_number(year_binary + 8'd1,
                                                       binary_mode);
                end
                if (year_rollover) begin
                    cmos_q[7'h32] <= encode_number(
                        (century_binary >= 8'd99) ? 8'd0 :
                                                    century_binary + 8'd1,
                        binary_mode);
                end
            end

            if (port_selected && !lane_valid)
                protocol_error <= 1'b1;
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset)
            assert (!(request_accept && !port_selected))
                else $error("AT RTC accepted an unselected request");
    end
`endif
endmodule
