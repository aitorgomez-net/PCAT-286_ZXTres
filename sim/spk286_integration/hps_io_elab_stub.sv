// Minimal hps_io contract used by the AT top-level elaboration check.
// The production profile is built with sys/hps_io.sv; this stub keeps the
// local Icarus structural check independent of MiSTer framework primitives.
module hps_io #(
    parameter CONF_STR = "",
    parameter CONF_STR_BRAM = 0,
    parameter PS2DIV = 0,
    parameter WIDE = 0,
    parameter VDNUM = 1,
    parameter BLKSZ = 2,
    parameter PS2WE = 0,
    parameter STRLEN = 0,
    parameter F12KEYMOD = 0
) (
    input        clk_sys,
    inout [45:0] HPS_BUS,
    inout [35:0] EXT_BUS,
    inout [21:0] gamma_bus,
    output       forced_scandoubler,
    output       direct_video,
    output [1:0] buttons,
    output [127:0] status,
    input [15:0] status_menumask,
    input        video_rotated,
    input        new_vmode,
    input        info_req,
    input [7:0]  info,
    input [127:0] status_in,
    input        status_set,
    output [7:0] uart_mode,
    output [10:0] ps2_key,
    input        ps2_kbd_clk_in,
    input        ps2_kbd_data_in,
    output       ps2_kbd_clk_out,
    output       ps2_kbd_data_out,
    input        ps2_mouse_clk_in,
    input        ps2_mouse_data_in,
    output       ps2_mouse_clk_out,
    output       ps2_mouse_data_out,
    output [31:0] joystick_0,
    output [31:0] joystick_1,
    output [15:0] joystick_l_analog_0,
    output [15:0] joystick_l_analog_1,
    output       ioctl_download,
    output [15:0] ioctl_index,
    output       ioctl_wr,
    output [26:0] ioctl_addr,
    output [15:0] ioctl_dout,
    input        ioctl_wait,
    input        ioctl_upload_req,
    input [7:0]  ioctl_upload_index,
    input [15:0] ioctl_din
);
    assign forced_scandoubler = 1'b0;
    assign direct_video = 1'b0;
    assign buttons = 2'b00;
    assign status = 128'h0;
    assign uart_mode = 8'h0;
    assign ps2_key = 11'h0;
    assign ps2_kbd_clk_out = 1'b0;
    assign ps2_kbd_data_out = 1'b0;
    assign ps2_mouse_clk_out = 1'b0;
    assign ps2_mouse_data_out = 1'b0;
    assign joystick_0 = 32'h0;
    assign joystick_1 = 32'h0;
    assign joystick_l_analog_0 = 16'h0;
    assign joystick_l_analog_1 = 16'h0;
    assign ioctl_download = 1'b0;
    assign ioctl_index = 16'h0;
    assign ioctl_wr = 1'b0;
    assign ioctl_addr = 27'h0;
    assign ioctl_dout = 16'h0;
endmodule
