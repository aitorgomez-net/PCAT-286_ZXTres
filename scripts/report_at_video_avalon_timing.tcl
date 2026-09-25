# Read-only post-fit audit. Run after compiling PCAT-286, never against an
# old netlist with candidate SDC. The output directory must be new.
# quartus_sta -t scripts/report_at_video_avalon_timing.tcl PCAT-286 OUTPUT
# Optional third argument "baseline" selects the old endpoint families.
package require ::quartus::project
package require ::quartus::sta
if {[llength $quartus(args)] < 2 || [llength $quartus(args)] > 3} {
    error "Usage: report_at_video_avalon_timing.tcl REVISION OUTPUT ?baseline?"
}
lassign $quartus(args) revision output mode
if {$mode ne "" && $mode ne "baseline"} { error "Unknown audit mode: $mode" }
if {[file exists $output]} { error "Output already exists: $output" }
file mkdir $output
project_open $revision -revision $revision
create_timing_netlist -model slow
read_sdc
update_timing_netlist
set inventory [open "$output/collections.txt" w]
proc regs {label patterns} {
    global inventory
    set c [get_registers -nowarn $patterns]
    set n [get_collection_size $c]
    puts $inventory "$label=$n"
    flush $inventory
    if {!$n} { error "Required CDC audit collection empty: $label" }
    return $c
}
set groups [list global {}]
set payload_groups {}
if {$mode eq "baseline"} {
    foreach {label src dst} {
        capture_bank0 {*ascal|o_ibuf0[*]} {*ascal|avl_i_offset0[*]}
        capture_bank1 {*ascal|o_ibuf1[*]} {*ascal|avl_i_offset1[*]}
        read_address {*ascal|o_adrs[*]} {*ascal|avl_radrs[*]}
        packed_mode {*u_video|u_ega|ega_gfx|misc_reg[*]} {*u_video|vga_packed_memory_sync1_q}
    } {
        lappend groups $label [list -from [regs ${label}_src $src] -to [regs ${label}_dst $dst]]
    }
} else {
    foreach {label src dst} {
        read_payload {*ascal|o_read_address_q[*] *ascal|o_read_base_q[*]} {*ascal|avl_radrs[*] *ascal|avl_rbase[*]}
        write_payload {*ascal|i_wadrs[*] *ascal|i_wbase[*] *ascal|i_walt} {*ascal|avl_wadrs[*] *ascal|avl_wbase[*] *ascal|avl_walt}
        read_avalon {*ascal|avl_radrs[*] *ascal|avl_rbase[*]} {*ascal|avl_address[*]}
        write_avalon {*ascal|avl_wadrs[*] *ascal|avl_wbase[*]} {*ascal|avl_address[*]}
        packed_decode {*u_video|u_ega|ega_gfx|misc_reg[*]} {*u_video|vga_packed_memory_video_q}
        packed_sync {*u_video|vga_packed_memory_sync1_q} {*u_video|vga_packed_memory_sync2_q}
        read_request_sync {*ascal|avl_read_sync} {*ascal|avl_read_sync2}
        write_request_sync {*ascal|avl_write_sync} {*ascal|avl_write_sync2}
        read_ack_sync {*ascal|o_readack_sync} {*ascal|o_readack_sync2}
        read_data_ack_sync {*ascal|o_readdataack_sync} {*ascal|o_readdataack_sync2}
        input_frame_sync {*ascal|o_iendframe0 *ascal|o_iendframe1} {*ascal|o_iendframe02 *ascal|o_iendframe12}
        output_frame_sync {*ascal|avl_o_vs_sync} {*ascal|avl_o_vs}
        frame_counter_source {*sync_v|pol* emu|at_video_vs_out_q} {*u_at_frame_counter|vs_video_q}
        frame_counter_sync {*u_at_frame_counter|vs_meta} {*u_at_frame_counter|vs_sync}
        frame_counter_logic {*u_at_frame_counter|vs_sync *u_at_frame_counter|vs_seen} {*u_at_frame_counter|frame_cnt[*]}
        shadowmask_apply {*HDMI_shadowmask*g_at_config*config_mailbox|dst_data[*]} {*HDMI_shadowmask*g_at_config*config_active_q[*]}
        shadowmask_local {*HDMI_shadowmask*g_at_config*config_active_q[*]} {*HDMI_shadowmask|*}
        video_options_apply {*u_at_video_options*config_mailbox|dst_data[*]} {*u_at_video_options|scale[*] *u_at_video_options|display[*] *u_at_video_options|arx[*] *u_at_video_options|ary[*]}
        video_options_local {*u_at_video_options|scale[*] *u_at_video_options|display[*] *u_at_video_options|arx[*] *u_at_video_options|ary[*]} {*}
        monitor_profile_local {*u_video|video_geometry_cdc|dst_data[14] *u_video|video_geometry_cdc|dst_data[15]} {*}
        scanlines_status_apply {*u_at_scanlines_status*config_mailbox|dst_data[*]} {*u_at_scanlines_status|status[*]}
        scanlines_status_readback {*u_at_scanlines_status|status[*]} {io_dout_sys[*]}
        scaler_geometry_apply {*u_at_scaler_config*geometry_config|dst_data[*]} {*u_at_scaler_config|active_q*}
        scaler_geometry_local {*u_at_scaler_config|active_q*} {*}
        scaler_aspect_phase {*u_at_video_options|arx[*] *u_at_video_options|ary[*]} {*u_at_scaler_config|aspect_video_q[*]}
        scaler_aspect_local {*u_at_scaler_config|aspect_video_q[*]} {*}
        scaler_frame_local {*u_at_scaler_config*scaler_frame_config|dst_data[*]} {*}
        scaler_frame_retime {*u_at_scaler_config|output_retime *u_at_scaler_config*scaler_frame_config|dst_update} {*ascal|*}
        scaler_input_mode {*u_at_scaler_config|input_mode[*]} {*ascal|i_mode[*]}
        scaler_aspect_readback {*u_at_scaler_config*aspect_readback|dst_data[*]} {*}
        adaptive_flags_source {*ascal|o_h_poly_adaptive *ascal|o_v_poly_adaptive} {*ascal*g_at_poly_control*poly_adaptive_config|payload_q[*]}
        adaptive_flags_apply {*ascal*g_at_poly_control*poly_adaptive_config|dst_data[*]} {*ascal|poly_adaptive_local[*]}
        adaptive_flags_commit {*ascal|o_run *ascal|o_vsv[*]} {*ascal|poly_adaptive_local[*]}
        adaptive_flags_local {*ascal|poly_adaptive_local[*]} {*}
        scaler_luminance_capture {*ascal|o_h_lum_pix* *ascal|o_v_lum_pix*} {*ascal|o_poly_lum_rg[*] *ascal|o_poly_lum_b[*]}
        scaler_luminance_reduce {*ascal|o_poly_lum_rg[*] *ascal|o_poly_lum_b[*]} {*ascal|o_poly_lum1[*]}
        scaler_luminance_weights {*ascal|o_poly_lum1[*]} {*ascal|o_poly_lerp_ta[*] *ascal|o_poly_lerp_tb[*]}
        hdmi_vsync_sync {*u_at_hdmi_vsync|vs_meta} {*u_at_hdmi_vsync|vs_sync}
        hdmi_vsync_consumers {*u_at_hdmi_vsync|vs_sync *u_at_hdmi_vsync|vs_seen} {*}
        hdmi_vsync_wait {*u_at_hdmi_vsync|vs_sync *u_at_hdmi_vsync|vs_seen} {vs_wait}
        hdmi_vsync_pll {*u_at_hdmi_vsync|vs_sync *u_at_hdmi_vsync|vs_seen} {cfg_got}
        analog_config_source {PhaseInc[*] ColorBurst_Range[*] pal_en cvbs yc_en subcarrier} {*u_at_video_output_config*config_mailbox|payload_q[*]}
        analog_config_apply {*u_at_video_output_config*config_mailbox|dst_data[*]} {*u_at_video_output_config|active_q[*]}
        analog_config_local {*u_at_video_output_config|active_q[*]} {*}
        subcarrier_accumulator {sub_accum[*]} {sub_accum[*] subcarrier_out}
        direct_video_capture {dv_data[*] dv_hs dv_vs dv_de} {*u_at_hdmi_output|direct_q1[*]}
        direct_video_pipeline {*u_at_hdmi_output|direct_q1[*]} {*u_at_hdmi_output|direct_q2[*]}
        scaled_video_capture {*hdmi_osd|* *csync_hdmi|*} {*u_at_hdmi_output|scaled_q[*]}
        tx_csync_sync {*u_at_hdmi_output|csync_meta} {*u_at_hdmi_output|csync_sync}
        tx_csync_local {*u_at_hdmi_output|csync_sync} {*u_at_hdmi_output|scaled_q[*]}
        tx_mode_control {*u_at_hdmi_output|state_q* *u_at_hdmi_output|wait_q* *u_at_hdmi_output|target_q} {*u_at_hdmi_output|select_direct *u_at_hdmi_output|switch_reset_q}
    } {
        lappend groups $label [list -from [regs ${label}_src $src] -to [regs ${label}_dst $dst]]
    }
    set payload_groups {read_payload write_payload}
    foreach {label source clock} {
        direct_video_output {*u_at_hdmi_output|direct_q2[*]} AT_HDMI_TX_DIRECT
        scaled_video_output {*u_at_hdmi_output|scaled_q[*]} AT_HDMI_TX_SCALED
    } {
        lappend groups $label [list -from [regs ${label}_source $source] \
            -to [regs ${label}_destination {*u_at_hdmi_output|tx_pixel[*]}] -to_clock [get_clocks $clock]]
    }
    foreach clock {AT_HDMI_TX_DIRECT AT_HDMI_TX_SCALED} {
        lappend groups tx_reset_${clock} [list \
            -from [regs ${clock}_reset_meta {*u_at_hdmi_output|reset_meta}] \
            -to [regs ${clock}_reset_sync {*u_at_hdmi_output|reset_sync}] \
            -from_clock [get_clocks $clock] -to_clock [get_clocks $clock]]
    }
    lappend groups tx_mode_stable [list \
        -from [regs tx_mode_source {*u_at_hdmi_output|select_direct}] \
        -to [regs tx_mode_destination {*u_at_hdmi_output|tx_pixel[*]}]]
    lappend payload_groups tx_mode_stable
    set tx_reset_release [regs tx_reset_release {*u_at_hdmi_output|reset_sync}]
    set tx_output_regs [regs tx_output_reset {*u_at_hdmi_output|tx_pixel[*]}]
    foreach {label instance} {
        capture_bank_config capture_bank_config
        capture_field_history capture_field_history
        scaler_geometry_config u_at_scaler_config*geometry_config
        scaler_frame_config u_at_scaler_config*scaler_frame_config
        scaler_aspect_config u_at_scaler_config*aspect_readback
        shadowmask_config HDMI_shadowmask*g_at_config*config_mailbox
        video_geometry_config video_geometry_cdc
        video_options_config u_at_video_options*config_mailbox
        scanlines_status_config u_at_scanlines_status*config_mailbox
        adaptive_flags_config ascal*g_at_poly_control*poly_adaptive_config
        analog_output_config u_at_video_output_config*config_mailbox
    } {
        # Selectors may contain wildcards; report filenames must work on Windows.
        set src [regs ${label}_src "*${instance}|payload_q\[*\]"]
        set dst [regs ${label}_dst "*${instance}|dst_data\[*\]"]
        lappend groups $label [list -from $src -to $dst]
        lappend payload_groups $label
        foreach {src_name dst_name} {req_meta req_sync ack_meta ack_sync} {
            set src [regs ${label}_${src_name} "*${instance}|${src_name}"]
            set dst [regs ${label}_${dst_name} "*${instance}|${dst_name}"]
            lappend groups ${label}_${src_name} [list -from $src -to $dst]
        }
    }
    set old [get_registers -nowarn {*ascal|avl_i_offset0[*] *ascal|avl_i_offset1[*] *ascal|avl_o_offset0[*] *ascal|avl_o_offset1[*]}]
    puts $inventory "legacy_async_offsets=[get_collection_size $old]"
    if {[get_collection_size $old]} { error "Old asynchronous bank offsets still present" }
    set old_profile [get_registers -nowarn {*u_video|ega_monitor_profile_video_sync1_q[*] *u_video|ega_monitor_profile_video_sync2_q[*]}]
    puts $inventory "legacy_independent_profile_bits=[get_collection_size $old_profile]"
    if {[get_collection_size $old_profile]} { error "Old independent profile synchronizers still present" }
    set old_direct [get_registers -nowarn {hdmi_dv_data[*] hdmi_dv_hs hdmi_dv_vs hdmi_dv_de}]
    puts $inventory "legacy_direct_capture=[get_collection_size $old_direct]"
    if {[get_collection_size $old_direct]} { error "Old cross-domain direct video capture still present" }
}
close $inventory
set counts [open "$output/path_counts.txt" w]
set open_timing 0
foreach condition [get_available_operating_conditions] {
    set_operating_conditions $condition
    update_timing_netlist
    set corner [string map {" " "_" "/" "_"} $condition]
    set dir "$output/$corner"
    file mkdir $dir
    report_clock_fmax_summary -file "$dir/fmax.rpt"
    report_exceptions -file "$dir/exceptions.rpt"
    report_ucp -file "$dir/unconstrained.rpt"
    check_timing -file "$dir/check_timing.rpt"
    foreach {label selectors} $groups {
        foreach kind {setup hold} {
            # Held asynchronous payloads have a setup/max-delay budget, with
            # hold excluded. Their two synchronizer stages must pass both.
            if {$kind eq "hold" && [lsearch -exact $payload_groups $label] >= 0} { continue }
            set result [eval report_timing -$kind $selectors -npaths 20 -detail full_path -file "$dir/${label}_${kind}.rpt"]
            puts $counts "$corner $label $kind $result"
            flush $counts
            if {[lindex $result 0] == 0 || [lindex $result 1] < 0} { set open_timing 1 }
        }
    }
    foreach kind {recovery removal} {
        set result [report_timing -$kind -npaths 20 -detail full_path -file "$dir/global_${kind}.rpt"]
        puts $counts "$corner global $kind $result"
        if {[lindex $result 0] && [lindex $result 1] < 0} { set open_timing 1 }
        if {$mode ne "baseline"} {
            foreach clock {AT_HDMI_TX_DIRECT AT_HDMI_TX_SCALED} {
                set result [report_timing -$kind \
                    -from $tx_reset_release -to $tx_output_regs \
                    -from_clock [get_clocks $clock] -to_clock [get_clocks $clock] \
                    -npaths 20 -detail full_path -file "$dir/tx_${clock}_${kind}.rpt"]
                puts $counts "$corner tx_${clock} $kind $result"
                if {[lindex $result 0] == 0 || [lindex $result 1] < 0} { set open_timing 1 }
            }
        }
    }
    report_min_pulse_width -nworst 20 -file "$dir/pulse_width.rpt"
}
puts $counts "timing_open=$open_timing"
close $counts
delete_timing_netlist
project_close -dont_export_assignments
post_message "CDC audit written to $output; timing_open=$open_timing (inspect reports before accepting closure)"
