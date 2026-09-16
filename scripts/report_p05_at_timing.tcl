# Run with quartus_sta -t scripts/report_p05_at_timing.tcl REVISION OUTPUT.
# OUTPUT must be new; reports never overwrite a previous corner/candidate.
package require ::quartus::project
package require ::quartus::sta

if {[llength $quartus(args)] != 2} {
    error "Usage: report_p05_at_timing.tcl REVISION OUTPUT"
}
lassign $quartus(args) revision output
if {[file exists $output]} { error "Report directory already exists: $output" }
file mkdir $output
project_open $revision -revision $revision
create_timing_netlist -model slow
read_sdc
update_timing_netlist

set inventory [open "$output/collections.txt" w]
proc require_collection {label collection} {
    global inventory
    set count [get_collection_size $collection]
    puts $inventory "$label=$count"
    flush $inventory
    if {$count == 0} { error "P05 required collection empty: $label" }
    return $collection
}
set cpu [require_collection cpu [get_registers -nowarn {*u_at_machine|u_cpu|*}]]
set bridge [require_collection bridge [get_registers -nowarn {*u_at_machine|u_bridge|*}]]
set port [require_collection memory_port [get_registers -nowarn {*u_at_memory_port|*}]]
set owner [require_collection sdram_owner [get_registers -nowarn {*u_at_sdram_owner|*}]]
set no_debug 0
foreach_in_collection a [get_all_global_assignments -name VERILOG_MACRO] {
    if {[lindex $a 2] eq "SPK286_AT_NO_DEBUG"} { set no_debug 1 }
}
set debug [get_registers -nowarn {*u_at_debug_overlay|*source_snapshot*}]
set observers [get_registers -nowarn {
    *u_at_debug_overlay|* *u_at_boot_trace|* *u_at_ram_trace|* *u_at_fault_trace|*
}]
puts $inventory "no_debug=$no_debug observers=[get_collection_size $observers]"
if {$no_debug} {
    if {[get_collection_size $observers]} {
        error "AT production fit still contains debug observers"
    }
} else {
    require_collection debug $debug
}
set video [require_collection video [get_registers -nowarn {*u_video|*}]]
set video_out [require_collection video_out [get_clocks {emu|u_at_video_pll|pll_system_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}]]
set hdmi [require_collection hdmi [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]]
set clk50 [require_collection clk50 [get_clocks FPGA_CLK2_50]]
set sdram [require_collection sdram_clock [get_clocks SDRAM_CLK]]
set dq [require_collection dq [get_ports {SDRAM_DQ[*]}]]
set dramout [require_collection sdram_outputs [get_ports {SDRAM_DQ[*] SDRAM_A[*] SDRAM_DQM* SDRAM_n* SDRAM_BA[*] SDRAM_CKE}]]
foreach_in_collection clock [get_clocks *] {
    puts $inventory "clock=[get_clock_info -name $clock] period=[get_clock_info -period $clock]"
}
close $inventory

# Use the device's supported speed/voltage/temperature models, not just slow.
set conditions [get_available_operating_conditions]
set counts [open "$output/path_counts.txt" w]
foreach condition $conditions {
    set_operating_conditions $condition
    update_timing_netlist
    set label [string map {" " "_" "/" "_"} $condition]
    set dir "$output/$label"
    file mkdir $dir
    report_clocks -file "$dir/clocks.rpt"
    report_clock_fmax_summary -file "$dir/fmax.rpt"
    report_ucp -file "$dir/unconstrained.rpt"
    report_exceptions -file "$dir/exceptions.rpt"
    check_timing -file "$dir/check_timing.rpt"
    set path_groups [list \
            global {} \
            cpu [list -from $cpu -to $cpu] \
            cpu_bridge [list -from $cpu -to $bridge] \
            bridge_cpu [list -from $bridge -to $cpu] \
            memory_port [list -to $port] \
            owner [list -to $owner] \
            video [list -to $video] \
            video_out [list -to_clock $video_out] \
            hdmi [list -to_clock $hdmi] \
            clk50 [list -from_clock $clk50 -to_clock $clk50] \
            sdram_input [list -from $dq] \
            sdram_output [list -to $dramout]]
    if {!$no_debug} { lappend path_groups debug [list -to $debug] }
    foreach kind {setup hold} {
        foreach {name selectors} $path_groups {
            set result [eval report_timing -$kind $selectors \
                -npaths 20 -detail full_path -file "$dir/${name}_${kind}.rpt"]
            puts $counts "$label $name $kind $result"
            flush $counts
        }
    }
    foreach kind {recovery removal} {
        report_timing -$kind -npaths 20 -detail full_path -file "$dir/global_${kind}.rpt"
    }
    report_min_pulse_width -nworst 20 -file "$dir/pulse_width.rpt"
}
close $counts
delete_timing_netlist
project_close -dont_export_assignments
