// IBM AT compatible MC146818 RTC/CMOS boundary.
//
// Port 70h selects one of 128 CMOS bytes and carries the NMI mask. Port 71h
// reads or writes the selected byte. MiSTer's hps_ext transport supplies the
// host date/time and CMOS defaults with writes in the F4xx management window,
// matching the convention used by the ao486 and z486 cores.
// x86_init uploads that window while holding the machine in reset. CMOS is
// battery-backed state: initialize it at FPGA configuration, retain it across
// machine resets, and accept host writes even while CPU I/O is held in reset.
//
// The default AT memory profile contains 4 MiB of RAM: 640 KiB at
// 000000h-09FFFFh plus 3456 KiB at 100000h-45FFFFh. The Hardware OSD can select
// other profiles; their extended-memory CMOS fields follow the applied map.
`timescale 1ns/1ps

module spk286_at_rtc_cmos (
    input  logic        clk,
    input  logic        reset,

    input  logic        request_valid,
    input  logic        request_command_valid,
    input  logic        request_write,
    input  logic        request_io,
    input  logic [23:0] request_address,
    input  logic [2:0]  installed_ram_size,
    input  logic [1:0]  request_byte_enable,
    input  logic [15:0] request_data_out,
    output logic        request_accept,
    output logic        request_ready,
    output logic [15:0] request_read_data,
    output logic        request_read_data_valid,

    input  logic [15:0] mgmt_address,
    input  logic [15:0] mgmt_writedata,
    input  logic        mgmt_write,
    output logic [15:0] mgmt_readdata,

    input  logic        periodic_tick, // One clk enable per 32768 Hz base tick
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
    localparam logic [7:0] CMOS_EXTENDED_LOW   = 8'h80; // 3456 KiB = 0D80h
    localparam logic [7:0] CMOS_EXTENDED_HIGH  = 8'h0D;
    localparam logic [15:0] CMOS_INITIAL_SUM   = 16'h010F;

    logic       io_state_q;
    logic [1:0] io_byte_enable_q;
    logic [7:0] io_read_data_q;
    logic       io_read_data_valid_q;
    logic [6:0] index_q;
    logic       nmi_mask_q;
    wire        irq8_q;
    logic [13:0] periodic_count_q;
    logic       status_c_periodic_q;
    logic       status_c_alarm_q;
    logic       status_c_update_q;
    logic [15:0] checksum_q;
    logic [2:0]  memory_size_applied_q = 3'd0;
    logic [7:0] cmos_q [0:127];
    logic [7:0] request_byte;
    logic [7:0] current_read_data;
    logic       port_selected;
    logic       lane_valid;
    logic       cpu_data_write;
    logic       mgmt_rtc_write;
    integer i;

    function automatic logic [2:0] normalize_ram_size(input logic [2:0] size);
        begin
            case (size)
                3'd0, 3'd1, 3'd2, 3'd3, 3'd4: normalize_ram_size = size;
                default: normalize_ram_size = 3'd0;
            endcase
        end
    endfunction

    function automatic logic [15:0] extended_memory_kib(
        input logic [2:0] size
    );
        begin
            // Total installed-RAM selections subtract the fixed 640 KiB
            // conventional base. The 16 MiB class follows the 16-bit-bus AT
            // map and reserves the top 128 KiB at FE0000h-FFFFFFh.
            case (size)
                3'd0:    extended_memory_kib = 16'd3456;
                3'd1:    extended_memory_kib = 16'd7552;
                3'd2:    extended_memory_kib = 16'd15232;
                3'd3:    extended_memory_kib = 16'd384;
                3'd4:    extended_memory_kib = 16'd1408;
                default: extended_memory_kib = 16'd3456;
            endcase
        end
    endfunction

    wire [2:0] normalized_ram_size = normalize_ram_size(installed_ram_size);
    wire [15:0] selected_extended_memory_kib =
        extended_memory_kib(normalized_ram_size);
    wire [7:0] selected_extended_memory_low =
        selected_extended_memory_kib[7:0];
    wire [7:0] selected_extended_memory_high =
        selected_extended_memory_kib[15:8];

    initial begin
        checksum_q = CMOS_INITIAL_SUM;
        for (i = 0; i < 128; i = i + 1)
            cmos_q[i] = 8'h00;
        cmos_q[7'h06] = 8'h07;
        cmos_q[7'h07] = 8'h01;
        cmos_q[7'h08] = 8'h01;
        cmos_q[7'h0A] = 8'h26;
        cmos_q[7'h0B] = 8'h02;
        cmos_q[7'h15] = CMOS_BASE_LOW;
        cmos_q[7'h16] = CMOS_BASE_HIGH;
        cmos_q[7'h17] = CMOS_EXTENDED_LOW;
        cmos_q[7'h18] = CMOS_EXTENDED_HIGH;
        cmos_q[7'h30] = CMOS_EXTENDED_LOW;
        cmos_q[7'h31] = CMOS_EXTENDED_HIGH;
        cmos_q[7'h32] = 8'h20;
    end

    function automatic logic [7:0] bcd_to_binary(input logic [7:0] value);
        begin
            bcd_to_binary = ({4'h0, value[7:4]} * 8'd10) +
                            {4'h0, value[3:0]};
        end
    endfunction

    function automatic logic [7:0] binary_to_bcd(input logic [7:0] value);
        begin
            // Combinational truth table for the full byte domain. Retain
            // the previous quotient's low four bits even above decimal 159;
            // invalid CMOS bytes must not acquire a different result.
            case (value)
                8'd0: binary_to_bcd = 8'h00;
                8'd1: binary_to_bcd = 8'h01;
                8'd2: binary_to_bcd = 8'h02;
                8'd3: binary_to_bcd = 8'h03;
                8'd4: binary_to_bcd = 8'h04;
                8'd5: binary_to_bcd = 8'h05;
                8'd6: binary_to_bcd = 8'h06;
                8'd7: binary_to_bcd = 8'h07;
                8'd8: binary_to_bcd = 8'h08;
                8'd9: binary_to_bcd = 8'h09;
                8'd10: binary_to_bcd = 8'h10;
                8'd11: binary_to_bcd = 8'h11;
                8'd12: binary_to_bcd = 8'h12;
                8'd13: binary_to_bcd = 8'h13;
                8'd14: binary_to_bcd = 8'h14;
                8'd15: binary_to_bcd = 8'h15;
                8'd16: binary_to_bcd = 8'h16;
                8'd17: binary_to_bcd = 8'h17;
                8'd18: binary_to_bcd = 8'h18;
                8'd19: binary_to_bcd = 8'h19;
                8'd20: binary_to_bcd = 8'h20;
                8'd21: binary_to_bcd = 8'h21;
                8'd22: binary_to_bcd = 8'h22;
                8'd23: binary_to_bcd = 8'h23;
                8'd24: binary_to_bcd = 8'h24;
                8'd25: binary_to_bcd = 8'h25;
                8'd26: binary_to_bcd = 8'h26;
                8'd27: binary_to_bcd = 8'h27;
                8'd28: binary_to_bcd = 8'h28;
                8'd29: binary_to_bcd = 8'h29;
                8'd30: binary_to_bcd = 8'h30;
                8'd31: binary_to_bcd = 8'h31;
                8'd32: binary_to_bcd = 8'h32;
                8'd33: binary_to_bcd = 8'h33;
                8'd34: binary_to_bcd = 8'h34;
                8'd35: binary_to_bcd = 8'h35;
                8'd36: binary_to_bcd = 8'h36;
                8'd37: binary_to_bcd = 8'h37;
                8'd38: binary_to_bcd = 8'h38;
                8'd39: binary_to_bcd = 8'h39;
                8'd40: binary_to_bcd = 8'h40;
                8'd41: binary_to_bcd = 8'h41;
                8'd42: binary_to_bcd = 8'h42;
                8'd43: binary_to_bcd = 8'h43;
                8'd44: binary_to_bcd = 8'h44;
                8'd45: binary_to_bcd = 8'h45;
                8'd46: binary_to_bcd = 8'h46;
                8'd47: binary_to_bcd = 8'h47;
                8'd48: binary_to_bcd = 8'h48;
                8'd49: binary_to_bcd = 8'h49;
                8'd50: binary_to_bcd = 8'h50;
                8'd51: binary_to_bcd = 8'h51;
                8'd52: binary_to_bcd = 8'h52;
                8'd53: binary_to_bcd = 8'h53;
                8'd54: binary_to_bcd = 8'h54;
                8'd55: binary_to_bcd = 8'h55;
                8'd56: binary_to_bcd = 8'h56;
                8'd57: binary_to_bcd = 8'h57;
                8'd58: binary_to_bcd = 8'h58;
                8'd59: binary_to_bcd = 8'h59;
                8'd60: binary_to_bcd = 8'h60;
                8'd61: binary_to_bcd = 8'h61;
                8'd62: binary_to_bcd = 8'h62;
                8'd63: binary_to_bcd = 8'h63;
                8'd64: binary_to_bcd = 8'h64;
                8'd65: binary_to_bcd = 8'h65;
                8'd66: binary_to_bcd = 8'h66;
                8'd67: binary_to_bcd = 8'h67;
                8'd68: binary_to_bcd = 8'h68;
                8'd69: binary_to_bcd = 8'h69;
                8'd70: binary_to_bcd = 8'h70;
                8'd71: binary_to_bcd = 8'h71;
                8'd72: binary_to_bcd = 8'h72;
                8'd73: binary_to_bcd = 8'h73;
                8'd74: binary_to_bcd = 8'h74;
                8'd75: binary_to_bcd = 8'h75;
                8'd76: binary_to_bcd = 8'h76;
                8'd77: binary_to_bcd = 8'h77;
                8'd78: binary_to_bcd = 8'h78;
                8'd79: binary_to_bcd = 8'h79;
                8'd80: binary_to_bcd = 8'h80;
                8'd81: binary_to_bcd = 8'h81;
                8'd82: binary_to_bcd = 8'h82;
                8'd83: binary_to_bcd = 8'h83;
                8'd84: binary_to_bcd = 8'h84;
                8'd85: binary_to_bcd = 8'h85;
                8'd86: binary_to_bcd = 8'h86;
                8'd87: binary_to_bcd = 8'h87;
                8'd88: binary_to_bcd = 8'h88;
                8'd89: binary_to_bcd = 8'h89;
                8'd90: binary_to_bcd = 8'h90;
                8'd91: binary_to_bcd = 8'h91;
                8'd92: binary_to_bcd = 8'h92;
                8'd93: binary_to_bcd = 8'h93;
                8'd94: binary_to_bcd = 8'h94;
                8'd95: binary_to_bcd = 8'h95;
                8'd96: binary_to_bcd = 8'h96;
                8'd97: binary_to_bcd = 8'h97;
                8'd98: binary_to_bcd = 8'h98;
                8'd99: binary_to_bcd = 8'h99;
                8'd100: binary_to_bcd = 8'hA0;
                8'd101: binary_to_bcd = 8'hA1;
                8'd102: binary_to_bcd = 8'hA2;
                8'd103: binary_to_bcd = 8'hA3;
                8'd104: binary_to_bcd = 8'hA4;
                8'd105: binary_to_bcd = 8'hA5;
                8'd106: binary_to_bcd = 8'hA6;
                8'd107: binary_to_bcd = 8'hA7;
                8'd108: binary_to_bcd = 8'hA8;
                8'd109: binary_to_bcd = 8'hA9;
                8'd110: binary_to_bcd = 8'hB0;
                8'd111: binary_to_bcd = 8'hB1;
                8'd112: binary_to_bcd = 8'hB2;
                8'd113: binary_to_bcd = 8'hB3;
                8'd114: binary_to_bcd = 8'hB4;
                8'd115: binary_to_bcd = 8'hB5;
                8'd116: binary_to_bcd = 8'hB6;
                8'd117: binary_to_bcd = 8'hB7;
                8'd118: binary_to_bcd = 8'hB8;
                8'd119: binary_to_bcd = 8'hB9;
                8'd120: binary_to_bcd = 8'hC0;
                8'd121: binary_to_bcd = 8'hC1;
                8'd122: binary_to_bcd = 8'hC2;
                8'd123: binary_to_bcd = 8'hC3;
                8'd124: binary_to_bcd = 8'hC4;
                8'd125: binary_to_bcd = 8'hC5;
                8'd126: binary_to_bcd = 8'hC6;
                8'd127: binary_to_bcd = 8'hC7;
                8'd128: binary_to_bcd = 8'hC8;
                8'd129: binary_to_bcd = 8'hC9;
                8'd130: binary_to_bcd = 8'hD0;
                8'd131: binary_to_bcd = 8'hD1;
                8'd132: binary_to_bcd = 8'hD2;
                8'd133: binary_to_bcd = 8'hD3;
                8'd134: binary_to_bcd = 8'hD4;
                8'd135: binary_to_bcd = 8'hD5;
                8'd136: binary_to_bcd = 8'hD6;
                8'd137: binary_to_bcd = 8'hD7;
                8'd138: binary_to_bcd = 8'hD8;
                8'd139: binary_to_bcd = 8'hD9;
                8'd140: binary_to_bcd = 8'hE0;
                8'd141: binary_to_bcd = 8'hE1;
                8'd142: binary_to_bcd = 8'hE2;
                8'd143: binary_to_bcd = 8'hE3;
                8'd144: binary_to_bcd = 8'hE4;
                8'd145: binary_to_bcd = 8'hE5;
                8'd146: binary_to_bcd = 8'hE6;
                8'd147: binary_to_bcd = 8'hE7;
                8'd148: binary_to_bcd = 8'hE8;
                8'd149: binary_to_bcd = 8'hE9;
                8'd150: binary_to_bcd = 8'hF0;
                8'd151: binary_to_bcd = 8'hF1;
                8'd152: binary_to_bcd = 8'hF2;
                8'd153: binary_to_bcd = 8'hF3;
                8'd154: binary_to_bcd = 8'hF4;
                8'd155: binary_to_bcd = 8'hF5;
                8'd156: binary_to_bcd = 8'hF6;
                8'd157: binary_to_bcd = 8'hF7;
                8'd158: binary_to_bcd = 8'hF8;
                8'd159: binary_to_bcd = 8'hF9;
                8'd160: binary_to_bcd = 8'h00;
                8'd161: binary_to_bcd = 8'h01;
                8'd162: binary_to_bcd = 8'h02;
                8'd163: binary_to_bcd = 8'h03;
                8'd164: binary_to_bcd = 8'h04;
                8'd165: binary_to_bcd = 8'h05;
                8'd166: binary_to_bcd = 8'h06;
                8'd167: binary_to_bcd = 8'h07;
                8'd168: binary_to_bcd = 8'h08;
                8'd169: binary_to_bcd = 8'h09;
                8'd170: binary_to_bcd = 8'h10;
                8'd171: binary_to_bcd = 8'h11;
                8'd172: binary_to_bcd = 8'h12;
                8'd173: binary_to_bcd = 8'h13;
                8'd174: binary_to_bcd = 8'h14;
                8'd175: binary_to_bcd = 8'h15;
                8'd176: binary_to_bcd = 8'h16;
                8'd177: binary_to_bcd = 8'h17;
                8'd178: binary_to_bcd = 8'h18;
                8'd179: binary_to_bcd = 8'h19;
                8'd180: binary_to_bcd = 8'h20;
                8'd181: binary_to_bcd = 8'h21;
                8'd182: binary_to_bcd = 8'h22;
                8'd183: binary_to_bcd = 8'h23;
                8'd184: binary_to_bcd = 8'h24;
                8'd185: binary_to_bcd = 8'h25;
                8'd186: binary_to_bcd = 8'h26;
                8'd187: binary_to_bcd = 8'h27;
                8'd188: binary_to_bcd = 8'h28;
                8'd189: binary_to_bcd = 8'h29;
                8'd190: binary_to_bcd = 8'h30;
                8'd191: binary_to_bcd = 8'h31;
                8'd192: binary_to_bcd = 8'h32;
                8'd193: binary_to_bcd = 8'h33;
                8'd194: binary_to_bcd = 8'h34;
                8'd195: binary_to_bcd = 8'h35;
                8'd196: binary_to_bcd = 8'h36;
                8'd197: binary_to_bcd = 8'h37;
                8'd198: binary_to_bcd = 8'h38;
                8'd199: binary_to_bcd = 8'h39;
                8'd200: binary_to_bcd = 8'h40;
                8'd201: binary_to_bcd = 8'h41;
                8'd202: binary_to_bcd = 8'h42;
                8'd203: binary_to_bcd = 8'h43;
                8'd204: binary_to_bcd = 8'h44;
                8'd205: binary_to_bcd = 8'h45;
                8'd206: binary_to_bcd = 8'h46;
                8'd207: binary_to_bcd = 8'h47;
                8'd208: binary_to_bcd = 8'h48;
                8'd209: binary_to_bcd = 8'h49;
                8'd210: binary_to_bcd = 8'h50;
                8'd211: binary_to_bcd = 8'h51;
                8'd212: binary_to_bcd = 8'h52;
                8'd213: binary_to_bcd = 8'h53;
                8'd214: binary_to_bcd = 8'h54;
                8'd215: binary_to_bcd = 8'h55;
                8'd216: binary_to_bcd = 8'h56;
                8'd217: binary_to_bcd = 8'h57;
                8'd218: binary_to_bcd = 8'h58;
                8'd219: binary_to_bcd = 8'h59;
                8'd220: binary_to_bcd = 8'h60;
                8'd221: binary_to_bcd = 8'h61;
                8'd222: binary_to_bcd = 8'h62;
                8'd223: binary_to_bcd = 8'h63;
                8'd224: binary_to_bcd = 8'h64;
                8'd225: binary_to_bcd = 8'h65;
                8'd226: binary_to_bcd = 8'h66;
                8'd227: binary_to_bcd = 8'h67;
                8'd228: binary_to_bcd = 8'h68;
                8'd229: binary_to_bcd = 8'h69;
                8'd230: binary_to_bcd = 8'h70;
                8'd231: binary_to_bcd = 8'h71;
                8'd232: binary_to_bcd = 8'h72;
                8'd233: binary_to_bcd = 8'h73;
                8'd234: binary_to_bcd = 8'h74;
                8'd235: binary_to_bcd = 8'h75;
                8'd236: binary_to_bcd = 8'h76;
                8'd237: binary_to_bcd = 8'h77;
                8'd238: binary_to_bcd = 8'h78;
                8'd239: binary_to_bcd = 8'h79;
                8'd240: binary_to_bcd = 8'h80;
                8'd241: binary_to_bcd = 8'h81;
                8'd242: binary_to_bcd = 8'h82;
                8'd243: binary_to_bcd = 8'h83;
                8'd244: binary_to_bcd = 8'h84;
                8'd245: binary_to_bcd = 8'h85;
                8'd246: binary_to_bcd = 8'h86;
                8'd247: binary_to_bcd = 8'h87;
                8'd248: binary_to_bcd = 8'h88;
                8'd249: binary_to_bcd = 8'h89;
                8'd250: binary_to_bcd = 8'h90;
                8'd251: binary_to_bcd = 8'h91;
                8'd252: binary_to_bcd = 8'h92;
                8'd253: binary_to_bcd = 8'h93;
                8'd254: binary_to_bcd = 8'h94;
                8'd255: binary_to_bcd = 8'h95;
                default: binary_to_bcd = 8'hxx;
            endcase
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
    // The AT RTC uses the 32.768 kHz oscillator mode (DV=010). Other DV
    // values stop this divider; in particular 11x holds it in reset.
    wire rtc_divider_running = (cmos_q[7'h0A][6:4] == 3'b010);
    wire rtc_clock_running = !cmos_q[7'h0B][7] && rtc_divider_running;
    wire [3:0] periodic_rate = cmos_q[7'h0A][3:0];
    wire rate_write = mgmt_rtc_write ? (mgmt_address[6:0] == 7'h0A) :
                      (cpu_data_write && (index_q == 7'h0A));
    logic [13:0] periodic_limit;

    // Register A RS=1/2 alias 8/9. RS=0 disables periodic events only;
    // it does not stop calendar updates. Limits count 32768 Hz enables.
    always_comb begin
        case (periodic_rate)
            4'h1, 4'h8: periodic_limit = 14'd127;   // 256 Hz
            4'h2, 4'h9: periodic_limit = 14'd255;   // 128 Hz
            4'h3: periodic_limit = 14'd3;          // 8192 Hz
            4'h4: periodic_limit = 14'd7;
            4'h5: periodic_limit = 14'd15;
            4'h6: periodic_limit = 14'd31;         // 1024 Hz (BIOS default)
            4'h7: periodic_limit = 14'd63;
            4'hA: periodic_limit = 14'd511;
            4'hB: periodic_limit = 14'd1023;       // 32 Hz (OS/2)
            4'hC: periodic_limit = 14'd2047;
            4'hD: periodic_limit = 14'd4095;
            4'hE: periodic_limit = 14'd8191;
            4'hF: periodic_limit = 14'd16383;      // 2 Hz
            default: periodic_limit = 14'd0;
        endcase
    end

    wire periodic_event = periodic_tick && rtc_divider_running &&
                          (periodic_rate != 4'h0) && !rate_write &&
                          (periodic_count_q == periodic_limit);

    always_ff @(posedge clk) begin
        if (reset || rate_write || !rtc_divider_running ||
            (periodic_rate == 4'h0))
            periodic_count_q <= 14'd0;
        else if (periodic_tick)
            periodic_count_q <= periodic_event ? 14'd0 :
                                                periodic_count_q + 1'b1;
    end

    // PF/AF/UF latch even with their interrupt enable clear. Deriving IRQ
    // from the flags and register B also handles enabling an already pending
    // event and masking an asserted interrupt without discarding its flag.
    assign irq8_q = !reset &&
                   ((status_c_periodic_q && cmos_q[7'h0B][6]) ||
                    (status_c_alarm_q && cmos_q[7'h0B][5]) ||
                    (status_c_update_q && cmos_q[7'h0B][4]));
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

    function automatic logic [7:0] read_cmos_byte(input logic [6:0] address);
        begin
            case (address)
                7'h0A: read_cmos_byte = {1'b0, cmos_q[7'h0A][6:0]};
                7'h0C: read_cmos_byte = {irq8_q,
                                         status_c_periodic_q,
                                         status_c_alarm_q,
                                         status_c_update_q,
                                         4'b0000};
                7'h0D: read_cmos_byte = 8'h80;
                7'h2E: read_cmos_byte = checksum_q[15:8];
                7'h2F: read_cmos_byte = checksum_q[7:0];
                default: read_cmos_byte = cmos_q[address];
            endcase
        end
    endfunction

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

        // hps_ext samples ext_din before asserting its read pulse, so expose
        // management data directly from the address. This snapshot path is
        // deliberately side-effect free: reading register C here must not
        // acknowledge RTC interrupts as a CPU read from port 71h would.
        mgmt_readdata = 16'h0000;
        if ((mgmt_address[15:8] == 8'hF4) && !mgmt_address[7])
            mgmt_readdata = {8'h00, read_cmos_byte(mgmt_address[6:0])};

        if (request_address[15:0] == 16'h0070)
            current_read_data = {nmi_mask_q, index_q};
        else
            current_read_data = read_cmos_byte(index_q);
    end

    assign request_accept = !reset && (io_state_q == IO_IDLE) && port_selected &&
                            lane_valid;
    assign request_ready = (io_state_q == IO_DONE);
    assign request_read_data_valid = request_ready && io_read_data_valid_q;
    assign request_read_data = io_byte_enable_q[1] ?
                               {io_read_data_q, 8'h00} :
                               {8'h00, io_read_data_q};
    assign irq8 = irq8_q;
    assign nmi_mask = nmi_mask_q;

    always_ff @(posedge clk) begin
        // The host initializes CMOS before releasing reset. Keep these writes
        // outside the CPU-interface reset branch; a later reset must not erase
        // date/time, drive configuration, shutdown codes or the BIOS checksum.
        // Apply the memory-size fields on Reset & apply settings. Preserve
        // CPU-writable CMOS semantics between profile changes, and adjust the
        // standard checksum for the changed 17h/18h bytes.
        if ((normalized_ram_size != memory_size_applied_q) &&
            !mgmt_rtc_write && !cpu_data_write) begin
            cmos_q[7'h17] <= selected_extended_memory_low;
            cmos_q[7'h18] <= selected_extended_memory_high;
            cmos_q[7'h30] <= selected_extended_memory_low;
            cmos_q[7'h31] <= selected_extended_memory_high;
            checksum_q <= checksum_q - {8'h00, cmos_q[7'h17]} -
                          {8'h00, cmos_q[7'h18]} +
                          {8'h00, selected_extended_memory_low} +
                          {8'h00, selected_extended_memory_high};
            memory_size_applied_q <= normalized_ram_size;
        end else if (mgmt_rtc_write) begin
            if ((mgmt_address[6:0] != 7'h0C) &&
                (mgmt_address[6:0] != 7'h0D) &&
                (mgmt_address[6:0] != 7'h2E) &&
                (mgmt_address[6:0] != 7'h2F) &&
                !is_fixed_memory_address(mgmt_address[6:0])) begin
                // 32h is the AT century byte; 37h is independent NVRAM.
                // MRBIOS checksums 37h but excludes 32h, so aliasing them
                // invalidates its configuration when DOS sets the date.
                cmos_q[mgmt_address[6:0]] <= mgmt_writedata[7:0];
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
                if (is_checksum_address(index_q))
                    checksum_q <= checksum_q -
                                  {8'h00, cmos_q[index_q]} +
                                  {8'h00, request_byte};
            end
        end

        if (reset) begin
            io_state_q <= IO_IDLE;
            io_byte_enable_q <= 2'b00;
            io_read_data_q <= 8'h00;
            io_read_data_valid_q <= 1'b0;
            protocol_error <= 1'b0;
            index_q <= 7'h00;
            nmi_mask_q <= 1'b1;
            status_c_periodic_q <= 1'b0;
            status_c_alarm_q <= 1'b0;
            status_c_update_q <= 1'b0;
            side_effect_count <= 16'h0000;
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
                    end
                end else if (request_address[15:0] == 16'h0070) begin
                    index_q <= request_byte[6:0];
                    nmi_mask_q <= request_byte[7];
                end
            end

            // A coincident new event survives a status-C acknowledgement.
            if (periodic_event) begin
                status_c_periodic_q <= 1'b1;
            end

            if (second_tick && rtc_clock_running) begin
                cmos_q[7'h00] <= next_second_clock;
                status_c_update_q <= 1'b1;

                if (alarm_match_next_second) begin
                    status_c_alarm_q <= 1'b1;
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
