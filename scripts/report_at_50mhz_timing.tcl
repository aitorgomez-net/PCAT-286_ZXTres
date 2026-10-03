# Read the preserved fitted netlist without mapping/fitting. The wrapper may
# explicitly supply a frozen SYSTEM.sdc overlay for a constraint-only A/B run.
# quartus_sta -t report_at_50mhz_timing.tcl PCAT-286 NEW_OUTPUT
package require ::quartus::project
package require ::quartus::sta
if {[llength $quartus(args)] != 2} { error "Usage: REVISION NEW_OUTPUT" }
lassign $quartus(args) revision output
if {[file exists $output]} { error "Output already exists: $output" }
file mkdir $output
project_open $revision -revision $revision
create_timing_netlist -model slow
read_sdc
update_timing_netlist
set inventory [open "$output/collections.txt" w]
proc require_regs {label pattern} {
    global inventory
    set c [get_registers -nowarn $pattern]
    puts $inventory "$label=[get_collection_size $c]"
    flush $inventory
    if {![get_collection_size $c]} { error "Empty fitted collection: $label" }
    return $c
}
set cpu [require_regs cpu {*u_at_machine|u_cpu|*}]
set bridge [require_regs bridge {*u_at_machine|u_bridge|*}]
set port [require_regs port {*u_at_memory_port|*}]
set code [require_regs code_buffer {*u_at_sdram_read_buffer|*}]
set data [require_regs data_buffer {*u_at_ram_read_buffer|*}]
set owner [require_regs sdram_owner {*u_at_sdram_owner|*}]
set keyboard [require_regs keyboard {*u_at_keyboard|*}]
set video [require_regs video {*u_video|*}]
set prebios1 [require_regs prebios_stage1 {*u_video|prebios_video_sync1_q}]
set prebios2 [require_regs prebios_stage2 {*u_video|prebios_video_sync2_q}]
set observers [get_registers -nowarn {*u_at_debug_overlay|* *at_debug_cpu_clock_q*}]
puts $inventory "fixed_cpu_profile=1 observers=[get_collection_size $observers]"
if {[get_collection_size $observers]} { error "Retired observer/divider in production fit" }
set clk50 [get_clocks FPGA_CLK2_50]
set sdram_clk [get_clocks SDRAM_CLK]
if {[get_collection_size $clk50] != 1 || [get_collection_size $sdram_clk] != 1} {
    error "Missing/ambiguous 50 MHz or SDRAM clock"
}
foreach_in_collection a [get_all_global_assignments -name VERILOG_MACRO] {
    puts $inventory "macro=[lindex $a 2]"
}
foreach_in_collection c [get_clocks *] {
    puts $inventory "clock=[get_clock_info -name $c] period=[get_clock_info -period $c]"
}
close $inventory
set groups [list \
    global {} \
    clk50_internal [list -from_clock $clk50 -to_clock $clk50] \
    clk50_incoming [list -to_clock $clk50] \
    cpu [list -from $cpu -to $cpu] \
    cpu_bridge [list -from $cpu -to $bridge] \
    bridge_cpu [list -from $bridge -to $cpu] \
    memory_port [list -to $port] \
    code_buffer [list -to $code] \
    data_buffer [list -to $data] \
    data_buffer_outputs [list -from $data] \
    sdram_owner [list -to $owner] \
    sdram_owner_internal [list -from $owner -to $owner] \
    keyboard [list -from $keyboard -to $keyboard] \
    prebios_stage2 [list -from $prebios1 -to $prebios2] \
    video [list -to $video] \
    sdram_input [list -from [get_ports {SDRAM_DQ[*]}]] \
    sdram_output [list -to [get_ports {SDRAM_DQ[*] SDRAM_DQM* SDRAM_A[*] SDRAM_n* SDRAM_BA[*] SDRAM_CKE}]]]
set counts [open "$output/path_counts.txt" w]
foreach condition [get_available_operating_conditions] {
    set_operating_conditions $condition
    update_timing_netlist
    set corner [string map {" " "_" "/" "_"} $condition]
    set dir "$output/$corner"
    file mkdir $dir
    report_clocks -file "$dir/clocks.rpt"
    report_clock_fmax_summary -file "$dir/fmax.rpt"
    report_exceptions -file "$dir/exceptions.rpt"
    report_ucp -file "$dir/unconstrained.rpt"
    check_timing -file "$dir/check_timing.rpt"
    foreach kind {setup hold} {
        foreach {label selectors} $groups {
            set paths 20
            if {$kind eq "setup" && ($label eq "cpu" || $label eq "clk50_internal")} { set paths 80 }
            set result [eval report_timing -$kind $selectors -npaths $paths \
                -detail full_path -file "$dir/${label}_${kind}.rpt"]
            puts $counts "$corner $label $kind $result"
            flush $counts
        }
    }
    foreach kind {recovery removal} {
        set result [report_timing -$kind -npaths 20 -detail full_path -file "$dir/global_${kind}.rpt"]
        puts $counts "$corner global $kind $result"
    }
}
close $counts
delete_timing_netlist
project_close -dont_export_assignments
puts "AT_50MHZ_FITTED_AUDIT_EXTRACTED: $output (report extraction, not closure)"
