// ZXTRES+ board top for PCAT-286 with DeMiSTify. Based on the DeMiSTify
// ZXTRES template (DeMiSTify/templates/zxtres, by somhi) and the PCXT
// DeMiSTify ZXTRES top: the DeMiSTify controller (an EightThirtyTwo CPU
// with the firmware built from zxtres/firmware) reads the microSD card and
// the PS/2 keyboard for the OSD, decodes the DB9 joysticks, and talks to
// the guest core over the MiST SPI protocol.
`timescale 1ns/1ps
module zxtres_pcat_top (
    input  logic        CLOCK_50,
    output logic        LED,

    output logic [7:0]  VGA_R,
    output logic [7:0]  VGA_G,
    output logic [7:0]  VGA_B,
    output logic        VGA_HS,
    output logic        VGA_VS,

    output logic [12:0] SDRAM_A,
    inout  wire  [15:0] SDRAM_DQ,
    output logic        SDRAM_DQML,
    output logic        SDRAM_DQMH,
    output logic        SDRAM_nWE,
    output logic        SDRAM_nCAS,
    output logic        SDRAM_nRAS,
    output logic        SDRAM_nCS,
    output logic [1:0]  SDRAM_BA,
    output logic        SDRAM_CLK,
    output logic        SDRAM_CKE,

    output logic        SD_CS,
    output logic        SD_SCK,
    output logic        SD_MOSI,
    input  logic        SD_MISO,

    inout  wire         PS2_KEYBOARD_CLK,
    inout  wire         PS2_KEYBOARD_DAT,
    inout  wire         PS2_MOUSE_CLK,
    inout  wire         PS2_MOUSE_DAT,

    output logic        JOY_CLK,
    output logic        JOY_LOAD,
    input  logic        JOY_DATA,
    output logic        JOY_SEL,

    output logic        AUDIO_L,
    output logic        AUDIO_R,
    output logic        I2S_BCK,
    output logic        I2S_LRCK,
    output logic        I2S_DATA
);
    logic clk50;
    BUFG u_clock_bufg (.I(CLOCK_50), .O(clk50));

    // PS/2: open-collector lines. The keyboard is hidden from the guest
    // while the OSD is open (intercept).
    logic intercept;
    logic ps2k_clk_out, ps2k_dat_out, ps2m_clk_out, ps2m_dat_out;
    logic guest_ps2m_clk_out, guest_ps2m_dat_out;   // the guest's mouse port
    assign PS2_KEYBOARD_CLK = ps2k_clk_out ? 1'bz : 1'b0;
    assign PS2_KEYBOARD_DAT = ps2k_dat_out ? 1'bz : 1'b0;
    // The mouse belongs to the guest (COM1 serial mouse); the controller's
    // mouse outputs stay idle because the firmware has no PS/2 mouse support.
    assign PS2_MOUSE_CLK    = (ps2m_clk_out && guest_ps2m_clk_out) ? 1'bz : 1'b0;
    assign PS2_MOUSE_DAT    = (ps2m_dat_out && guest_ps2m_dat_out) ? 1'bz : 1'b0;

    // DB9 joysticks (Atari and Megadrive pads) as the controller's 8-bit
    // joystick words: fire2, fire1, right, left, down, up (active low).
    logic joy1_up, joy1_down, joy1_left, joy1_right, joy1_fire1, joy1_fire2;
    logic joy2_up, joy2_down, joy2_left, joy2_right, joy2_fire1, joy2_fire2;
    logic [11:0] joy1_b12, joy2_b12;
    /* verilator lint_off PINCONNECTEMPTY */
    joydecoder_neptuno u_joydecoder (
        .clk_i(clk50), .joy_data_i(JOY_DATA), .joy_clk_o(JOY_CLK), .joy_load_o(JOY_LOAD),
        .joy1_up_o(joy1_up), .joy1_down_o(joy1_down), .joy1_left_o(joy1_left),
        .joy1_right_o(joy1_right), .joy1_fire1_o(joy1_fire1), .joy1_fire2_o(joy1_fire2),
        .joy1_fire3_o(), .joy1_start_o(),
        .joy2_up_o(joy2_up), .joy2_down_o(joy2_down), .joy2_left_o(joy2_left),
        .joy2_right_o(joy2_right), .joy2_fire1_o(joy2_fire1), .joy2_fire2_o(joy2_fire2),
        .joy2_fire3_o(), .joy2_start_o()
    );
    /* verilator lint_on PINCONNECTEMPTY */
    joystick_sega u_sega (                       // default CLK_SPEED 50000 (50 MHz)
        .joy0({joy1_fire2, joy1_fire1, joy1_up, joy1_down, joy1_left, joy1_right}),
        .joy1({joy2_fire2, joy2_fire1, joy2_up, joy2_down, joy2_left, joy2_right}),
        .player1(joy1_b12), .player2(joy2_b12),
        .clk_i(clk50), .sega_strobe(JOY_SEL)
    );
    wire [7:0] joy1 = {2'b11, joy1_b12[4], joy1_b12[6], joy1_b12[0], joy1_b12[1],
                       joy1_b12[2], joy1_b12[3]};
    wire [7:0] joy2 = {2'b11, joy2_b12[4], joy2_b12[6], joy2_b12[0], joy2_b12[1],
                       joy2_b12[2], joy2_b12[3]};

    // Guest core.
    logic reset_n, act_led;
    logic spi_clk, spi_toguest, spi_ss2, spi_ss3, spi_ss4, conf_data0;
    wire  spi_fromguest;
    logic [15:0] dac_l, dac_r;
    // ZXTRES_SKELETON selects the MiST-interface test guest (zxtres_skeleton_guest)
    // instead of the PC/AT machine.
`ifdef ZXTRES_SKELETON
    assign guest_ps2m_clk_out = 1'b1;
    assign guest_ps2m_dat_out = 1'b1;
    zxtres_skeleton_guest guest (
        .CLOCK_50(clk50), .RESET_N(reset_n), .LED(act_led),
        .SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nWE(SDRAM_nWE), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nRAS(SDRAM_nRAS),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_BA(SDRAM_BA), .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE),
        .SPI_DO(spi_fromguest), .SPI_DI(spi_toguest), .SPI_SCK(spi_clk),
        .SPI_SS2(spi_ss2), .SPI_SS3(spi_ss3), .SPI_SS4(spi_ss4), .CONF_DATA0(conf_data0),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS),
        .PS2K_CLK_IN(PS2_KEYBOARD_CLK || intercept), .PS2K_DAT_IN(PS2_KEYBOARD_DAT),
        .DAC_L(dac_l), .DAC_R(dac_r)
    );
`else
    pcat286_zxtres_guest guest (
        .CLOCK_50(clk50), .RESET_N(reset_n), .LED(act_led),
        .SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nWE(SDRAM_nWE), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nRAS(SDRAM_nRAS),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_BA(SDRAM_BA), .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE),
        .SPI_DO(spi_fromguest), .SPI_DI(spi_toguest), .SPI_SCK(spi_clk),
        .SPI_SS2(spi_ss2), .SPI_SS3(spi_ss3), .SPI_SS4(spi_ss4), .CONF_DATA0(conf_data0),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS),
        .PS2K_CLK_IN(PS2_KEYBOARD_CLK || intercept), .PS2K_DAT_IN(PS2_KEYBOARD_DAT),
        .PS2M_CLK_IN(PS2_MOUSE_CLK), .PS2M_DAT_IN(PS2_MOUSE_DAT),
        .PS2M_CLK_OUT(guest_ps2m_clk_out), .PS2M_DAT_OUT(guest_ps2m_dat_out),
        .DAC_L(dac_l), .DAC_R(dac_r)
    );
`endif

    // DeMiSTify controller; SD_SCK is the shared SPI clock.
    /* verilator lint_off PINCONNECTEMPTY */
    // Default generics: sysclk_frequency 500 (50 MHz), the board clock.
    substitute_mcu controller (
        .clk(clk50), .reset_in(1'b1), .reset_out(reset_n),
        .spi_miso(SD_MISO), .spi_clk(spi_clk), .spi_cs(SD_CS), .spi_mosi(SD_MOSI),
        .spi_toguest(spi_toguest), .spi_fromguest(spi_fromguest),
        .spi_ss2(spi_ss2), .spi_ss3(spi_ss3), .spi_ss4(spi_ss4), .spi_srtc(),
        .conf_data0(conf_data0), .spi_req(), .spi_ack(1'b1),
        .ps2k_clk_in(PS2_KEYBOARD_CLK), .ps2k_dat_in(PS2_KEYBOARD_DAT),
        .ps2k_clk_out(ps2k_clk_out), .ps2k_dat_out(ps2k_dat_out),
        .ps2m_clk_in(PS2_MOUSE_CLK), .ps2m_dat_in(PS2_MOUSE_DAT),
        .ps2m_clk_out(ps2m_clk_out), .ps2m_dat_out(ps2m_dat_out),
        .joy1(joy1), .joy2(joy2), .joy3(8'hFF), .joy4(8'hFF),
        .buttons(32'hFFFF_FFFF), .c64_keys(64'hFFFF_FFFF_FFFF_FFFF),
        .rxd(1'b1), .txd(), .intercept(intercept)
    );
    /* verilator lint_on PINCONNECTEMPTY */
    assign SD_SCK = spi_clk;

    // Audio is silent in the skeleton.
    assign AUDIO_L  = 1'b0;
    assign AUDIO_R  = 1'b0;
    assign I2S_BCK  = 1'b0;
    assign I2S_LRCK = 1'b0;
    assign I2S_DATA = 1'b0;

    assign LED = !act_led;
endmodule
