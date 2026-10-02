// MiSTer top-level for the normalized PCAT-286 AT machine.
//
// This is the only machine top kept by the project.  sys_top selects emu_at
// through AT_PROFILE, so the legacy XT chipset is not present as a second
// SDRAM owner.
`timescale 1ns/1ps

`ifndef ENABLE_OPL2
`define ENABLE_OPL2 0
`endif
`ifndef ENABLE_CMS
`define ENABLE_CMS 0
`endif
`ifndef ENABLE_TANDY_AUDIO
`define ENABLE_TANDY_AUDIO 0
`endif
`ifndef ENABLE_MIDI
`define ENABLE_MIDI 0
`endif
`ifndef ENABLE_SB
`define ENABLE_SB 0
`endif

module emu_at
(
`include "sys/emu_ports.vh"
);

    // Keep the AT profile's System & BIOS page local to the PCAT-286 top.
    // These indices are part of the HPS/OSD contract: bit 7 is splash when
    // enabled in config.tcl, bits 74:72 select installed RAM, and bit 71
    // enables the compact diagnostic overlay.
    // The ROM marker is required for MiSTer to expose a real file selector.
    localparam CONF_STR_HALT_AT = {
        "h4-,HALTED: no PCAT ROM selected;",
        "h5-,HALTED: no EGA BIOS selected;"
    };

    localparam CONF_STR_INFO = {
        "I,Monitor setting pending\n",
        "Reset to apply\n",
        "OSD: Hardware,",
        "No PCAT BIOS selected\n",
        "Machine halted\n",
        "OSD: System & BIOS,",
        "No EGA BIOS selected\n",
        "Machine halted\n",
        "OSD: System & BIOS;"
    };

`ifndef SPK286_AT_NO_DEBUG
    localparam CONF_STR_AT_DEBUG =
        "P1O[71],SPK286 Debug,Off,On;";
`endif

    // Match the source profile's mutually exclusive C/MS and Sound Blaster
    // choices on the shared 220h ports.
    localparam CONF_STR_A220 = (`ENABLE_CMS && `ENABLE_SB ?
        "P2OST,Audio 220h,C/MS,Sound Blaster,Disabled;" :
        (`ENABLE_SB ? "P2OT,Sound Blaster,Enabled,Disabled;" :
         (`ENABLE_CMS ? "P2OT,C/MS Audio,Enabled,Disabled;" : "")));
    localparam CONF_STR_OPL2 = (`ENABLE_OPL2 ?
        "P2oAB,OPL2,Adlib 388h,SB FM 388h/228h, Disabled;" : "");
    localparam CONF_STR_TANDY = (`ENABLE_TANDY_AUDIO ?
        "P2oN,Tandy Sound,Disabled,Enabled;" : "");
    // Keep the source profile's MIDI/MT32-pi page and status-bit placement.
    // MPU-401 is the AT card at 330h; USER I/O selects the physical MIDI
    // cable or the COM2 pins, while the h3P4 entries configure the external
    // MT32-pi bridge and its LCD/status protocol.
    localparam CONF_STR_MIDI = (`ENABLE_MIDI ?
        "P3oO,MPU-401,Enabled,Disabled;P3-;P3O6,USER I/O,MIDI,COM2;P3-;h3P4,MT32-pi;h3P4-;h3P4OD,Use MT32-pi,Yes,No;h3P4-;h3P4o9,MT32-pi Mode,MT-32,General MIDI;h3P4O34,MT32-pi ROM,MT-32 v1,MT-32 v2,CM-32L,Reserved;h3P4oSU,MT32-pi SoundFont,#0,#1,#2,#3,#4,#5,#6,#7;h3P4-;h3P4r8,Reset Hanging Notes;h3P4-;" : "");

    localparam CONF_STR_SYSTEM = "PCAT-286;";
    localparam CONF_STR_UART = (`ENABLE_MIDI ?
        "UART115200:115200,MIDI;" :
        "UART115200:115200;");

    localparam CONF_STR_AT = {
        CONF_STR_SYSTEM,
        CONF_STR_UART,
        CONF_STR_HALT_AT,
        "S0,IMGIMAVFD,Floppy A:;",
        "S1,IMGIMAVFD,Floppy B:;",
        "OJK,Write Protect,None,A:,B:,A: & B:;",
        "-;",
        "S2,VHD,IDE 0-0;",
        "S3,VHD,IDE 0-1;",
        "OLM,2nd SD card,Disable,IDE 0-0,IDE 0-1;",
        "-;",
        "P1,System & BIOS;",
        "P1-;",
`ifdef SPK286_AT_BOOT_SPLASH
        "P1O7,Boot Splash Screen,Yes,No;",
`endif
        "P1FC0,ROM,PCAT BIOS:;",
        "P1FC3,ROM,EGA BIOS:;",
        "P1-;",
        // An empty packed Verilog string is an 8-bit NUL, not zero bytes.
        // Omit the entire element so the host can read the remaining entries.
`ifndef SPK286_AT_NO_DEBUG
        CONF_STR_AT_DEBUG,
`endif
        "P1-;",
        "P2,Audio & Video;",
        "P2-;",
        CONF_STR_A220,
        CONF_STR_OPL2,
        CONF_STR_TANDY,
        "P2o01,Speaker Volume,1,2,3,4;",
        "P2o45,Audio Boost,No,2x,4x;",
        "P2o67,Stereo Mix,none,25%,50%,100%;",
        "P2-;",
        "P2oEH,CRT H offset,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15;",
        "P2oIK,CRT V offset,0,1,2,3,4,5,6,7;",
        "P2O[66:64],VSync Width,Auto,1,2,3,4,5,6,7;",
        "P2O[69:67],HSync Width,Auto,1,2,3,4,5,6,7;",
        "P2O12,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%;",
        "P2O89,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
        "P2OEG,Display,Full Color,Green,Amber,B&W,Red,Blue,Fuchsia,Purple;",
        "P2OA,VGA 13h+ CRT,Native 70Hz,TV 60Hz;",
        "P2o23,350-line CRT,Native,480i 15 kHz,240p 15 kHz;",
        "P2-;",
        "P3,Hardware;",
        "P3-;",
        "P3O[74:72],Installed RAM,4MB,8MB,16MB,1MB,2MB;",
        "P3oCD,Monitor,5154/ECD,5153/CGA,5151/MDA;",
        "P3ONO,Joystick 1, Analog, Digital, Disabled;",
        "P3OPQ,Joystick 2, Analog, Digital, Disabled;",
        "P3OR,Sync Joy to CPU Speed,No,Yes;",
        "P3oM,Swap Joysticks,No,Yes;",
        (`ENABLE_SB ? "P3O[70],Sound Blaster IRQ,5,7;" : ""),
        CONF_STR_MIDI,
        "P3-;",
        "-;",
        "R0,Reset & apply settings;",
        "J,Fire 1,Fire 2;",
        CONF_STR_INFO,
        "V,v"
    };

    wire [35:0] EXT_BUS;
    wire [21:0] gamma_bus;
    wire [21:0] gamma_bus_video;
    assign gamma_bus = gamma_bus_video;

    wire [15:0] at_mgmt_din;
    wire [15:0] at_mgmt_dout;
    wire [15:0] at_mgmt_address;
    wire        at_mgmt_read;
    wire        at_mgmt_write;
    wire [1:0]  at_floppy_present;
    wire [1:0]  at_floppy_request;
    wire [2:0]  at_ide_request;
    wire [7:0]  at_mgmt_request = {at_floppy_request, 3'b000,
                                   at_ide_request};

    // Use the same MiSTer management transport and request bit layout as the
    // XT profile. Requests 7:6 are floppy A/B and 2:0 belong to XT-IDE.
    // RTC/CMOS uses host-pushed writes and host-initiated snapshot reads in
    // the F400-F47F window, so it needs no request bit.
    hps_ext hps_ext_at (
        .clk_sys     (CLK_50M),
        .EXT_BUS     (EXT_BUS),
        .ext_din     (at_mgmt_din),
        .ext_dout    (at_mgmt_dout),
        .ext_addr    (at_mgmt_address),
        .ext_rd      (at_mgmt_read),
        .ext_wr      (at_mgmt_write),
        .ext_midi    (),
        .ext_req     (at_mgmt_request),
        .ext_hotswap (2'b00)
    );

    wire [31:0] joystick_0;
    wire [31:0] joystick_1;
    wire [15:0] joystick_l_analog_0;
    wire [15:0] joystick_l_analog_1;
    wire [1:0]  hps_buttons;
    wire        forced_scandoubler;
    wire        direct_video;
    wire [127:0] hps_status;
    wire [15:0]  hps_status_menumask;
    wire [1:0]   at_monitor_profile_osd = hps_status[45:44];
    wire [1:0]   at_monitor_profile_applied;
    wire         at_monitor_pending_info_req;
    wire [7:0]   at_monitor_pending_info;
    wire         at_bios_info_req;
    wire [7:0]   at_bios_info;
    wire         at_info_req = at_bios_info_req | at_monitor_pending_info_req;
    wire [7:0]   at_info = at_bios_info_req ? at_bios_info : at_monitor_pending_info;
    wire         at_monitor_profile_pending =
        at_monitor_profile_osd != at_monitor_profile_applied;
    wire         at_debug_enable = hps_status[71];
    wire         at_vga_mode13_native_osd = ~hps_status[10];
    wire [3:0]   at_crt_h_osd = hps_status[49:46];
    wire [2:0]   at_crt_v_osd = hps_status[52:50];
    wire [2:0]   at_vsync_width_osd = hps_status[66:64];
    wire [2:0]   at_hsync_width_osd = hps_status[69:67];
    wire         at_joy1_digital_osd = hps_status[23];
    wire         at_joy1_disable_osd = hps_status[24];
    wire         at_joy2_digital_osd = hps_status[25];
    wire         at_joy2_disable_osd = hps_status[26];
    wire         at_joy_sync_osd = hps_status[27];
    wire         at_joy_swap_osd = hps_status[54];
    wire         at_a220_cms_osd = `ENABLE_CMS ?
        (`ENABLE_SB ? (hps_status[29:28] == 2'b00) : ~hps_status[29]) : 1'b0;
    wire         at_a220_sb_osd = `ENABLE_SB ?
        (`ENABLE_CMS ? (hps_status[29:28] == 2'b01) : ~hps_status[29]) : 1'b0;
    wire [2:0]   at_sb_irq_osd = hps_status[70] ? 3'd7 : 3'd5;
    wire [2:0]   at_installed_ram_size_osd = hps_status[74:72];

    wire [7:0] at286ctl_cpu;
    wire [7:0] at286ctl_exp;
    wire [7:0] at286ctl_vid;
    wire [7:0] at286ctl_inp;
    wire [7:0] at286ctl_midi;
    wire [7:0] at286ctl_exp2;
    wire [7:0] at286ctl_crt;
    wire [7:0] at286ctl_sync;
    wire [39:0] at286ctl_status_effective;
    wire [17:0] at286ctl_status_osd_match;
    wire [1:0] at286ctl_eff_speed;
    wire        at286ctl_eff_fake286;
    wire [1:0] at286ctl_eff_opl2;
    wire        at286ctl_eff_cms;
    wire        at286ctl_eff_sb;
    wire [2:0] at286ctl_eff_sb_irq;
    wire        at286ctl_eff_ems;
    wire        at286ctl_eff_umb;
    wire        at286ctl_eff_vga13;
    wire        at286ctl_eff_joy1_digital;
    wire        at286ctl_eff_joy1_disable;
    wire        at286ctl_eff_joy2_digital;
    wire        at286ctl_eff_joy2_disable;
    wire        at286ctl_eff_joy_sync;
    wire        at286ctl_eff_joy_swap;
    wire        at286ctl_eff_mt32_gm;
    wire        at286ctl_eff_tandy;
    wire        at286ctl_eff_mpu401;
    wire [3:0] at286ctl_eff_crt_h;
    wire [2:0] at286ctl_eff_crt_v;
    wire [2:0] at286ctl_eff_vsync_width;
    wire [2:0] at286ctl_eff_hsync_width;
    wire [4:0] at_joy_opts = {at286ctl_eff_joy_sync,
                               at286ctl_eff_joy2_disable,
                               at286ctl_eff_joy2_digital,
                               at286ctl_eff_joy1_disable,
                               at286ctl_eff_joy1_digital};

    // The AT profile currently implements the real VGA/EGA video path and
    // PC speaker; the remaining compatibility fields stay available in the
    // register map and resolve to their hardware-safe defaults.
    at286ctl_resolve u_at286ctl_resolve (
        .reg_cpu(at286ctl_cpu), .reg_exp(at286ctl_exp),
        .reg_vid(at286ctl_vid), .reg_inp(at286ctl_inp),
        .reg_midi(at286ctl_midi), .reg_exp2(at286ctl_exp2),
        .osd_speed(2'd0), .osd_fake286(1'b0), .osd_opl2(hps_status[43:42]),
        .osd_cms(at_a220_cms_osd), .osd_sb(at_a220_sb_osd),
        .osd_sb_irq(at_sb_irq_osd),
        .osd_joy1_digital(at_joy1_digital_osd), .osd_joy1_disable(at_joy1_disable_osd),
        .osd_joy2_digital(at_joy2_digital_osd), .osd_joy2_disable(at_joy2_disable_osd),
        .osd_joy_sync(at_joy_sync_osd), .osd_joy_swap(at_joy_swap_osd),
        .osd_mt32_gm(hps_status[41]), .osd_tandy(hps_status[55]),
        .osd_mpu401(~hps_status[56]),
        .reg_crt(at286ctl_crt), .reg_sync(at286ctl_sync),
        .osd_crt_h(at_crt_h_osd), .osd_crt_v(at_crt_v_osd),
        .osd_vsync_w(at_vsync_width_osd), .osd_hsync_w(at_hsync_width_osd),
        .build_sb(`ENABLE_SB ? 1'b1 : 1'b0),
        .build_tandy(`ENABLE_TANDY_AUDIO ? 1'b1 : 1'b0),
        .eff_speed(at286ctl_eff_speed), .eff_fake286(at286ctl_eff_fake286),
        .eff_opl2(at286ctl_eff_opl2), .eff_cms(at286ctl_eff_cms),
        .eff_sb(at286ctl_eff_sb), .eff_sb_irq(at286ctl_eff_sb_irq),
        .eff_ems(at286ctl_eff_ems), .eff_umb(at286ctl_eff_umb),
        .eff_vga13(at286ctl_eff_vga13),
        .eff_joy1_digital(at286ctl_eff_joy1_digital),
        .eff_joy1_disable(at286ctl_eff_joy1_disable),
        .eff_joy2_digital(at286ctl_eff_joy2_digital),
        .eff_joy2_disable(at286ctl_eff_joy2_disable),
        .eff_joy_sync(at286ctl_eff_joy_sync),
        .eff_joy_swap(at286ctl_eff_joy_swap),
        .eff_mt32_gm(at286ctl_eff_mt32_gm), .eff_tandy(at286ctl_eff_tandy),
        .eff_mpu401(at286ctl_eff_mpu401),
        .eff_crt_h(at286ctl_eff_crt_h), .eff_crt_v(at286ctl_eff_crt_v),
        .eff_vsync_w(at286ctl_eff_vsync_width),
        .eff_hsync_w(at286ctl_eff_hsync_width),
        .status_effective(at286ctl_status_effective),
        .status_osd_match(at286ctl_status_osd_match)
    );
    wire [10:0]  ps2_key;
    wire          ps2_kbd_clk_out;
    wire          ps2_kbd_data_out;
    wire          ps2_mouse_clk_out;
    wire          ps2_mouse_data_out;
    wire [7:0]    uart_mode;

    wire        ioctl_download;
    wire [15:0] ioctl_index;
    wire        ioctl_wr;
    wire [26:0] ioctl_addr;
    wire [15:0] ioctl_data;
    wire        ioctl_wait;

    // The keyboard uses the decoded HPS event stream at the AT 8042 boundary.
    // The mouse retains the source profile's PS/2 wire protocol and serial
    // COM1 converter so DOS sees a Microsoft-compatible mouse at 3F8h.
    wire ps2_kbd_clk_in  = 1'b1;
    wire ps2_kbd_data_in = 1'b1;
    wire ps2_mouse_clk_in;
    wire ps2_mouse_data_in;

    hps_io #(
        .CONF_STR (CONF_STR_AT),
        .PS2DIV   (2000),
        .PS2WE    (1),
        .WIDE     (1)
    ) hps_io_at (
        .clk_sys              (CLK_50M),
        .HPS_BUS              (HPS_BUS),
        .EXT_BUS              (EXT_BUS),
        .gamma_bus            (gamma_bus),
        .forced_scandoubler   (forced_scandoubler),
        .direct_video         (direct_video),
        .buttons              (hps_buttons),
        .status               (hps_status),
        .status_menumask      (hps_status_menumask),
        .video_rotated        (1'b0),
        .new_vmode            (1'b0),
        .info_req             (at_info_req),
        .info                 (at_info),
        .status_in            (128'h0),
        .status_set           (1'b0),
        .uart_mode            (uart_mode),
        .ps2_key              (ps2_key),
        .ps2_kbd_clk_in       (ps2_kbd_clk_in),
        .ps2_kbd_data_in      (ps2_kbd_data_in),
        .ps2_kbd_clk_out      (ps2_kbd_clk_out),
        .ps2_kbd_data_out     (ps2_kbd_data_out),
        .ps2_mouse_clk_in     (ps2_mouse_clk_in),
        .ps2_mouse_data_in    (ps2_mouse_data_in),
        .ps2_mouse_clk_out    (ps2_mouse_clk_out),
        .ps2_mouse_data_out   (ps2_mouse_data_out),
        .joystick_0           (joystick_0),
        .joystick_1           (joystick_1),
        .joystick_l_analog_0  (joystick_l_analog_0),
        .joystick_l_analog_1  (joystick_l_analog_1),
        .ioctl_download       (ioctl_download),
        .ioctl_index          (ioctl_index),
        .ioctl_wr             (ioctl_wr),
        .ioctl_addr           (ioctl_addr),
        .ioctl_dout           (ioctl_data),
        .ioctl_wait           (ioctl_wait),
        .ioctl_upload_req     (1'b0),
        .ioctl_upload_index   (8'h00),
        .ioctl_din            (16'h0000)
    );

    // The source profile routes the MiSTer UART menu's MIDI mode to the HPS
    // UART and otherwise leaves MPU-401 MIDI on the external USER I/O cable.
    // USER I/O can also expose COM2, matching the original option exactly.
    wire hps_midi = (`ENABLE_MIDI) && (uart_mode >= 8'd3);
    wire user_io_mt32 = (`ENABLE_MIDI) && !hps_status[6];
    wire user_io_com2 = (`ENABLE_MIDI) && hps_status[6];
    wire mt32_disable = hps_status[13];
    wire [6:0] mt32_user_out;
    wire       mt32_pi_midi_rx;
    wire       mt32_available;
    wire       mt32_midi_connected = user_io_mt32 && mt32_available;
    // Match the source profile's priority: HPS UART in MIDI mode, otherwise
    // the MT32-pi MIDI input after its connection handshake, and idle high
    // while the selected USER I/O pins are floating or disconnected.  Without
    // this qualification an un-driven SDA/RX pin is interpreted as a UART
    // break, making 331h read 00h before the first MPU command.
    wire       midi_rx = hps_midi ? UART_RXD :
                         mt32_midi_connected ?
                           mt32_pi_midi_rx : 1'b1;
    wire       midi_tx;
    wire       uart1_rx;
    wire       uart1_rts_n;
    MSMouseWrapper #(.CLKFREQ(50_000_000)) u_serial_mouse (
        .clk          (CLK_50M),
        .ps2dta_in    (ps2_mouse_data_out),
        .ps2clk_in    (ps2_mouse_clk_out),
        .ps2dta_out   (ps2_mouse_data_in),
        .ps2clk_out   (ps2_mouse_clk_in),
        .rts          (~uart1_rts_n),
        .rd           (uart1_rx)
    );
    wire       uart2_rx = user_io_mt32 ? 1'b1 : USER_IN[0];
    wire       uart2_cts_n = user_io_mt32 ? 1'b1 : USER_IN[3];
    wire       uart2_dsr_n = user_io_mt32 ? 1'b1 : USER_IN[5];
    wire       uart2_dcd_n = user_io_mt32 ? 1'b1 : USER_IN[6];
    wire       uart2_tx;
    wire       uart2_rts_n;
    wire       uart2_dtr_n;
    wire       mt32_reset = hps_status[40] | RESET | hps_status[0] |
                            hps_buttons[1];
    wire       mt32_mode_req = at286ctl_eff_mt32_gm;
    wire [1:0] mt32_rom_req = hps_status[4:3];
    wire [7:0] mt32_sf_req = {5'd0, hps_status[62:60]};
    wire [15:0] mt32_i2s_r;
    wire [15:0] mt32_i2s_l;
    wire [7:0] mt32_mode;
    wire [7:0] mt32_rom;
    wire [7:0] mt32_sf;
    wire       mt32_newmode;
    wire       mt32_lcd_en;
    wire       mt32_lcd_pix;
    wire       mt32_lcd_update;
    wire       mt32_use = user_io_mt32 && !mt32_disable;
    wire       mt32_mute = user_io_mt32 && mt32_disable;

    // Exact MIDI baud enable: 50 MHz / (4 * 16 * 25) = 31250 baud. Both
    // serial ports receive the standard 1.8432 MHz x16 reference.
    logic [1:0]  midi_baud_div_q;
    logic [25:0] uart_baud_phase_q;
    logic        midi_baudce;
    logic        uart_baudce;
    always_ff @(posedge CLK_50M or posedge RESET) begin
        if (RESET) begin
            midi_baud_div_q  <= 2'd0;
            midi_baudce      <= 1'b0;
            uart_baud_phase_q <= 26'd0;
            uart_baudce      <= 1'b0;
        end else begin
            midi_baudce <= (midi_baud_div_q == 2'd3);
            if (midi_baud_div_q == 2'd3)
                midi_baud_div_q <= 2'd0;
            else
                midi_baud_div_q <= midi_baud_div_q + 1'b1;

            if ((uart_baud_phase_q + 26'd1_843_200) >= 26'd50_000_000) begin
                uart_baud_phase_q <= uart_baud_phase_q + 26'd1_843_200 -
                                     26'd50_000_000;
                uart_baudce <= 1'b1;
            end else begin
                uart_baud_phase_q <= uart_baud_phase_q + 26'd1_843_200;
                uart_baudce <= 1'b0;
            end
        end
    end

    wire        physical_idle;
    wire [12:0] sdram_address;
    wire        sdram_cke;
    wire        sdram_cs;
    wire        sdram_ras;
    wire        sdram_cas;
    wire        sdram_we;
    wire [1:0]  sdram_ba;
    wire [15:0] sdram_dq_in;
    wire [15:0] sdram_dq_out;
    wire        sdram_dq_io;
    wire        sdram_ldqm;
    wire        sdram_udqm;
    logic       sdram_initialized_q;

    assign sdram_dq_in = SDRAM_DQ;
    assign SDRAM_DQ = ~sdram_dq_io ? sdram_dq_out : 16'hzzzz;
    // Forward the real 50 MHz clock through the dedicated DDR output cells.
    // High on rising edges, low on falling edges: no divide or phase shift.
    // A global clock routed as ordinary output data adds avoidable pin skew.
    altddio_out #(
        .extend_oe_disable("OFF"), .intended_device_family("Cyclone V"),
        .invert_output("OFF"), .lpm_hint("UNUSED"),
        .lpm_type("altddio_out"), .oe_reg("UNREGISTERED"),
        .power_up_high("OFF"), .width(1)
    ) sdram_clock_ddr (
        .datain_h(1'b1), .datain_l(1'b0), .outclock(CLK_50M),
        .dataout(SDRAM_CLK), .aclr(1'b0), .aset(1'b0), .oe(1'b1),
        .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
    );
    assign SDRAM_A   = sdram_address;
    assign SDRAM_CKE = sdram_cke;
    assign SDRAM_BA  = sdram_ba;
    assign SDRAM_nCS = sdram_cs;
    assign SDRAM_nRAS = sdram_ras;
    assign SDRAM_nCAS = sdram_cas;
    assign SDRAM_nWE  = sdram_we;
    assign SDRAM_DQML = sdram_ldqm;
    assign SDRAM_DQMH = sdram_udqm;

    // physical_idle is a transaction-state signal and therefore drops for
    // every SDRAM access.  The HPS loader needs a monotonic initialization
    // indication so an active ROM word is not reset at the next command.
    always_ff @(posedge CLK_50M or posedge RESET) begin
        if (RESET)
            sdram_initialized_q <= 1'b0;
        else if (physical_idle)
            sdram_initialized_q <= 1'b1;
    end

    wire        loader_valid;
    wire        loader_write;
    wire [23:0] loader_address;
    wire [1:0]  loader_byte_enable;
    wire [15:0] loader_data_out;
    wire        loader_accept;
    wire        loader_ready;
    wire [2:0]  bios_protect_flag;
    wire        main_rom_loaded;
    wire        ega_rom_loaded;
    wire        loader_active;
    wire        loader_protocol_error;

    // Match the source profile: bits 4 and 5 expose the missing-main/EGA
    // indicators, while the lower menu bits control the MIDI/MT32-pi entries.
    wire at_bios_missing_main = !main_rom_loaded;
    wire at_bios_missing_ega = main_rom_loaded && !ega_rom_loaded;
    wire at_bios_required_missing = at_bios_missing_main || at_bios_missing_ega;
    assign hps_status_menumask = {10'd0, at_bios_missing_ega, at_bios_missing_main,
                                  (`ENABLE_MIDI && mt32_available && at286ctl_eff_mpu401),
                                  3'b111};

    spk286_at_hps_rom_loader u_at_hps_rom_loader (
        .clk                (CLK_50M),
        .reset              (RESET),
        .sdram_initialized  (sdram_initialized_q),
        .ioctl_download     (ioctl_download),
        .ioctl_index        (ioctl_index[7:0]),
        .ioctl_wr           (ioctl_wr),
        .ioctl_addr         (ioctl_addr[24:0]),
        .ioctl_data         (ioctl_data),
        .ioctl_wait         (ioctl_wait),
        .loader_valid       (loader_valid),
        .loader_write       (loader_write),
        .loader_address     (loader_address),
        .loader_byte_enable (loader_byte_enable),
        .loader_data_out    (loader_data_out),
        .loader_accept      (loader_accept),
        .loader_ready       (loader_ready),
        .bios_protect_flag  (bios_protect_flag),
        .main_rom_loaded    (main_rom_loaded),
        .ega_rom_loaded     (ega_rom_loaded),
        .load_active        (loader_active),
        .protocol_error     (loader_protocol_error)
    );

    wire        cpu_memory_valid;
    wire        cpu_memory_command_valid;
    wire        cpu_memory_write;
    wire        cpu_memory_code_fetch;
    wire [3:0]  cpu_memory_cycle_class;
    wire [24:0] cpu_memory_address;
    wire [1:0]  cpu_memory_byte_enable;
    wire [15:0] cpu_memory_data_out;
    wire        cpu_memory_accept;
    wire        cpu_memory_ready;
    wire [15:0] cpu_memory_read_data;
    wire        cpu_memory_read_data_valid;

    wire        at_cpu_data_oe;
    wire [23:0] at_cpu_address;
    wire [15:0] at_cpu_data_out;
    wire [15:0] at_cpu_data_in;
    wire        at_cpu_bus_valid;
    wire        at_cpu_bus_write;
    wire        at_cpu_bus_bhe_n;
    wire [3:0]  at_cpu_bus_status;
    wire        at_cpu_bus_lock;
    wire        at_cpu_hlda;
    wire        at_cpu_ready;
    wire        at_cpu_halted;
    wire        at_cpu_shutdown;
    wire        at_debug_bridge_error;
    wire        at_debug_control_error;
    wire        at_debug_unsupported_opcode;
    wire        at_debug_microcode_fault;
    wire        at_debug_operand_blocked;
    wire [7:0]  at_debug_opcode;
    wire [15:0] at_debug_cs;
    wire [15:0] at_debug_ip;
    wire [15:0] at_debug_flags;
    wire [127:0] at_debug_gpr;
    wire        at_debug_instruction_retired;
    wire        at_debug_fetch_blocked;
    wire [11:0] at_debug_micro_pc;
    wire [3:0]  at_debug_bus_state;
    wire [7:0]  at_debug_biu_detail;
    wire [7:0]  at_debug_last_post;
    wire [31:0] at_debug_trace0;
    wire [19:0] at_debug_address;
    wire [7:0]  at_debug_data_out;
    wire [7:0]  at_debug_data_in;
    wire [2:0]  at_debug_status;
    wire        at_debug_valid;
    wire        at_debug_write;
    wire        at_debug_io;
    wire        at_debug_ready;
    wire        at_debug_hold_request;
    wire        at_debug_bridge_idle;
    wire [3:0]  at_debug_bridge_state;
    wire        at_debug_read_data_valid;
    wire        at_debug_dma_bus_request;
    wire        at_debug_refresh_request;
    wire        at_debug_dma_grant;
    wire        at_debug_refresh_grant;
    wire        at_debug_intr;
    wire [15:0] at_debug_irq_request;
    wire        at_speaker_active;
    wire        at_speaker_level;
    wire signed [15:0] at_opl2_sound;
    wire signed [15:0] at_cms_sound_l;
    wire signed [15:0] at_cms_sound_r;
    wire signed [10:0] at_tandy_sound;
    wire signed [15:0] at_sb_sound_l;
    wire signed [15:0] at_sb_sound_r;

    wire        dma_memory_valid;
    wire        dma_memory_write;
    wire        dma_memory_read;
    wire [24:0] dma_memory_address;
    wire [1:0]  dma_memory_byte_enable;
    wire [15:0] dma_memory_data_out;
    wire        dma_memory_accept;
    wire        dma_memory_ready;
    wire [15:0] dma_memory_data_in;

    wire        refresh_memory_valid;
    wire [23:0] refresh_memory_address;
    wire        refresh_memory_accept;
    wire        refresh_memory_ready;

    wire        backend_valid;
    wire        backend_command_valid;
    wire [1:0]  backend_owner;
    wire        backend_write;
    wire        backend_refresh;
    wire        backend_code_fetch;
    wire [3:0]  backend_cycle_class;
    wire [24:0] backend_address;
    wire [1:0]  backend_byte_enable;
    wire [15:0] backend_data_out;
    wire        backend_accept;
    wire        backend_ready;
    wire [15:0] backend_read_data;
    wire        backend_read_data_valid;
    wire        memory_port_protocol_error;
    wire [4:0]  memory_port_debug_state;

    wire        p03_out_valid;
    wire        p03_out_command_valid;
    wire [1:0]  p03_out_owner;
    wire        p03_out_write;
    wire        p03_out_refresh;
    wire        p03_out_code_fetch;
    wire        p03_out_burst;
    wire [3:0]  p03_out_cycle_class;
    wire [24:0] p03_out_address;
    wire [1:0]  p03_out_byte_enable;
    wire [15:0] p03_out_data_out;
    wire        p03_in_accept;
    wire        p03_in_ready;
    wire [15:0] p03_in_read_data;
    wire        p03_in_read_data_valid;
    wire        p03_out_accept;
    wire        p03_out_ready;
    wire [15:0] p03_out_read_data;
    wire        p03_out_read_data_valid;
    wire [31:0] p03_hit_count;
    wire [31:0] p03_miss_count;
    wire [31:0] p03_fill_count;
    wire [31:0] p03_physical_read_count;
    wire [31:0] p03_invalidation_count;
    wire [4:0]  p03_debug_state;

    // Keep the existing logical-backend debug names pointed at the response
    // seen by the memory port. The physical owner handshake is intentionally
    // private to the P03 fill/bypass state machine.
    assign backend_accept          = p03_in_accept;
    assign backend_ready           = p03_in_ready;
    assign backend_read_data       = p03_in_read_data;
    assign backend_read_data_valid = p03_in_read_data_valid;

    spk286_at_mister_memory_port u_at_memory_port (
        .clk                    (CLK_50M),
        .reset                  (RESET),
        .cancel_cpu             (at_machine_reset | at_cpu_reset_request),
        .cpu_valid              (cpu_memory_valid),
        .cpu_command_valid      (cpu_memory_command_valid),
        .cpu_write              (cpu_memory_write),
        .cpu_code_fetch         (cpu_memory_code_fetch),
        .cpu_cycle_class        (cpu_memory_cycle_class),
        .cpu_address            (cpu_memory_address),
        .cpu_byte_enable        (cpu_memory_byte_enable),
        .cpu_data_out           (cpu_memory_data_out),
        .cpu_accept             (cpu_memory_accept),
        .cpu_ready              (cpu_memory_ready),
        .cpu_read_data          (cpu_memory_read_data),
        .cpu_read_data_valid    (cpu_memory_read_data_valid),
        .loader_valid           (loader_valid),
        .loader_write           (loader_write),
        .loader_address         (loader_address),
        .loader_byte_enable     (loader_byte_enable),
        .loader_data_out        (loader_data_out),
        .loader_accept          (loader_accept),
        .loader_ready           (loader_ready),
        .loader_read_data       (),
        .dma_valid              (dma_memory_valid),
        .dma_write              (dma_memory_write),
        .dma_address            (dma_memory_address),
        .dma_byte_enable        (dma_memory_byte_enable),
        .dma_data_out           (dma_memory_data_out),
        .dma_accept             (dma_memory_accept),
        .dma_ready              (dma_memory_ready),
        .dma_read_data          (dma_memory_data_in),
        .refresh_valid          (refresh_memory_valid),
        .refresh_address        (refresh_memory_address),
        .refresh_accept         (refresh_memory_accept),
        .refresh_ready          (refresh_memory_ready),
        .backend_valid          (backend_valid),
        .backend_command_valid  (backend_command_valid),
        .backend_owner          (backend_owner),
        .backend_write          (backend_write),
        .backend_refresh        (backend_refresh),
        .backend_code_fetch     (backend_code_fetch),
        .backend_cycle_class    (backend_cycle_class),
        .backend_address        (backend_address),
        .backend_byte_enable    (backend_byte_enable),
        .backend_data_out       (backend_data_out),
        .backend_accept         (p03_in_accept),
        .backend_ready          (p03_in_ready),
        .backend_read_data      (p03_in_read_data),
        .backend_read_data_valid(p03_in_read_data_valid),
        .debug_state            (memory_port_debug_state),
        .protocol_error         (memory_port_protocol_error)
    );

    // P03 is placed below the single-owner memory port. The port still
    // serializes CPU, DMA, loader and refresh ownership; the buffer can
    // therefore invalidate one line on every accepted write without adding
    // a second coherence arbiter.
    spk286_at_sdram_read_buffer #(
        .ENABLE(1'b1)
    ) u_at_sdram_read_buffer (
        .clk                     (CLK_50M),
        .reset                   (RESET),
        .cancel_cpu              (at_machine_reset | at_cpu_reset_request),
        .enable                  (1'b1),
        .in_valid                (backend_valid),
        .in_command_valid        (backend_command_valid),
        .in_owner                (backend_owner),
        .in_write                (backend_write),
        .in_refresh              (backend_refresh),
        .in_code_fetch           (backend_code_fetch),
        .in_cycle_class          (backend_cycle_class),
        .in_address              (backend_address),
        .in_byte_enable          (backend_byte_enable),
        .in_data_out             (backend_data_out),
        .in_accept               (p03_in_accept),
        .in_ready                (p03_in_ready),
        .in_read_data            (p03_in_read_data),
        .in_read_data_valid      (p03_in_read_data_valid),
        .out_valid               (p03_out_valid),
        .out_command_valid       (p03_out_command_valid),
        .out_owner               (p03_out_owner),
        .out_write               (p03_out_write),
        .out_refresh             (p03_out_refresh),
        .out_code_fetch          (p03_out_code_fetch),
        .out_burst               (p03_out_burst),
        .out_cycle_class         (p03_out_cycle_class),
        .out_address             (p03_out_address),
        .out_byte_enable         (p03_out_byte_enable),
        .out_data_out            (p03_out_data_out),
        .out_accept              (p03_out_accept),
        .out_ready               (p03_out_ready),
        .out_read_data           (p03_out_read_data),
        .out_read_data_valid     (p03_out_read_data_valid),
        .debug_hit_count         (p03_hit_count),
        .debug_miss_count        (p03_miss_count),
        .debug_fill_count        (p03_fill_count),
        .debug_physical_read_count(p03_physical_read_count),
        .debug_invalidation_count(p03_invalidation_count),
        .debug_state             (p03_debug_state)
    );

    wire        sdram_owner_protocol_error;
    wire [7:0]  sdram_owner_debug_state;
    wire        ram_out_valid, ram_out_command, ram_out_write, ram_out_refresh;
    wire        ram_out_code, ram_out_burst, ram_out_accept, ram_out_ready;
    wire        ram_out_read_valid;
    wire [1:0]  ram_out_owner, ram_out_lanes;
    wire [3:0]  ram_out_class;
    wire [24:0] ram_out_address;
    wire [15:0] ram_out_data, ram_out_read_data;
`ifdef SPK286_AT_RAM_READ_BUFFER
    localparam logic RAM_READ_BUFFER_ENABLED = 1'b1;
`else
    localparam logic RAM_READ_BUFFER_ENABLED = 1'b0;
`endif
    // Both buffers observe canonical addresses and every accepted CPU/DMA/HPS
    // write. RAM data hits do not change physical write completion or P03's
    // instruction-line invalidation. SDRAM remains the final memory owner.
    spk286_at_sdram_data_buffer #(.ENABLE(RAM_READ_BUFFER_ENABLED)) u_at_ram_read_buffer (
        .clk(CLK_50M), .reset(RESET),
        .cancel_cpu(at_machine_reset | at_cpu_reset_request), .enable(1'b1),
        .in_valid(p03_out_valid), .in_command_valid(p03_out_command_valid),
        .in_owner(p03_out_owner), .in_write(p03_out_write),
        .in_refresh(p03_out_refresh), .in_code_fetch(p03_out_code_fetch),
        .in_burst(p03_out_burst), .in_cycle_class(p03_out_cycle_class),
        .in_address(p03_out_address), .in_byte_enable(p03_out_byte_enable),
        .in_data_out(p03_out_data_out), .in_accept(p03_out_accept),
        .in_ready(p03_out_ready), .in_read_data(p03_out_read_data),
        .in_read_data_valid(p03_out_read_data_valid),
        .out_valid(ram_out_valid), .out_command_valid(ram_out_command),
        .out_owner(ram_out_owner), .out_write(ram_out_write),
        .out_refresh(ram_out_refresh), .out_code_fetch(ram_out_code),
        .out_burst(ram_out_burst), .out_cycle_class(ram_out_class),
        .out_address(ram_out_address), .out_byte_enable(ram_out_lanes),
        .out_data_out(ram_out_data), .out_accept(ram_out_accept),
        .out_ready(ram_out_ready), .out_read_data(ram_out_read_data),
        .out_read_data_valid(ram_out_read_valid),
        .debug_hit_count(), .debug_miss_count(), .debug_fill_count(),
        .debug_write_update_count(), .debug_state()
    );
    spk286_at_mister_sdram_owner u_at_sdram_owner (
        .clk                    (CLK_50M),
        .reset                  (RESET),
        .request_valid          (ram_out_valid),
        .request_command_valid  (ram_out_command),
        .request_owner_refresh  (ram_out_refresh),
        .request_write          (ram_out_write),
        .request_code_fetch     (ram_out_code),
        .request_burst          (ram_out_burst),
        .request_cycle_class    (ram_out_class),
        .request_address        (ram_out_address),
        .request_byte_enable    (ram_out_lanes),
        .request_data_out       (ram_out_data),
        .request_accept         (ram_out_accept),
        .request_ready          (ram_out_ready),
        .request_read_data      (ram_out_read_data),
        .request_read_data_valid(ram_out_read_valid),
        .physical_idle          (physical_idle),
        .debug_state            (sdram_owner_debug_state),
        .protocol_error         (sdram_owner_protocol_error),
        .sdram_address           (sdram_address),
        .sdram_cke               (sdram_cke),
        .sdram_cs                (sdram_cs),
        .sdram_ras               (sdram_ras),
        .sdram_cas               (sdram_cas),
        .sdram_we                (sdram_we),
        .sdram_ba                (sdram_ba),
        .sdram_dq_in             (sdram_dq_in),
        .sdram_dq_out            (sdram_dq_out),
        .sdram_dq_io             (sdram_dq_io),
        .sdram_ldqm              (sdram_ldqm),
        .sdram_udqm              (sdram_udqm)
    );

    logic counter_clock;
    spk286_at_pit_clock u_pit_clock(.clk(CLK_50M), .reset(RESET), .counter_clock(counter_clock));
    logic rtc_tick_32768;
    logic second_tick;
    spk286_at_rtc_clock u_rtc_clock (
        .clk(CLK_50M), .reset(RESET),
        .tick_32768(rtc_tick_32768), .second_tick(second_tick)
    );

    wire keyboard_byte_valid;
    wire [7:0] keyboard_byte;
    wire keyboard_byte_ready;
    wire keyboard_translate_set1;
    wire keyboard_num_lock;
    wire keyboard_event_overflow;

    // Keep the AT machine in reset until the private video PLL is usable as
    // well as until the system BIOS has arrived.  The BIOS loader and SDRAM
    // remain in the 50 MHz domain, so this does not change download timing.
    wire at_video_clk_28;
    wire at_video_clk_57;
    wire at_video_clk_57_ps;
    wire at_video_clk_native;
    wire at_video_pll_locked;
    pll_system u_at_video_pll (
        .refclk   (CLK_50M),
        .rst      (1'b0),
        .outclk_0 (at_video_clk_28),
        .outclk_1 (at_video_clk_57),
        .outclk_2 (at_video_clk_57_ps),
        .outclk_3 (at_video_clk_native),
        .locked   (at_video_pll_locked)
    );

    // Keep the reset that gates the splash sequencer separate from the
    // machine reset.  The XT profile holds the CPU in reset while its splash
    // is visible; feeding the machine reset back into the sequencer would
    // clear the timer as soon as the splash became active.
    // Reuse the XT reset controls without clearing the loaded ROM flags.
    wire at_boot_reset = RESET | hps_status[0] | hps_buttons[1] |
                         !main_rom_loaded | !at_video_pll_locked;
    // Keep the external raster and MiSTer output path running at the EGA
    // power-on timing while the main BIOS is absent. The machine itself stays
    // reset through at_boot_reset and at_machine_reset below.
    wire at_video_output_reset = RESET | hps_status[0] | hps_buttons[1] |
                                 !at_video_pll_locked;
    // The XT splash lifetime survives OSD reset and Reset & apply settings.
    // Only re-arm it when the core itself restarts or its boot prerequisites
    // disappear; the host reset controls belong to the machine reset below.
    wire at_splash_reset = RESET | !main_rom_loaded | !at_video_pll_locked;

    spk286_at_keyboard u_at_keyboard (
        .clk                    (CLK_50M),
        .reset                  (at_boot_reset),
        .ps2_key                (ps2_key),
        .translate_set1         (keyboard_translate_set1),
        .num_lock               (keyboard_num_lock),
        .keyboard_byte_ready    (keyboard_byte_ready),
        .keyboard_byte_valid    (keyboard_byte_valid),
        .keyboard_byte          (keyboard_byte),
        .overflow               (keyboard_event_overflow)
    );

    // Keep the XT-compatible second-SD routing selection stable until the
    // machine is reset, matching the XT profile's use_mmc latch.  Bits 22:21
    // are free in the AT profile and are reserved for this shared OSD field.
    logic [1:0] at_use_mmc_q;
    always_ff @(posedge CLK_50M or posedge RESET) begin
        if (RESET)
            at_use_mmc_q <= 2'b00;
        else if (at_boot_reset)
            at_use_mmc_q <= hps_status[22:21];
    end

    // Keep the AT splash lifetime aligned with the XT profile.  Previously
    // this was wired directly to hps_status[7], which made the default
    // "Yes" setting hold the image forever while the CPU continued running
    // behind it.
    wire at_splashscreen;
    wire at_splash_boot_hold;
`ifdef SPK286_AT_BOOT_SPLASH
    spk286_at_splash_control u_at_splash_control (
        .clk         (CLK_50M),
        .reset       (at_splash_reset),
        .option_off  (hps_status[7]),
        .second_tick (second_tick),
        .splash_active(at_splashscreen),
        .boot_hold   (at_splash_boot_hold)
    );
`else
    assign at_splashscreen   = 1'b0;
    assign at_splash_boot_hold = 1'b0;
`endif

    // Keep the processor stopped until both required firmware images exist.
    // The periodic Info notice is independent of the optional splash artwork.
    wire at_bios_hold;
    spk286_at_bios_hold_notice u_at_bios_hold_notice (
        .clock             (CLK_50M),
        .splash_boot_phase (main_rom_loaded && at_splash_boot_hold),
        .bios_missing_main (at_bios_missing_main),
        .bios_missing_ega  (at_bios_missing_ega),
        .hold              (at_bios_hold),
        .info              (at_bios_info),
        .info_req          (at_bios_info_req)
    );

    // The splash is a real boot hold, not only a video overlay.  This keeps
    // CPU/BIU state frozen from boot settling until the image is removed.
    // As in XT, the pending interval is part of the boot hold; otherwise
    // the CPU runs before the first timer tick and is reset a second time.
    wire at_machine_reset = at_boot_reset | at_splash_boot_hold |
                            at_bios_required_missing | at_bios_hold;

    // The OSD choice represents physical EGA monitor switches. Sample it for
    // the active machine only during reset, then use that applied profile for
    // both BIOS switch-sense reads and the video connector output.
    ega_monitor_profile_latch at_monitor_profile_latch (
        .clock        (CLK_50M),
        .reset_active (at_machine_reset),
        .selected     (at_monitor_profile_osd),
        .applied      (at_monitor_profile_applied)
    );

    reset_pending_notice #(
        .INFO_INDEX (8'd1)
    ) at_monitor_pending_notice (
        .clock      (CLK_50M),
        .pending    (at_monitor_profile_pending),
        .osd_status (OSD_STATUS),
        .suppress   (at_bios_hold),
        .info       (at_monitor_pending_info),
        .info_req   (at_monitor_pending_info_req)
    );

    wire at_cpu_reset_request;
    logic at_video_pipe_reset_57_q1;
    logic at_video_pipe_reset_57_q2;
    logic at_video_pipe_reset_57_ps_q1;
    logic at_video_pipe_reset_57_ps_q2;
    wire  at_video_pipe_reset_57 = at_video_pipe_reset_57_q2;
    wire  at_video_pipe_reset_57_ps = at_video_pipe_reset_57_ps_q2;

    // Reset release for each output pipeline is synchronized to its own
    // phase. This keeps PLL lock/BIOS-load reset out of recovery paths in the
    // 57.272 MHz output registers.
    always_ff @(posedge at_video_clk_57 or posedge at_video_output_reset) begin
        if (at_video_output_reset) begin
            at_video_pipe_reset_57_q1 <= 1'b1;
            at_video_pipe_reset_57_q2 <= 1'b1;
        end else begin
            // The output pipeline must remain live for the pre-BIOS raster and
            // splash; only the AT machine itself stays held in reset.
            at_video_pipe_reset_57_q1 <= 1'b0;
            at_video_pipe_reset_57_q2 <= at_video_pipe_reset_57_q1;
        end
    end

    always_ff @(posedge at_video_clk_57_ps or posedge at_video_output_reset) begin
        if (at_video_output_reset) begin
            at_video_pipe_reset_57_ps_q1 <= 1'b1;
            at_video_pipe_reset_57_ps_q2 <= 1'b1;
        end else begin
            at_video_pipe_reset_57_ps_q1 <= 1'b0;
            at_video_pipe_reset_57_ps_q2 <= at_video_pipe_reset_57_ps_q1;
        end
    end
    wire cpu_fault;
    wire machine_protocol_error;

    // Raw EGA timing and colour signals stay in the raster clock domain until
    // they enter the established 57.272 MHz MiSTer output pipeline below.
    wire [5:0] at_video_red_raw;
    wire [5:0] at_video_green_raw;
    wire [5:0] at_video_blue_raw;
    wire       at_video_hsync_raw;
    wire       at_video_hblank_raw;
    wire       at_video_dbl_hsync_raw;
    wire       at_video_vsync_raw;
    wire       at_video_vblank_raw;
    wire       at_video_vblank_border_raw;
    wire       at_video_de_raw;
    wire       at_video_dot_toggle_raw;
    wire       at_video_scandouble_raw;
    wire       at_video_vmode_toggle_raw;
    wire       at_video_mode350_raw;
    wire [11:0] at_video_active_dots_raw;
    wire [9:0]  at_video_active_lines_raw;

    // Keep the PCXT-EGA bit assignments, but cross completed HPS options as
    // one configuration. Apply before the next active native-raster frame.
    wire [1:0] at_video_scale_q;
    wire [2:0] at_video_display_q;
    wire [12:0] at_video_arx_q;
    wire [12:0] at_video_ary_q;
    at_video_options_cdc u_at_video_options (
        .clk_sys(CLK_50M), .src_idle(!HPS_BUS[34]),
        .options({hps_status[16:14], hps_status[2:1], hps_status[9:8]}),
        .clk_video(at_video_clk_57), .video_reset(at_video_pipe_reset_57),
        .vblank(at_video_vb_pipe_q),
        .scale(at_video_scale_q), .display(at_video_display_q),
        .arx(at_video_arx_q), .ary(at_video_ary_q)
    );

    // AT286CTL is clocked by the AT bus and its effective video fields are
    // fed to the EGA/VGA adapter through the machine boundary.

`ifndef SPK286_AT_NO_DEBUG
`ifdef SPK286_AT_DEBUG_CPU_DIV2
    // Optional diagnostic configuration: run only SPK286 from a related
    // 25 MHz clock while the chipset, memory pipeline and SDRAM remain at
    // 50 MHz. The ordinary observer build keeps the CPU at 50 MHz.
    (* preserve, altera_attribute = "-name GLOBAL_SIGNAL GLOBAL_CLOCK" *)
    logic at_debug_cpu_clock_q;
    always_ff @(posedge CLK_50M or posedge RESET) begin
        if (RESET)
            at_debug_cpu_clock_q <= 1'b0;
        else
            at_debug_cpu_clock_q <= ~at_debug_cpu_clock_q;
    end
    wire at_cpu_clock = at_debug_cpu_clock_q;
    wire at_cpu_sample_edge = ~at_debug_cpu_clock_q;
    localparam logic AT_CPU_DIV2_ENABLED = 1'b1;
`else
    wire at_cpu_clock = CLK_50M;
    wire at_cpu_sample_edge = 1'b1;
    localparam logic AT_CPU_DIV2_ENABLED = 1'b0;
`endif
`else
    wire at_cpu_clock = CLK_50M;
    wire at_cpu_sample_edge = 1'b1;
    localparam logic AT_CPU_DIV2_ENABLED = 1'b0;
`endif

    spk286_at_machine #(
        .CPU_USES_SAMPLE_EDGE(AT_CPU_DIV2_ENABLED)
    ) u_at_machine (
        .clk                    (CLK_50M),
        .clk_cpu                (at_cpu_clock),
        .cpu_sample_edge        (at_cpu_sample_edge),
        // Keep the AT devices and EGA raster alive during the splash.  Only
        // the CPU/BIU reset is extended over the splash interval.
        .reset                  (at_boot_reset),
        .video_reset            (at_video_output_reset),
        .cpu_reset              (at_machine_reset),
        .clk_video              (at_video_clk_28),
        .splashscreen           (at_splashscreen),
        .ega_monitor_profile    (at_monitor_profile_applied),
        .at286ctl_status_effective(at286ctl_status_effective),
        .at286ctl_status_osd_match(at286ctl_status_osd_match),
        .at286ctl_eff_opl2     (at286ctl_eff_opl2),
        .at286ctl_eff_cms      (at286ctl_eff_cms),
        .at286ctl_eff_sb       (at286ctl_eff_sb),
        .at286ctl_eff_sb_irq   (at286ctl_eff_sb_irq),
        .at286ctl_eff_tandy    (at286ctl_eff_tandy),
        .at286ctl_eff_mpu401   (at286ctl_eff_mpu401),
        .at286ctl_eff_ems      (at286ctl_eff_ems),
        .at286ctl_eff_umb      (at286ctl_eff_umb),
        .installed_ram_size_osd(at_installed_ram_size_osd),
        .midi_baudce           (midi_baudce),
        .uart_baudce           (uart_baudce),
        .midi_rx               (midi_rx),
        .uart1_rx              (uart1_rx),
        .uart2_rx              (uart2_rx),
        .uart2_cts_n           (uart2_cts_n),
        .uart2_dsr_n           (uart2_dsr_n),
        .uart2_dcd_n           (uart2_dcd_n),
        .vga_enabled            (at286ctl_eff_vga13),
        .vga_mode13_native      (at_vga_mode13_native_osd),
        .crt_h_offset           (at286ctl_eff_crt_h),
        .crt_v_offset           (at286ctl_eff_crt_v),
        .vsync_width_osd        (at286ctl_eff_vsync_width),
        .hsync_width_osd        (at286ctl_eff_hsync_width),
        .joy_clk_select         (at286ctl_eff_speed),
        .joy_opts               (at_joy_opts),
        .joy0                   (joystick_0[13:0]),
        .joy1                   (joystick_1[13:0]),
        .joya0                  (joystick_l_analog_0),
        .joya1                  (joystick_l_analog_1),
        .execute_enable         (1'b1),
        .counter_clock          (counter_clock),
        .refresh_enable         (1'b1),
        .keyboard_byte_valid    (keyboard_byte_valid),
        .keyboard_byte          (keyboard_byte),
        .keyboard_byte_ready    (keyboard_byte_ready),
        .keyboard_translate_set1(keyboard_translate_set1),
        .keyboard_num_lock      (keyboard_num_lock),
        .periodic_tick          (rtc_tick_32768),
        .second_tick             (second_tick),
        .parity_event           (1'b0),
        .channel_check_event    (1'b0),
        .external_nmi_event     (1'b0),
        .mgmt_address           (at_mgmt_address),
        .mgmt_writedata         (at_mgmt_dout),
        .mgmt_write             (at_mgmt_write),
        .mgmt_read              (at_mgmt_read),
        .mgmt_readdata          (at_mgmt_din),
        .use_mmc                (at_use_mmc_q),
        .floppy_write_protect   (hps_status[20:19]),
        .floppy_present         (at_floppy_present),
        .floppy_request         (at_floppy_request),
        .ide_request            (at_ide_request),
        .cpu_address            (at_cpu_address),
        .cpu_data_out           (at_cpu_data_out),
        .cpu_data_in            (at_cpu_data_in),
        .cpu_data_oe            (at_cpu_data_oe),
        .cpu_bus_valid          (at_cpu_bus_valid),
        .cpu_bus_write          (at_cpu_bus_write),
        .cpu_bus_bhe_n          (at_cpu_bus_bhe_n),
        .cpu_bus_status         (at_cpu_bus_status),
        .cpu_bus_lock           (at_cpu_bus_lock),
        .cpu_hlda               (at_cpu_hlda),
        .cpu_ready              (at_cpu_ready),
        .cpu_halted             (at_cpu_halted),
        .cpu_shutdown           (at_cpu_shutdown),
`ifndef SPK286_AT_NO_DEBUG
        .intr                   (at_debug_intr),
        .irq_request            (at_debug_irq_request),
        .dma_grant              (at_debug_dma_grant),
        .refresh_grant          (at_debug_refresh_grant),
        .debug_bridge_error     (at_debug_bridge_error),
        .debug_control_error    (at_debug_control_error),
        .debug_unsupported_opcode(at_debug_unsupported_opcode),
        .debug_microcode_fault  (at_debug_microcode_fault),
        .debug_operand_blocked  (at_debug_operand_blocked),
        .debug_event_completed  (),
        .debug_event_vector     (),
        .debug_event_kind       (),
        .debug_opcode           (at_debug_opcode),
        .debug_cs               (at_debug_cs),
        .debug_cs_base          (),
        .debug_ip               (at_debug_ip),
        .debug_flags            (at_debug_flags),
        .debug_gpr              (at_debug_gpr),
        .debug_instruction_retired(at_debug_instruction_retired),
        .debug_segment_selectors(),
        .debug_fetch_blocked    (at_debug_fetch_blocked),
        .debug_fetch_cursor     (),
        .debug_micro_pc         (at_debug_micro_pc),
        .debug_micro_entry      (),
        .debug_micro_instruction(),
        .debug_micro_active     (),
        .debug_prefetch_count   (),
        .debug_bus_state        (at_debug_bus_state),
        .debug_biu_detail       (at_debug_biu_detail),
        .debug_last_post        (at_debug_last_post),
        .debug_cpu_cycle_count  (),
        .debug_at_cycle_count   (),
        .debug_trace0           (at_debug_trace0),
        .debug_trace1           (),
        .debug_trace2           (),
        .debug_trace3           (),
        .debug_keyboard_keycode (),
        .debug_keyboard_irq     (),
        .debug_keyboard_port_b  (),
        .debug_keyboard_pic_int (),
        .debug_dma_request      (),
        .debug_dma_acknowledge_n(),
        .debug_at_address       (at_debug_address),
        .debug_at_data_out      (at_debug_data_out),
        .debug_at_data_in       (at_debug_data_in),
        .debug_at_status        (at_debug_status),
        .debug_at_valid         (at_debug_valid),
        .debug_at_write         (at_debug_write),
        .debug_at_io            (at_debug_io),
        .debug_at_inta          (),
        .debug_at_code          (),
        .debug_at_byte_high     (),
        .debug_at_memory_projection(),
        .debug_at_cycle_active  (),
        .debug_at_ready         (at_debug_ready),
        .debug_at_read_data_valid(at_debug_read_data_valid),
        .debug_dma_bus_request  (at_debug_dma_bus_request),
        .debug_refresh_request  (at_debug_refresh_request),
        .debug_bridge_state     (at_debug_bridge_state),
        .cpu_hold_request       (at_debug_hold_request),
        .bridge_idle            (at_debug_bridge_idle),
`endif
        .memory_request_valid   (cpu_memory_valid),
        .memory_command_valid   (cpu_memory_command_valid),
        .memory_write           (cpu_memory_write),
        .memory_code_fetch      (cpu_memory_code_fetch),
        .memory_cycle_class     (cpu_memory_cycle_class),
        .memory_address         (cpu_memory_address),
        .memory_byte_enable     (cpu_memory_byte_enable),
        .memory_data_out        (cpu_memory_data_out),
        .memory_accept          (cpu_memory_accept),
        .memory_ready           (cpu_memory_ready),
        .memory_read_data       (cpu_memory_read_data),
        .memory_read_data_valid (cpu_memory_read_data_valid),
        .dma_memory_valid       (dma_memory_valid),
        .dma_memory_write       (dma_memory_write),
        .dma_memory_read        (dma_memory_read),
        .dma_memory_address     (dma_memory_address),
        .dma_memory_byte_enable (dma_memory_byte_enable),
        .dma_memory_data_out    (dma_memory_data_out),
        .dma_memory_accept      (dma_memory_accept),
        .dma_memory_ready       (dma_memory_ready),
        .dma_memory_data_in     (dma_memory_data_in),
        .refresh_memory_valid   (refresh_memory_valid),
        .refresh_memory_address (refresh_memory_address),
        .refresh_memory_accept  (refresh_memory_accept),
        .refresh_memory_ready   (refresh_memory_ready),
        .cpu_fault              (cpu_fault),
        .cpu_reset_request      (at_cpu_reset_request),
        .speaker_active         (at_speaker_active),
        .speaker_level          (at_speaker_level),
        .opl2_sound             (at_opl2_sound),
        .cms_sound_l            (at_cms_sound_l),
        .cms_sound_r            (at_cms_sound_r),
        .tandy_sound            (at_tandy_sound),
        .sb_sound_l             (at_sb_sound_l),
        .sb_sound_r             (at_sb_sound_r),
        .midi_tx               (midi_tx),
        .uart1_rts_n           (uart1_rts_n),
        .uart2_tx              (uart2_tx),
        .uart2_rts_n           (uart2_rts_n),
        .uart2_dtr_n           (uart2_dtr_n),
        .protocol_error         (machine_protocol_error),
        .video_red              (at_video_red_raw),
        .video_green            (at_video_green_raw),
        .video_blue             (at_video_blue_raw),
        .video_hsync            (at_video_hsync_raw),
        .video_hblank           (at_video_hblank_raw),
        .video_dbl_hsync        (at_video_dbl_hsync_raw),
        .video_vsync            (at_video_vsync_raw),
        .video_vblank           (at_video_vblank_raw),
        .video_vblank_border    (at_video_vblank_border_raw),
        .video_de               (at_video_de_raw),
        .video_dot_toggle       (at_video_dot_toggle_raw),
        .video_scandouble_active(at_video_scandouble_raw),
        .video_vmode_toggle     (at_video_vmode_toggle_raw),
        .video_mode350          (at_video_mode350_raw),
        .video_active_dots      (at_video_active_dots_raw),
        .video_active_lines     (at_video_active_lines_raw),
        .at286ctl_cpu           (at286ctl_cpu),
        .at286ctl_exp           (at286ctl_exp),
        .at286ctl_vid           (at286ctl_vid),
        .at286ctl_inp           (at286ctl_inp),
        .at286ctl_midi          (at286ctl_midi),
        .at286ctl_exp2          (at286ctl_exp2),
        .at286ctl_crt           (at286ctl_crt),
        .at286ctl_sync          (at286ctl_sync)
    );

    // The AT device owns the EGA registers, planar VRAM and raster.  The EGA
    // itself runs at 28.636 MHz; MiSTer's video shell receives the same
    // 57.272 MHz phase-shifted pipeline clock used by the established XT
    // profile.  A dot toggle is crossed to the pipeline domain so CE_PIXEL
    // remains the real EGA dot enable in both 14.318 and 16.257 MHz modes.
    logic       at_video_dot_d_q;
    logic       at_video_dot_dd_q;
    logic [7:0] at_video_r_pipe_q;
    logic [7:0] at_video_g_pipe_q;
    logic [7:0] at_video_b_pipe_q;
    logic       at_video_hs_pipe_q;
    logic       at_video_hb_pipe_q;
    logic       at_video_vs_pipe_q;
    logic       at_video_vb_pipe_q;
    logic       at_video_de_pipe_q;
    logic       at_video_ce_pipe_q;
    logic [7:0] at_video_r_out_q;
    logic [7:0] at_video_g_out_q;
    logic [7:0] at_video_b_out_q;
    logic       at_video_hs_out_q;
    logic       at_video_hb_out_q;
    logic       at_video_vs_out_q;
    logic       at_video_vb_out_q;
    logic       at_video_de_out_q;
    logic       at_video_ce_out_q;

    always_ff @(posedge at_video_clk_57) begin
        if (at_video_pipe_reset_57) begin
            at_video_dot_d_q  <= 1'b0;
            at_video_dot_dd_q <= 1'b0;
            at_video_r_pipe_q <= 8'h00;
            at_video_g_pipe_q <= 8'h00;
            at_video_b_pipe_q <= 8'h00;
            at_video_hs_pipe_q <= 1'b1;
            at_video_hb_pipe_q <= 1'b1;
            at_video_vs_pipe_q <= 1'b1;
            at_video_vb_pipe_q <= 1'b1;
            at_video_de_pipe_q <= 1'b0;
            at_video_ce_pipe_q <= 1'b0;
        end else begin
            at_video_dot_d_q  <= at_video_dot_toggle_raw;
            at_video_dot_dd_q <= at_video_dot_d_q;
            at_video_r_pipe_q <= {at_video_red_raw, 2'b00};
            at_video_g_pipe_q <= {at_video_green_raw, 2'b00};
            at_video_b_pipe_q <= {at_video_blue_raw, 2'b00};
            at_video_hs_pipe_q <= at_video_hsync_raw;
            at_video_hb_pipe_q <= at_video_hblank_raw;
            at_video_vs_pipe_q <= at_video_vsync_raw;
            at_video_vb_pipe_q <= at_video_vblank_raw;
            at_video_de_pipe_q <= at_video_de_raw;
            at_video_ce_pipe_q <= at_video_dot_d_q ^ at_video_dot_dd_q;
        end
    end

    // Apply the selected monitor phosphor in the pixel domain. Sync and
    // blanking pass through the same converter so their edges stay aligned
    // with the tinted RGB values.
    wire [7:0] at_video_mono_r;
    wire [7:0] at_video_mono_g;
    wire [7:0] at_video_mono_b;
    wire       at_video_mono_hs;
    wire       at_video_mono_hb;
    wire       at_video_mono_vs;
    wire       at_video_mono_vb;

    video_monochrome_converter u_at_video_display (
        .clk_vid    (at_video_clk_57),
        .ce_pix     (at_video_ce_pipe_q),
        .gfx_mode   (at_video_display_q),
        .R          (at_video_r_pipe_q),
        .G          (at_video_g_pipe_q),
        .B          (at_video_b_pipe_q),
        .HSync      (at_video_hs_pipe_q),
        .VSync      (at_video_vs_pipe_q),
        .HBlank     (at_video_hb_pipe_q),
        .VBlank     (at_video_vb_pipe_q),
        .R_OUT      (at_video_mono_r),
        .G_OUT      (at_video_mono_g),
        .B_OUT      (at_video_mono_b),
        .HSync_OUT  (at_video_mono_hs),
        .VSync_OUT  (at_video_mono_vs),
        .HBlank_OUT (at_video_mono_hb),
        .VBlank_OUT (at_video_mono_vb)
    );

    logic       at_video_mode350_s1_q;
    logic       at_video_mode350_s2_q;
    logic [11:0] at_video_active_dots_s1_q;
    logic [11:0] at_video_active_dots_s2_q;
    logic [9:0]  at_video_active_lines_s1_q;
    logic [9:0]  at_video_active_lines_s2_q;
    always_ff @(posedge at_video_clk_57) begin
        if (at_video_pipe_reset_57) begin
            at_video_mode350_s1_q <= 1'b0;
            at_video_mode350_s2_q <= 1'b0;
            at_video_active_dots_s1_q <= 12'd0;
            at_video_active_dots_s2_q <= 12'd0;
            at_video_active_lines_s1_q <= 10'd0;
            at_video_active_lines_s2_q <= 10'd0;
        end else begin
            at_video_mode350_s1_q <= at_video_mode350_raw;
            at_video_mode350_s2_q <= at_video_mode350_s1_q;
            at_video_active_dots_s1_q <= at_video_active_dots_raw;
            at_video_active_dots_s2_q <= at_video_active_dots_s1_q;
            at_video_active_lines_s1_q <= at_video_active_lines_raw;
            at_video_active_lines_s2_q <= at_video_active_lines_s1_q;
        end
    end

    // 0 keeps the native EGA raster, 1 converts the captured frame to 480i,
    // and 2 converts it to 240p. The framebuffer is used only when the EGA
    // CRTC is actually producing a 350-line mode.
    wire [8:0] at_crt350_config_source = {
        hps_status[35:34], at286ctl_eff_crt_h, at286ctl_eff_crt_v
    };
    reg [8:0] at_crt350_config_sent_q = 9'd0;
    wire at_crt350_config_ready;
    wire [8:0] at_crt350_config_video;
    always_ff @(posedge CLK_50M) begin
        if (at_crt350_config_ready &&
            at_crt350_config_source != at_crt350_config_sent_q)
            at_crt350_config_sent_q <= at_crt350_config_source;
    end
    at_cdc_snapshot #(.WIDTH(9)) at_crt350_config_cdc (
        .src_clk   (CLK_50M),
        .src_send  (at_crt350_config_ready &&
                    at_crt350_config_source != at_crt350_config_sent_q),
        .src_data  (at_crt350_config_source),
        .src_ready (at_crt350_config_ready),
        .dst_clk   (at_video_clk_57),
        .dst_data  (at_crt350_config_video),
        .dst_update()
    );
    wire [1:0] at_video_crt350_mode = at_crt350_config_video[8:7];
    wire       at_video_crt350_enable = at_video_mode350_s2_q &
                                         (|at_video_crt350_mode);
    wire       at_video_crt350_progressive = at_video_crt350_mode[1];

    wire [7:0]  at_fb_cap_burstcnt;
    wire [28:0] at_fb_cap_addr;
    wire [63:0] at_fb_cap_din;
    wire        at_fb_cap_we;
    wire        at_fb_cap_busy;
    wire [1:0]  at_fb_frame_buffer;
    wire [11:0] at_fb_frame_width;
    wire [9:0]  at_fb_frame_height;
    wire [13:0] at_fb_frame_stride;
    wire        at_fb_frame_valid;
    wire [1:0]  at_fb_reading_buffer;

    ega_fb_capture u_at_ega_fb_capture (
        .clk            (at_video_clk_57),
        .reset          (at_video_pipe_reset_57),
        .enable         (at_video_crt350_enable),
        .ce_pix         (at_video_ce_pipe_q),
        .r              (at_video_mono_r),
        .g              (at_video_mono_g),
        .b              (at_video_mono_b),
        .de             (~at_video_mono_hb & ~at_video_mono_vb),
        .vblank         (at_video_mono_vb),
        .active_dots    (at_video_active_dots_s2_q),
        .active_lines   (at_video_active_lines_s2_q),
        .reading_buffer (at_fb_reading_buffer),
        .ddram_busy     (at_fb_cap_busy),
        .ddram_burstcnt (at_fb_cap_burstcnt),
        .ddram_addr     (at_fb_cap_addr),
        .ddram_din      (at_fb_cap_din),
        .ddram_be       (),
        .ddram_we       (at_fb_cap_we),
        .frame_buffer   (at_fb_frame_buffer),
        .frame_width    (at_fb_frame_width),
        .frame_height   (at_fb_frame_height),
        .frame_stride   (at_fb_frame_stride),
        .frame_seq      (),
        .frame_valid    (at_fb_frame_valid),
        .overrun        ()
    );

    wire        at_fb_rd_req;
    wire [28:0] at_fb_rd_addr;
    wire [7:0]  at_fb_rd_burstcnt;
    wire        at_fb_rd_grant;
    wire [63:0] at_fb_rd_data;
    wire        at_fb_rd_data_valid;
    wire [7:0]  at_fb_r;
    wire [7:0]  at_fb_g;
    wire [7:0]  at_fb_b;
    wire        at_fb_hs;
    wire        at_fb_vs;
    wire        at_fb_hb;
    wire        at_fb_vb;
    wire        at_fb_de;
    wire        at_fb_field;
    wire        at_fb_ce_pix;

    ega_fb_readout u_at_ega_fb_readout (
        .clk            (at_video_clk_57),
        .reset          (at_video_pipe_reset_57),
        .enable         (at_video_crt350_enable),
        .progressive    (at_video_crt350_progressive),
        .crt_h_offset   (at_crt350_config_video[6:3]),
        .crt_v_offset   (at_crt350_config_video[2:0]),
        .frame_buffer   (at_fb_frame_buffer),
        .frame_width    (at_fb_frame_width),
        .frame_height   (at_fb_frame_height),
        .frame_stride   (at_fb_frame_stride),
        .frame_valid    (at_fb_frame_valid),
        .rd_req         (at_fb_rd_req),
        .rd_addr        (at_fb_rd_addr),
        .rd_burstcnt    (at_fb_rd_burstcnt),
        .rd_grant       (at_fb_rd_grant),
        .rd_data        (at_fb_rd_data),
        .rd_data_valid  (at_fb_rd_data_valid),
        .r              (at_fb_r),
        .g              (at_fb_g),
        .b              (at_fb_b),
        .hsync          (at_fb_hs),
        .vsync          (at_fb_vs),
        .hblank         (at_fb_hb),
        .vblank         (at_fb_vb),
        .de             (at_fb_de),
        .field          (at_fb_field),
        .ce_pix         (at_fb_ce_pix),
        .reading_buffer (at_fb_reading_buffer)
    );

    assign DDRAM_CLK = at_video_clk_57;
    ega_ddr_arbiter u_at_ega_ddr_arbiter (
        .clk             (at_video_clk_57),
        .reset           (at_video_pipe_reset_57),
        .ddram_busy      (DDRAM_BUSY),
        .ddram_burstcnt  (DDRAM_BURSTCNT),
        .ddram_addr      (DDRAM_ADDR),
        .ddram_din       (DDRAM_DIN),
        .ddram_be        (DDRAM_BE),
        .ddram_we        (DDRAM_WE),
        .ddram_rd        (DDRAM_RD),
        .ddram_dout      (DDRAM_DOUT),
        .ddram_dout_ready(DDRAM_DOUT_READY),
        .rd_req          (at_fb_rd_req),
        .rd_addr         (at_fb_rd_addr),
        .rd_burstcnt     (at_fb_rd_burstcnt),
        .rd_grant        (at_fb_rd_grant),
        .rd_data         (at_fb_rd_data),
        .rd_data_valid   (at_fb_rd_data_valid),
        .wr_req          (at_fb_cap_we),
        .wr_addr         (at_fb_cap_addr),
        .wr_burstcnt     (at_fb_cap_burstcnt),
        .wr_din          (at_fb_cap_din),
        .wr_busy_out     (at_fb_cap_busy),
        .wr_grant        ()
    );

    wire at_video_crt350_active;
    video_source_switch u_at_video_crt350_switch (
        .clock         (at_video_clk_57),
        .reset         (at_video_pipe_reset_57),
        .select_alt    (at_video_crt350_enable & at_fb_frame_valid),
        .primary_hsync (at_video_mono_hs),
        .primary_vblank(at_video_mono_vb),
        .alt_hsync     (at_fb_hs),
        .alt_vblank    (at_fb_vb),
        .alt_active    (at_video_crt350_active)
    );

    wire [7:0] at_video_mix_r = at_video_crt350_active ? at_fb_r : at_video_mono_r;
    wire [7:0] at_video_mix_g = at_video_crt350_active ? at_fb_g : at_video_mono_g;
    wire [7:0] at_video_mix_b = at_video_crt350_active ? at_fb_b : at_video_mono_b;
    wire       at_video_mix_hs = at_video_crt350_active ? at_fb_hs : at_video_mono_hs;
    wire       at_video_mix_vs = at_video_crt350_active ? at_fb_vs : at_video_mono_vs;
    wire       at_video_mix_hb = at_video_crt350_active ? at_fb_hb : at_video_mono_hb;
    wire       at_video_mix_vb = at_video_crt350_active ? at_fb_vb : at_video_mono_vb;
    wire       at_video_mix_ce = at_video_crt350_active ? at_fb_ce_pix : at_video_ce_pipe_q;
    wire       at_video_mixer_ce;
    wire [7:0] at_video_mixer_r;
    wire [7:0] at_video_mixer_g;
    wire [7:0] at_video_mixer_b;
    wire       at_video_mixer_hs;
    wire       at_video_mixer_vs;
    wire       at_video_mixer_de;
    logic      at_video_vga_f1_ps1;
    logic      at_video_vga_f1_ps2;

    video_mixer #(.GAMMA(1)) u_at_video_mixer (
        .CLK_VIDEO  (at_video_clk_57),
        .CE_PIXEL   (at_video_mixer_ce),
        .ce_pix     (at_video_mix_ce),
        .scandoubler(1'b0),
        .hq2x       (at_video_scale_q == 2'd1),
        .gamma_bus  (gamma_bus_video),
        .R          (at_video_mix_r),
        .G          (at_video_mix_g),
        .B          (at_video_mix_b),
        .HSync      (at_video_mix_hs),
        .VSync      (at_video_mix_vs),
        .HBlank     (at_video_mix_hb),
        .VBlank     (at_video_mix_vb),
        .HDMI_FREEZE(1'b0),
        .freeze_sync(),
        .VGA_R      (at_video_mixer_r),
        .VGA_G      (at_video_mixer_g),
        .VGA_B      (at_video_mixer_b),
        .VGA_VS     (at_video_mixer_vs),
        .VGA_HS     (at_video_mixer_hs),
        .VGA_DE     (at_video_mixer_de)
    );

    always_ff @(posedge at_video_clk_57_ps) begin
        if (at_video_pipe_reset_57_ps) begin
            at_video_vga_f1_ps1 <= 1'b0;
            at_video_vga_f1_ps2 <= 1'b0;
        end else begin
            at_video_vga_f1_ps1 <= at_video_crt350_active & at_fb_field;
            at_video_vga_f1_ps2 <= at_video_vga_f1_ps1;
        end
    end

    always_ff @(posedge at_video_clk_57_ps) begin
        if (at_video_pipe_reset_57_ps) begin
            at_video_r_out_q <= 8'h00;
            at_video_g_out_q <= 8'h00;
            at_video_b_out_q <= 8'h00;
            at_video_hs_out_q <= 1'b0;
            at_video_hb_out_q <= 1'b1;
            at_video_vs_out_q <= 1'b0;
            at_video_vb_out_q <= 1'b1;
            at_video_de_out_q <= 1'b0;
            at_video_ce_out_q <= 1'b0;
        end else begin
            at_video_r_out_q <= at_video_mixer_r;
            at_video_g_out_q <= at_video_mixer_g;
            at_video_b_out_q <= at_video_mixer_b;
            at_video_hs_out_q <= at_video_mixer_hs;
            at_video_hb_out_q <= at_video_mix_hb;
            at_video_vs_out_q <= at_video_mixer_vs;
            at_video_vb_out_q <= at_video_mix_vb;
            at_video_de_out_q <= at_video_mixer_de;
            at_video_ce_out_q <= at_video_mixer_ce;
        end
    end

    wire        at_debug_hb_out;
    wire        at_debug_vb_out;
    wire [23:0] at_debug_rgb_out;

`ifndef SPK286_AT_NO_DEBUG
`ifdef SPK286_AT_DEBUG_STABLE_RASTER
    // Diagnostic output timing is independent of the EGA CRTC. A BIOS
    // reprogramming the CRTC can otherwise freeze the last debug snapshot on
    // screen even while the CPU and the snapshot mailbox keep running.
    logic at_debug_ce_q;
    logic [9:0] at_debug_hpos_q;
    logic [8:0] at_debug_vpos_q;
    always_ff @(posedge at_video_clk_57_ps) begin
        if (at_video_pipe_reset_57_ps) begin
            at_debug_ce_q   <= 1'b0;
            at_debug_hpos_q <= 10'd0;
            at_debug_vpos_q <= 9'd0;
        end else begin
            at_debug_ce_q <= ~at_debug_ce_q;
            if (at_debug_ce_q) begin
                if (at_debug_hpos_q == 10'd899) begin
                    at_debug_hpos_q <= 10'd0;
                    at_debug_vpos_q <= at_debug_vpos_q == 9'd448 ?
                                       9'd0 : at_debug_vpos_q + 9'd1;
                end else
                    at_debug_hpos_q <= at_debug_hpos_q + 10'd1;
            end
        end
    end
    wire at_debug_hs = !(at_debug_hpos_q >= 10'd720 &&
                         at_debug_hpos_q < 10'd816);
    wire at_debug_vs = !(at_debug_vpos_q >= 9'd440 &&
                         at_debug_vpos_q < 9'd442);
    wire at_debug_hb = !(at_debug_hpos_q >= 10'd48 &&
                         at_debug_hpos_q < 10'd688);
    wire at_debug_vb = !(at_debug_vpos_q >= 9'd35 &&
                         at_debug_vpos_q < 9'd435);
    wire at_debug_pxl_cen = at_debug_ce_q;
`else
    wire at_debug_hs = at_video_hs_out_q;
    wire at_debug_vs = at_video_vs_out_q;
    wire at_debug_hb = at_video_hb_out_q;
    wire at_debug_vb = at_video_vb_out_q;
    wire at_debug_pxl_cen = at_video_ce_out_q;
`endif
    // The single-page overlay is passive and never drives the machine.
    spk286_debug_min_overlay #(
        .COLW(8),
        .CPU_DIV2(AT_CPU_DIV2_ENABLED)
    ) u_at_debug_overlay (
        .rst                    (at_video_pipe_reset_57_ps),
        .src_rst                (at_boot_reset),
        .src_clk                (CLK_50M),
        .clk                    (at_video_clk_57_ps),
        .pxl_cen                (at_debug_pxl_cen),
        .HS                     (at_debug_hs),
        .VS                     (at_debug_vs),
        .HB                     (at_debug_hb),
        .VB                     (at_debug_vb),
`ifdef SPK286_AT_DEBUG_STABLE_RASTER
        .rgb_in                 (24'h000000),
`else
        .rgb_in                 ({at_video_r_out_q,
                                  at_video_g_out_q,
                                  at_video_b_out_q}),
`endif
        .cpu_reset              (at_machine_reset | at_cpu_reset_request),
        .cpu_halted             (at_cpu_halted),
        .cpu_shutdown           (at_cpu_shutdown),
        .cpu_control_error      (at_debug_control_error),
        .cpu_unsupported_opcode (at_debug_unsupported_opcode),
        .cpu_microcode_fault    (at_debug_microcode_fault),
        .cpu_operand_blocked    (at_debug_operand_blocked),
        .bridge_error           (at_debug_bridge_error |
                                 keyboard_event_overflow),
        .cpu_opcode             (at_debug_opcode),
        .cpu_cs                 (at_debug_cs),
        .cpu_ip                 (at_debug_ip),
        .cpu_flags              (at_debug_flags),
        .cpu_cx                 (at_debug_gpr[31:16]),
        .cpu_micro_pc           (at_debug_micro_pc),
        .cpu_biu_state          (at_debug_bus_state),
        .cpu_fetch_blocked      (at_debug_fetch_blocked),
        .cpu_ready              (at_cpu_ready),
        .cpu_bus_valid          (at_cpu_bus_valid),
        .cpu_hlda               (at_cpu_hlda),
        .instruction_retired    (at_debug_instruction_retired),
        .irq8                   (at_debug_irq_request[8]),
        .cpu_intr               (at_debug_intr),
        .last_post              (at_debug_last_post),
        .trace0                 (at_debug_trace0),
        .at_address             (at_debug_address),
        .at_data_out            (at_debug_data_out),
        .at_data_in             (at_debug_data_in),
        .at_status              (at_debug_status),
        .at_valid               (at_debug_valid),
        .at_write               (at_debug_write),
        .at_io                  (at_debug_io),
        .at_ready               (at_debug_ready),
        .at_read_data_valid     (at_debug_read_data_valid),
        .bridge_idle            (at_debug_bridge_idle),
        .bridge_state           (at_debug_bridge_state),
        .hold_request           (at_debug_hold_request),
        .dma_request            (at_debug_dma_bus_request),
        .refresh_request        (at_debug_refresh_request),
        .dma_grant              (at_debug_dma_grant),
        .refresh_grant          (at_debug_refresh_grant),
        .memory_port_state      (memory_port_debug_state),
        .read_buffer_state      (p03_debug_state),
        .sdram_owner_state      (sdram_owner_debug_state),
        .biu_detail             (at_debug_biu_detail),
        .HB_out                 (at_debug_hb_out),
        .VB_out                 (at_debug_vb_out),
        .rgb_out                (at_debug_rgb_out)
    );
`endif

`ifndef SPK286_AT_NO_DEBUG
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic at_debug_enable_sync1_q;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic at_debug_enable_sync2_q;
    always_ff @(posedge at_video_clk_57_ps) begin
        if (at_video_pipe_reset_57_ps) begin
            at_debug_enable_sync1_q <= 1'b0;
            at_debug_enable_sync2_q <= 1'b0;
        end else begin
            at_debug_enable_sync1_q <= at_debug_enable;
            at_debug_enable_sync2_q <= at_debug_enable_sync1_q;
        end
    end

    logic at_use_debug_q;
    always_ff @(posedge at_video_clk_57_ps) begin
        if (at_video_pipe_reset_57_ps)
            at_use_debug_q <= 1'b0;
        else if (at_debug_vb)
            at_use_debug_q <= at_debug_enable_sync2_q;
    end
`else
    logic at_use_debug_q;
    assign at_use_debug_q = 1'b0;
    assign at_debug_hb_out = 1'b0;
    assign at_debug_vb_out = 1'b0;
    assign at_debug_rgb_out = 24'h000000;
`endif

    wire at_video_fault = cpu_fault | machine_protocol_error | keyboard_event_overflow |
                          memory_port_protocol_error |
                          sdram_owner_protocol_error |
                          loader_protocol_error;

    assign CLK_VIDEO    = at_video_clk_57_ps;
`ifndef SPK286_AT_NO_DEBUG
    assign CE_PIXEL     = at_use_debug_q ? at_debug_pxl_cen : at_video_ce_out_q;
`else
    assign CE_PIXEL     = at_video_ce_out_q;
`endif
    assign VIDEO_ARX    = at_video_arx_q;
    assign VIDEO_ARY    = at_video_ary_q;
    assign VGA_R        = at_use_debug_q ? at_debug_rgb_out[23:16] :
                          at_video_r_out_q;
    assign VGA_G        = at_use_debug_q ? at_debug_rgb_out[15:8] :
                          at_video_g_out_q;
    assign VGA_B        = at_use_debug_q ? at_debug_rgb_out[7:0] :
                          at_video_b_out_q;
`ifndef SPK286_AT_NO_DEBUG
    assign VGA_HS       = at_use_debug_q ? at_debug_hs : at_video_hs_out_q;
    assign VGA_VS       = at_use_debug_q ? at_debug_vs : at_video_vs_out_q;
`else
    assign VGA_HS       = at_video_hs_out_q;
    assign VGA_VS       = at_video_vs_out_q;
`endif
    assign VGA_DE       = at_use_debug_q ?
                          (~at_debug_hb_out & ~at_debug_vb_out) :
                          at_video_de_out_q;
    assign VGA_F1       = at_video_vga_f1_ps2;
    assign VGA_SL       = {at_video_scale_q == 2'd3,
                           at_video_scale_q == 2'd2};
    assign VGA_SCALER   = 1'b0;
    assign VGA_DISABLE  = 1'b0;
    assign HDMI_FREEZE  = 1'b0;
    assign HDMI_BLACKOUT = 1'b0;
    assign HDMI_BOB_DEINT = 1'b0;
    assign LED_USER     = cpu_fault | machine_protocol_error | keyboard_event_overflow |
                          memory_port_protocol_error |
                          sdram_owner_protocol_error |
                          loader_protocol_error;
    assign LED_POWER    = 2'b00;
    assign LED_DISK     = {1'b0, main_rom_loaded};
    assign BUTTONS      = hps_buttons;

    // External MT32-pi bridge. It speaks the same USER I/O protocol as the
    // source profile: MIDI serial to the MPU-401, I²S audio back into the
    // core, and I²C status/LCD updates for the optional OSD overlay.
    mt32pi u_mt32pi (
        .CLK_AUDIO       (CLK_AUDIO),
        .CLK_VIDEO       (CLK_VIDEO),
        .CE_PIXEL        (CE_PIXEL),
        .VGA_VS          (VGA_VS),
        .VGA_DE          (VGA_DE),
        // Do not let the MT32-pi receiver sample COM2's USER I/O pins when
        // that connector is assigned to the UART; ao486 uses the same idle
        // isolation to prevent a serial line from becoming a MIDI byte/IRQ.
        .USER_IN         (user_io_mt32 ? USER_IN : 7'h7F),
        .USER_OUT        (mt32_user_out),
        .reset           (mt32_reset),
        .midi_tx         (midi_tx | mt32_mute),
        .midi_rx         (mt32_pi_midi_rx),
        .mt32_i2s_r      (mt32_i2s_r),
        .mt32_i2s_l      (mt32_i2s_l),
        .mt32_available  (mt32_available),
        .mt32_mode_req   (mt32_mode_req),
        .mt32_rom_req    (mt32_rom_req),
        .mt32_sf_req     (mt32_sf_req),
        .mt32_mode       (mt32_mode),
        .mt32_rom        (mt32_rom),
        .mt32_sf         (mt32_sf),
        .mt32_newmode    (mt32_newmode),
        .mt32_lcd_en     (mt32_lcd_en),
        .mt32_lcd_pix    (mt32_lcd_pix),
        .mt32_lcd_update (mt32_lcd_update)
    );

    // MiSTer audio mixer. This retains the source profile's volume, boost
    // and stereo-mix controls while summing the PC speaker, FM, C/MS, Tandy,
    // Sound Blaster and MT32-pi sources.
    wire signed [16:0] audio_opl2 = {at_opl2_sound[15], at_opl2_sound};
    wire signed [16:0] audio_cms_l = {at_cms_sound_l[15], at_cms_sound_l};
    wire signed [16:0] audio_cms_r = {at_cms_sound_r[15], at_cms_sound_r};
    wire signed [16:0] audio_sb_l = {at_sb_sound_l[15], at_sb_sound_l};
    wire signed [16:0] audio_sb_r = {at_sb_sound_r[15], at_sb_sound_r};
    wire [16:0] audio_tandy = `ENABLE_TANDY_AUDIO ?
        {{{2{at_tandy_sound[10]}}, {4{at_tandy_sound[10]}}, at_tandy_sound}
          << hps_status[33:32], 2'b00} : 17'd0;
    wire [15:0] audio_speaker_amplitude =
        16'h0800 << hps_status[33:32];
    wire signed [16:0] audio_speaker = !at_speaker_active ? 17'sd0 :
        at_speaker_level ? $signed({1'b0, audio_speaker_amplitude}) :
                            -$signed({1'b0, audio_speaker_amplitude});
    wire signed [16:0] audio_mt32_l_ext =
        {mt32_i2s_l[15], mt32_i2s_l};
    wire signed [16:0] audio_mt32_r_ext =
        {mt32_i2s_r[15], mt32_i2s_r};
    wire signed [16:0] audio_mt32_l = mt32_use ?
        {audio_mt32_l_ext[16], audio_mt32_l_ext[16:1]} : 17'sd0;
    wire signed [16:0] audio_mt32_r = mt32_use ?
        {audio_mt32_r_ext[16], audio_mt32_r_ext[16:1]} : 17'sd0;
    wire signed [16:0] audio_sum_l = audio_opl2 + audio_cms_l +
                                      $signed(audio_tandy) + audio_speaker +
                                      audio_sb_l + audio_mt32_l;
    wire signed [16:0] audio_sum_r = audio_opl2 + audio_cms_r +
                                      $signed(audio_tandy) + audio_speaker +
                                      audio_sb_r + audio_mt32_r;

    localparam integer COMP_F1 = 4;
    localparam integer COMP_A1 = 2;
    localparam integer COMP_X1 = ((32767 * (COMP_F1 - 1)) /
                                  ((COMP_F1 * COMP_A1) - 1)) + 1;
    localparam integer COMP_B1 = COMP_X1 * COMP_A1;
    localparam integer COMP_F2 = 8;
    localparam integer COMP_A2 = 4;
    localparam integer COMP_X2 = ((32767 * (COMP_F2 - 1)) /
                                  ((COMP_F2 * COMP_A2) - 1)) + 1;
    localparam integer COMP_B2 = COMP_X2 * COMP_A2;

    function automatic [15:0] compress_audio(input [15:0] inp);
        reg [15:0] v;
        reg [15:0] v1;
        reg [15:0] v2;
        begin
            v  = inp[15] ? (~inp) + 1'd1 : inp;
            v1 = (v < COMP_X1) ? (v * COMP_A1) :
                 (((v - COMP_X1) / COMP_F1) + COMP_B1);
            v2 = (v < COMP_X2) ? (v * COMP_A2) :
                 (((v - COMP_X2) / COMP_F2) + COMP_B2);
            v = hps_status[37] ? v2 : v1;
            compress_audio = inp[15] ? ~(v - 1'd1) : v;
        end
    endfunction

    logic signed [15:0] audio_out_l_q;
    logic signed [15:0] audio_out_r_q;
    logic signed [15:0] audio_cmp_l_q;
    logic signed [15:0] audio_cmp_r_q;
    always_ff @(posedge CLK_50M or posedge RESET) begin
        if (RESET) begin
            audio_out_l_q <= 16'sd0;
            audio_out_r_q <= 16'sd0;
            audio_cmp_l_q <= 16'sd0;
            audio_cmp_r_q <= 16'sd0;
        end else begin
            audio_out_l_q <= (^audio_sum_l[16:15]) ?
                             {audio_sum_l[16], {15{audio_sum_l[15]}}} :
                             audio_sum_l[15:0];
            audio_out_r_q <= (^audio_sum_r[16:15]) ?
                             {audio_sum_r[16], {15{audio_sum_r[15]}}} :
                             audio_sum_r[15:0];
            audio_cmp_l_q <= compress_audio(audio_out_l_q);
            audio_cmp_r_q <= compress_audio(audio_out_r_q);
        end
    end

    assign AUDIO_L      = hps_status[37:36] ? audio_cmp_l_q : audio_out_l_q;
    assign AUDIO_R      = hps_status[37:36] ? audio_cmp_r_q : audio_out_r_q;
    assign AUDIO_S      = 1'b1;
    assign AUDIO_MIX    = hps_status[39:38];
    assign ADC_BUS      = 4'hz;
    assign SD_SCK       = 1'bz;
    assign SD_MOSI      = 1'bz;
    assign SD_CS        = 1'bz;
    // The HPS UART becomes the MPU-401 MIDI transport in its MIDI mode;
    // otherwise the selected COM2 path owns the pins. Match the source
    // profile by releasing the HPS modem outputs while MIDI mode is active.
    assign UART_TXD     = hps_midi ? midi_tx : uart2_tx;
    assign UART_RTS     = hps_midi ? 1'b0 : uart2_rts_n;
    assign UART_DTR     = hps_midi ? 1'b0 : uart2_dtr_n;
    assign USER_OUT     = user_io_mt32 ? mt32_user_out :
                          user_io_com2 ? {1'b1, 1'b1, uart2_dtr_n,
                                           1'b1, uart2_rts_n,
                                           uart2_tx, 1'b1} : 7'h7F;

endmodule
