# Specify root clocks
create_clock -period "50.0 MHz"  [get_ports FPGA_CLK1_50]
create_clock -period "50.0 MHz"  [get_ports FPGA_CLK2_50]
create_clock -period "50.0 MHz"  [get_ports FPGA_CLK3_50]
create_clock -period "100.0 MHz" [get_pins -compatibility_mode *|h2f_user0_clk] 
create_clock -period "100.0 MHz" [get_pins -compatibility_mode spi|sclk_out] -name spi_sck
create_clock -period "10.0 MHz"  [get_pins -compatibility_mode hdmi_i2c|out_clk] -name hdmi_sck

derive_pll_clocks
derive_clock_uncertainty

# Decouple different clock groups (to simplify routing)
# In the opt-in AT CDC experiment, remove clock-group exclusions between
# the participating control domains. Keep all unrelated legacy exclusions.
# The f2sdram exception below applies in both profiles because it is
# limited to paths that pass through the HPS hard block.
set at_cdc_enabled 0
foreach_in_collection a [get_all_global_assignments -name VERILOG_MACRO] {
   if {[lindex $a 2] eq "SPK286_AT_CDC"} { set at_cdc_enabled 1 }
}
if {!$at_cdc_enabled} {
set_clock_groups -exclusive \
   -group [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}] \
   -group [get_clocks { pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks { pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks { spi_sck}] \
   -group [get_clocks { hdmi_sck}] \
   -group [get_clocks { *|h2f_user0_clk}] \
   -group [get_clocks { FPGA_CLK1_50 }] \
   -group [get_clocks { FPGA_CLK2_50 }] \
   -group [get_clocks { FPGA_CLK3_50 }]
} else {
set at_groups [list set_clock_groups -exclusive]
foreach names {
   {*|pll|pll_inst|altera_pll_i|*[*].*|divclk}
   {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}
   {spi_sck} {hdmi_sck} {FPGA_CLK3_50}
   {FPGA_CLK1_50 FPGA_CLK2_50 *|h2f_user0_clk pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}
} {
   set clocks [get_clocks -nowarn $names]
   if {[get_collection_size $clocks]} { lappend at_groups -group $clocks }
}
eval $at_groups
}

# The Cyclone V f2sdram timing model can attribute an output of one DDR
# port to the clock of another. The video and audio DDR ports have separate
# clocks, so timing/hold repair across this hard-block boundary is invalid.
# Keep direct FPGA logic crossings between these clocks visible to TimeQuest.
set video_ddr_clock [get_clocks -nowarn {*u_at_video_pll*general[1]*divclk}]
set audio_ddr_clock [get_clocks -nowarn {pll_audio*general[0]*divclk}]
set hps_user_clock [get_clocks -nowarn {*h2f_user0_clk}]
set hps_ddr_pins [get_pins -compatibility_mode -nowarn {*|f2sdram|*}]
if {[get_collection_size $video_ddr_clock] != 1 ||
    [get_collection_size $audio_ddr_clock] != 1 ||
    [get_collection_size $hps_user_clock] != 1 ||
    [get_collection_size $hps_ddr_pins] == 0} {
   error "Expected HPS/video/audio DDR clocks and f2sdram pins were not found"
}
set_false_path -from $video_ddr_clock -through $hps_ddr_pins -to $audio_ddr_clock
set_false_path -from $audio_ddr_clock -through $hps_ddr_pins -to $video_ddr_clock
set_false_path -from $hps_user_clock -through $hps_ddr_pins -to $video_ddr_clock
set_false_path -from $video_ddr_clock -through $hps_ddr_pins -to $hps_user_clock
set_false_path -from $hps_user_clock -through $hps_ddr_pins -to $audio_ddr_clock
set_false_path -from $audio_ddr_clock -through $hps_ddr_pins -to $hps_user_clock

# sysmem reset is synchronized independently in each DDR port clock domain.
# The input of each first stage may change asynchronously; later stages stay timed.
foreach reset_port {ram1 ram2 vbuf} {
   set reset_meta [get_registers -nowarn "*|${reset_port}_reset_0"]
   if {[get_collection_size $reset_meta] != 1} {
      error "Expected ${reset_port} DDR reset synchronizer was not found"
   }
   set_false_path -to $reset_meta
}

# The OSD mode switch is sampled by a two-stage register chain in the EGA
# raster domain. Only the first stage may receive the asynchronous transition.
set vga_mode13_meta [get_registers -nowarn {*vga_mode13_native_video_sync1_q}]
if {[get_collection_size $vga_mode13_meta] != 1} {
   error "Expected EGA mode-13 clock-domain synchronizer was not found"
}
set_false_path -to $vga_mode13_meta

set_false_path -from [get_ports {KEY*}]
set_false_path -from [get_ports {BTN_*}]
set_false_path -to   [get_ports {LED_*}]
set_false_path -to   [get_ports {VGA_*}]
set_false_path -from [get_ports {VGA_EN}]
set_false_path -to   [get_ports {AUDIO_SPDIF}]
set_false_path -to   [get_ports {AUDIO_L}]
set_false_path -to   [get_ports {AUDIO_R}]
set_false_path -from {get_ports {SW[*]}}
set_false_path -to   {cfg[*]}
set_false_path -from {cfg[*]}
set_false_path -from {VSET[*]}
set_false_path -to   {wcalc[*] hcalc[*]}
set_false_path -to   {hdmi_width[*] hdmi_height[*]}
set_false_path -to   {deb_* btn_en btn_up}

if {!$at_cdc_enabled} {
set_multicycle_path -to {*_osd|osd_vcnt*} -setup 2
set_multicycle_path -to {*_osd|osd_vcnt*} -hold 1

set_false_path -to   {*_osd|v_cnt*}
set_false_path -to   {*_osd|v_osd_start*}
set_false_path -to   {*_osd|v_info_start*}
set_false_path -to   {*_osd|h_osd_start*}
set_false_path -from {*_osd|v_osd_start*}
set_false_path -from {*_osd|v_info_start*}
set_false_path -from {*_osd|h_osd_start*}
set_false_path -from {*_osd|rot*}
set_false_path -from {*_osd|dsp_width*}
set_false_path -to   {*_osd|half}
}

set_false_path -to   {WIDTH[*] HFP[*] HS[*] HBP[*] HEIGHT[*] VFP[*] VS[*] VBP[*]}
set_false_path -from {WIDTH[*] HFP[*] HS[*] HBP[*] HEIGHT[*] VFP[*] VS[*] VBP[*]}
set_false_path -to   {FB_BASE[*] FB_BASE[*] FB_WIDTH[*] FB_HEIGHT[*] LFB_HMIN[*] LFB_HMAX[*] LFB_VMIN[*] LFB_VMAX[*]}
set_false_path -from {FB_BASE[*] FB_BASE[*] FB_WIDTH[*] FB_HEIGHT[*] LFB_HMIN[*] LFB_HMAX[*] LFB_VMIN[*] LFB_VMAX[*]}
set_false_path -to   {vol_att[*] scaler_flt[*] led_overtake[*] led_state[*]}
set_false_path -from {vol_att[*] scaler_flt[*] led_overtake[*] led_state[*]}
set_false_path -from {aflt_* acx* acy* areset* arc*}
set_false_path -from {arx* ary*}
set_false_path -from {vs_line*}
if {!$at_cdc_enabled} {
set_false_path -from {ColorBurst_Range* PhaseInc* pal_en cvbs yc_en}
}

if {!$at_cdc_enabled} {
set_false_path -from {ascal|o_ihsize*}
set_false_path -from {ascal|o_ivsize*}
set_false_path -from {ascal|o_format*}
set_false_path -from {ascal|o_hdown}
set_false_path -from {ascal|o_vdown}
}
set_false_path -from {ascal|o_hmin* ascal|o_hmax* ascal|o_vmin* ascal|o_vmax* ascal|o_vrrmax* ascal|o_vrr}
set_false_path -from {ascal|o_hdisp* ascal|o_vdisp*}
set_false_path -from {ascal|o_htotal* ascal|o_vtotal*}
set_false_path -from {ascal|o_hsstart* ascal|o_vsstart* ascal|o_hsend* ascal|o_vsend*}
if {!$at_cdc_enabled} {
set_false_path -from {ascal|o_hsize* ascal|o_vsize*}
}

set_false_path -from {mcp23009|flg_*}
set_false_path -to   {sysmem|fpga_interfaces|clocks_resets|f2h*}
