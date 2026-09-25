# AT-only constraints for the single PCAT-286 project. Root clocks and common
# MiSTer constraints are loaded by sys/sys_top.sdc.
# Do not group the whole CPU and video domains as asynchronous: unchecked
# direct crossings must remain visible to TimeQuest.
derive_pll_clocks
derive_clock_uncertainty

proc at_clock {name} {
    set c [get_clocks -nowarn $name]
    if {[get_collection_size $c] != 1} { error "AT clock missing/ambiguous: $name" }
    return $c
}
proc at_regs {label patterns {required 1}} {
    set r [get_registers -nowarn $patterns]
    set n [get_collection_size $r]
    post_message "AT SDC collection $label: $n registers"
    if {$required && !$n} { error "AT SDC required collection empty: $label" }
    return $r
}
proc at_sync {label source_clock patterns {required 1}} {
    set r [at_regs $label $patterns $required]
    if {[get_collection_size $r]} {
        # Only the asynchronous arrival at the first stage is cut. The
        # first-to-second stage remains a normal single-cycle path.
        set_false_path -from $source_clock -to $r
    }
}
proc at_mailbox {label source_clock patterns budget} {
    set r [at_regs $label $patterns]
    # The source holds the complete payload until the acknowledged toggle
    # returns. This bound is shorter than one destination clock period;
    # the receiver waits at least two synchronizer stages before using it.
    set_max_delay -from $source_clock -to $r $budget
    set_false_path -hold -from $source_clock -to $r
}

# The optional observer /2 mode uses a real divide-by-two CPU clock. This is deliberately
# a generated clock rather than a multicycle exception on the complete SPK286
# hierarchy: BIU and chipset handshake paths which still require one 50 MHz
# cycle remain fully timed.
set at_no_debug 0
set at_debug_cpu_div2 0
set at_boot_splash_enabled 0
foreach_in_collection a [get_all_global_assignments -name VERILOG_MACRO] {
    if {[lindex $a 2] eq "SPK286_AT_NO_DEBUG"} { set at_no_debug 1 }
    if {[lindex $a 2] eq "SPK286_AT_DEBUG_CPU_DIV2"} { set at_debug_cpu_div2 1 }
    if {[lindex $a 2] eq "SPK286_AT_BOOT_SPLASH"} { set at_boot_splash_enabled 1 }
}
if {$at_no_debug && $at_debug_cpu_div2} {
    error "SPK286_AT_DEBUG_CPU_DIV2 requires the debug observer"
}
if {$at_debug_cpu_div2} {
    set at_debug_cpu_clock_pin [get_pins -nowarn {*|at_debug_cpu_clock_q|q}]
    if {[get_collection_size $at_debug_cpu_clock_pin] != 1} {
        error "AT debug CPU clock divider missing/ambiguous"
    }
    create_generated_clock -name AT_DEBUG_CPU_CLK -source [get_ports FPGA_CLK2_50] \
        -divide_by 2 $at_debug_cpu_clock_pin
    set AT_CPU [at_clock AT_DEBUG_CPU_CLK]
} else {
    set AT_CPU [at_clock FPGA_CLK2_50]
}

set AT_VIDEO [at_clock {emu|u_at_video_pll|pll_system_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set AT_VIDEO_X2 [at_clock {emu|u_at_video_pll|pll_system_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
set AT_VIDEO_OUT [at_clock {emu|u_at_video_pll|pll_system_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}]
set AT_HDMI [at_clock {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]

create_generated_clock -name SDRAM_CLK -source [get_ports FPGA_CLK2_50] -divide_by 1 [get_ports SDRAM_CLK]
create_clock -name VCLK_SDIO -period 20.000
set_input_delay -clock SDRAM_CLK -max 6 [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock SDRAM_CLK -min 3 [get_ports {SDRAM_DQ[*]}]
# Preserve the inherited external budget pending identification of the SDRAM
# module. Do not change phase, delay signs or target frequency to obtain PASS.
set_output_delay -clock SDRAM_CLK -max 2 [get_ports {SDRAM_DQ[*] SDRAM_DQM* SDRAM_A[*] SDRAM_n* SDRAM_BA[*] SDRAM_CKE}]
set_output_delay -clock SDRAM_CLK -min 1.5 [get_ports {SDRAM_DQ[*] SDRAM_DQM* SDRAM_A[*] SDRAM_n* SDRAM_BA[*] SDRAM_CKE}]
set_input_delay -clock VCLK_SDIO -max 10 [get_ports {SDIO_DAT[*] SDIO_CMD}]
set_input_delay -clock VCLK_SDIO -min 5 [get_ports {SDIO_DAT[*] SDIO_CMD}]
set_output_delay -clock VCLK_SDIO -max 5 [get_ports {SDIO_DAT[*] SDIO_CMD SDIO_CLK}]
set_output_delay -clock VCLK_SDIO -min 0 [get_ports {SDIO_DAT[*] SDIO_CMD SDIO_CLK}]
# The pins also carry analog video. A virtual SDIO receiver does not sample
# those video paths; FPGA internal paths are not affected by these exclusions.
foreach c [list $AT_VIDEO_OUT $AT_HDMI] {
    set_false_path -from $c -to [get_clocks VCLK_SDIO]
}

# CPU <-> EGA I/O: one outstanding request, stable payload, toggle handshake.
at_sync ega_request $AT_CPU {*u_video|video_io_req_sync1_q}
at_sync ega_ack $AT_VIDEO {*u_video|io_ack_sync1_q}
at_mailbox ega_request_payload $AT_CPU {*u_video|video_bus_address_q[*] *u_video|video_bus_data_q[*] *u_video|video_bus_ior_q *u_video|video_bus_iow_q} 10.0
at_mailbox ega_reply_payload $AT_VIDEO {*u_video|io_read_data_sync1_q[*]} 10.0
at_sync ega_memory_select $AT_CPU {*u_video|memory_select_video1_q *u_video|memory_write_video1_q}

# VRAM mode registers are held by the acknowledged EGA I/O transaction.
# The frontend samples the payload only on its synchronized cfg_toggle edge.
at_sync ega_config_toggle $AT_VIDEO {*u_video|u_vram|cfg_toggle_sync1}
at_mailbox ega_config_payload $AT_VIDEO {
    *u_video|u_vram|plane_write_mask_sync1[*] *u_video|u_vram|odd_even_mode_sync1
    *u_video|u_vram|chain2_write_sync1 *u_video|u_vram|chain2_read_sync1
    *u_video|u_vram|extended_memory_sync1 *u_video|u_vram|mem_map_sel_sync1[*]
    *u_video|u_vram|page_select_sync1 *u_video|u_vram|write_mode_sync1[*]
    *u_video|u_vram|read_mode_sync1[*] *u_video|u_vram|read_plane_sel_sync1[*]
    *u_video|u_vram|color_compare_sync1[*] *u_video|u_vram|color_dont_care_sync1[*]
    *u_video|u_vram|bit_mask_sync1[*] *u_video|u_vram|set_reset_sync1[*]
    *u_video|u_vram|enable_set_reset_sync1[*] *u_video|u_vram|rop_select_sync1[*]
    *u_video|u_vram|rotate_count_sync1[*]
} 10.0

# Optional diagnostic overlay.  Its source snapshot is frozen until the
# request/acknowledge toggle has crossed both clock domains, so the payload is
# a mailbox rather than a synchronous multi-cycle bus.  Constraining only the
# two first synchronizer stages and the held payload avoids artificial hold
# delay insertion across the wide observer without hiding any machine path.
set debug_snapshot_source [at_regs debug_snapshot_source {
    *u_at_debug_overlay|source_snapshot* *u_at_debug_overlay|source_sequence*
} 0]
set debug_snapshot_capture [at_regs debug_snapshot_capture {
    *u_at_debug_overlay|video_snapshot* *u_at_debug_overlay|video_sequence*
} 0]
set debug_snapshot_request [at_regs debug_snapshot_request {
    *u_at_debug_overlay|snapshot_request
} 0]
set debug_snapshot_request_meta [at_regs debug_snapshot_request_meta {
    *u_at_debug_overlay|snapshot_request_src1
} 0]
set debug_snapshot_ack [at_regs debug_snapshot_ack {
    *u_at_debug_overlay|snapshot_acknowledge
} 0]
set debug_snapshot_ack_meta [at_regs debug_snapshot_ack_meta {
    *u_at_debug_overlay|snapshot_ack_video1
} 0]
if {[get_collection_size $debug_snapshot_request] &&
    [get_collection_size $debug_snapshot_request_meta]} {
    set_false_path -from $debug_snapshot_request -to $debug_snapshot_request_meta
}
if {[get_collection_size $debug_snapshot_ack] &&
    [get_collection_size $debug_snapshot_ack_meta]} {
    set_false_path -from $debug_snapshot_ack -to $debug_snapshot_ack_meta
}
if {[get_collection_size $debug_snapshot_source] &&
    [get_collection_size $debug_snapshot_capture]} {
    set_max_delay -from $debug_snapshot_source \
                  -to $debug_snapshot_capture 20.0
    set_false_path -hold -from $debug_snapshot_source \
                             -to $debug_snapshot_capture
}

# The boot splash is optional at build time. When compiled in, a normal
# candidate build must still fail if its synchronizer is absent. An explicitly
# labelled reanalysis may lack this newly added stage.
set at_require_new [expr {![info exists ::env(P05_REFERENCE_FIT)] || $::env(P05_REFERENCE_FIT) ne "1"}]
at_sync splash $AT_CPU {*u_video|splash_video_sync1_q} [expr {$at_boot_splash_enabled && $at_require_new}]

# These registers asynchronously assert reset, then release on their local
# clock. Cut only the async control pin, not their synchronous D paths.
set reset_release [at_regs reset_release {
    *u_video|video_reset_sync1_q *u_video|video_reset_sync2_q
    emu|at_video_pipe_reset_57_q1 emu|at_video_pipe_reset_57_q2
    emu|at_video_pipe_reset_57_ps_q1 emu|at_video_pipe_reset_57_ps_q2
}]
set reset_pins [get_pins -nowarn -compatibility_mode {*u_video|video_reset_sync*_q|clrn *u_video|video_reset_sync*_q|prn *emu|at_video_pipe_reset*|clrn *emu|at_video_pipe_reset*|prn}]
if {[get_collection_size $reset_pins]} { set_false_path -to $reset_pins }
post_message "AT SDC reset asynchronous pins: [get_collection_size $reset_pins]"

# Common MiSTer exceptions which also apply to the AT output pipeline.
set pll_frame [get_registers -nowarn {pll_hdmi_adj:pll_hdmi_adj|ivss}]
if {[get_collection_size $pll_frame] && !$at_cdc_enabled} {
    set_false_path -from [get_registers {pll_hdmi_adj:pll_hdmi_adj|i_vss_delay}] -to $pll_frame
}
set scaler_reset [get_registers -nowarn {ascal:ascal|i_reset_na ascal:ascal|o_reset_na ascal:ascal|avl_reset_na}]
if {[get_collection_size $scaler_reset]} { set_false_path -to $scaler_reset }

# No extra retiming exception between the three related video PLL outputs.
# STA must analyze the real base/X2/+90 degree phase relationships.

if {$at_cdc_enabled && $at_require_new} {
    # The transmitter uses native video in direct mode and HDMI PLL otherwise.
    # These are two modes of the SAME clock mux, not asynchronous clock groups
    # for the rest of the design. Its final I/O data mux uses the same selector.
    set tx_pin [get_pins -nowarn -compatibility_mode {hdmi_clk_sw|outclk}]
    set tx_hdmi_pin [get_pins -nowarn -compatibility_mode {hdmi_clk_sw|inclk[2]}]
    set tx_video_pin [get_pins -nowarn -compatibility_mode {hdmi_clk_sw|inclk[3]}]
    foreach p [list $tx_pin $tx_hdmi_pin $tx_video_pin] {
        if {[get_collection_size $p] != 1} { error "AT HDMI clock mux pin missing/ambiguous" }
    }
    create_generated_clock -name AT_HDMI_TX_SCALED -source $tx_hdmi_pin \
        -master_clock $AT_HDMI -divide_by 1 $tx_pin
    create_generated_clock -name AT_HDMI_TX_DIRECT -source $tx_video_pin \
        -master_clock $AT_VIDEO_OUT -divide_by 1 -add $tx_pin
    set AT_TX_SCALED [at_clock AT_HDMI_TX_SCALED]
    set AT_TX_DIRECT [at_clock AT_HDMI_TX_DIRECT]
    set AT_TX [get_clocks {AT_HDMI_TX_SCALED AT_HDMI_TX_DIRECT}]
    set_clock_groups -logically_exclusive -group $AT_TX_SCALED -group $AT_TX_DIRECT
    set tx_regs [at_regs hdmi_tx_output {*u_at_hdmi_output|tx_pixel[*]}]
    # Only the unselected data branch is impossible in each clock mode.
    # The matching VIDEO->DIRECT and HDMI->SCALED transfers remain fully timed.
    set tx_direct_data [at_regs hdmi_tx_direct {*u_at_hdmi_output|direct_q2[*]}]
    set tx_scaled_data [at_regs hdmi_tx_scaled {*u_at_hdmi_output|scaled_q[*]}]
    set_false_path -from $tx_direct_data -to $AT_TX_SCALED
    set_false_path -from $tx_scaled_data -to $AT_TX_DIRECT
    # select_direct changes with reset asserted, >=160 ns before switching and
    # >=640 ns before release (then two TX reset-release stages). It cannot
    # change while a live output pixel is being sampled. Do not cut other SYS
    # controls or all paths into the output bank.
    set tx_select [at_regs hdmi_tx_select {*u_at_hdmi_output|select_direct}]
    set_max_delay -from $tx_select -to $tx_regs 10.0
    set_false_path -hold -from $tx_select -to $tx_regs
    set tx_reset_pins [get_pins -nowarn -compatibility_mode {
        *u_at_hdmi_output|reset_*|clrn *u_at_hdmi_output|reset_*|prn
    }]
    if {![get_collection_size $tx_reset_pins]} { error "AT HDMI reset pins missing" }
    # Only SYS assertion/release into the reset synchronizer is asynchronous.
    # reset_sync -> TX I/O reset pins retain recovery/removal analysis.
    set_false_path -to $tx_reset_pins
    at_sync hdmi_tx_csync $AT_CPU {*u_at_hdmi_output|csync_meta}
    derive_clock_uncertainty

    # Concrete instance endpoints, not domain-wide exemptions. 5 ns is less
    # than one 148.5 MHz destination period. Capture waits for two toggle
    # stages; the payload remains frozen until the acknowledgement returns.
    proc at_snapshot {instance {budget 5.0}} {
        set src [at_regs "${instance}_payload" "*${instance}|payload_q\[*\]"]
        set dst [at_regs "${instance}_capture" "*${instance}|dst_data\[*\]"]
        set req [at_regs "${instance}_req" "*${instance}|req_q"]
        set ack [at_regs "${instance}_ack" "*${instance}|ack_q"]
        set req_meta [at_regs "${instance}_req_meta" "*${instance}|req_meta"]
        set ack_meta [at_regs "${instance}_ack_meta" "*${instance}|ack_meta"]
        set_false_path -from $req -to $req_meta
        set_false_path -from $ack -to $ack_meta
        set_max_delay -from $src -to $dst $budget
        set_false_path -hold -from $src -to $dst
    }
    foreach instance {
        video_stats time_stats
        vga_osd*config_mailbox hdmi_osd*config_mailbox
        input_geometry output_geometry
    } {
        at_snapshot $instance
    }
    # Geometry plus the applied EGA monitor profile form a 16-bit held bus.
    # Its destination is 28.636 MHz; 10 ns leaves ample settling time.
    at_snapshot video_geometry_cdc 10.0
    at_snapshot at_crt350_config_cdc 10.0
    # Completed HPS display/scale/aspect fields apply locally in vertical blank.
    at_snapshot u_at_video_options*config_mailbox 10.0
    # Applied scanline intensity returns as a coherent pair for HPS readback.
    at_snapshot u_at_scanlines_status*config_mailbox 10.0
    # Complete UIO geometry is held through calculation, then frame-committed
    # in HDMI. Framebuffer base/format travel in that same output packet.
    at_snapshot u_at_scaler_config*geometry_config 10.0
    at_snapshot u_at_scaler_config*scaler_frame_config 5.0
    at_snapshot u_at_scaler_config*aspect_readback 10.0
    at_snapshot capture_bank_config 10.0
    at_snapshot capture_field_history 5.0
    # Completed UIO configuration is held until ack, then applied at HDMI VS.
    at_snapshot HDMI_shadowmask*g_at_config*config_mailbox 5.0
    # Adaptive H/V flags are published after the coefficient write pipeline
    # drains; the receiver applies the held pair at vertical blank.
    at_snapshot ascal*g_at_poly_control*poly_adaptive_config 5.0
    # Phase increment, colour burst and output controls are held together;
    # the complete UIO command is applied in the native video domain at VS.
    at_snapshot u_at_video_output_config*config_mailbox 10.0
    # Source-registered VS level; only the second stage drives edge detection.
    at_sync frame_counter_vs $AT_VIDEO_OUT {*u_at_frame_counter|vs_meta}
    # Registered HDMI output VS -> continuously running sys receiver. Only
    # stage one is asynchronous; edge detection and all consumers remain timed.
    at_sync hdmi_vsync $AT_TX {*u_at_hdmi_vsync|vs_meta}

    # Packed/planar selection is registered in the video domain before its
    # two-stage level synchronizer. Only the asynchronous first stage is cut.
    at_sync vga_packed_mode $AT_VIDEO {*u_video|vga_packed_memory_sync1_q}

    set AT_AVALON [at_clock {sysmem|fpga_interfaces|clocks_resets|h2f_user0_clk}]
    # No functional logic observes these first stages. Pulse/edge detection
    # in the AT scaler uses stage two and a separate remembered value.
    at_sync scaler_write_request $AT_VIDEO_OUT {*ascal|avl_write_sync}
    at_sync scaler_read_request $AT_HDMI {*ascal|avl_read_sync}
    at_sync scaler_read_ack $AT_AVALON {*ascal|o_readack_sync}
    at_sync scaler_read_data_ack $AT_AVALON {*ascal|o_readdataack_sync}
    at_sync scaler_input_frame $AT_VIDEO_OUT {*ascal|o_iendframe0 *ascal|o_iendframe1}
    at_sync scaler_output_frame $AT_HDMI {*ascal|avl_o_vs_sync}

    # Bundled command data, not a bank of independently synchronized bits.
    # Read address+base remain frozen until the Avalon acceptance ack returns.
    # Writes are held for >=6 input clocks (104 ns at 57.272 MHz); the 100 MHz
    # receiver captures after two stages, edge detection and one capture clock
    # (<50 ns). Use a 10 ns max-delay budget; Quartus 17 also accounts for
    # clock-network latencies. Audit actual data delay against the settling
    # window after fitting. Hold has no inter-clock phase requirement here.
    foreach {label src_patterns dst_patterns} {
        scaler_read_command
        {*ascal|o_read_address_q[*] *ascal|o_read_base_q[*]}
        {*ascal|avl_radrs[*] *ascal|avl_rbase[*]}
        scaler_write_command
        {*ascal|i_wadrs[*] *ascal|i_wbase[*] *ascal|i_walt}
        {*ascal|avl_wadrs[*] *ascal|avl_wbase[*] *ascal|avl_walt}
    } {
        set src [at_regs ${label}_source $src_patterns]
        set dst [at_regs ${label}_capture $dst_patterns]
        set_max_delay -from $src -to $dst 10.0
        set_false_path -hold -from $src -to $dst
    }
    at_sync metrics_video_edges $AT_VIDEO_OUT {*video_calc*g_at_edges*vs_meta *video_calc*g_at_edges*hs_meta *video_calc*g_at_edges*de_meta}
    at_sync metrics_hdmi_edge $AT_TX {*video_calc*g_at_edges*hdmi_meta}
    at_sync pll_cfg_video $AT_CPU {*pll_hdmi_adj|cfg_video_meta}
    at_sync pll_cfg_mgmt $AT_CPU {*pll_hdmi_adj|cfg_mgmt_meta *pll_hdmi_adj|llena_meta}
    at_sync pll_input_window $AT_VIDEO_OUT {*pll_hdmi_adj|ivss_meta}
    at_sync pll_output_window $AT_HDMI {*pll_hdmi_adj|ovss_meta}
    set cdc_reset_pins [get_pins -nowarn -compatibility_mode {
        *pll_hdmi_adj|video_reset_*|clrn *pll_hdmi_adj|video_reset_*|prn
        *pll_hdmi_adj|mgmt_reset_*|clrn *pll_hdmi_adj|mgmt_reset_*|prn
    }]
    if {[get_collection_size $cdc_reset_pins]} { set_false_path -to $cdc_reset_pins }
}
