# Vivado non-project build of the PCAT-286 ZXTRES+ target. Run from the
# build directory prepared by zxtres/scripts/build_pcat.sh, which holds
# vhdl_sources.txt, sv_sources.txt, include_dirs.txt, the .mem images and
# the constraints. Arguments: PART TOP [DEFINE...].
lassign $argv part top
# Resolve $readmemh inputs from this build directory, regardless of the caller's
# working directory, and fail before synthesis if the OSD font was not staged.
cd [file dirname [file normalize [info script]]]
if {![file isfile osd_font.mem]} { error "missing OSD font: [file join [pwd] osd_font.mem]" }
# Optional extra arguments: Verilog defines (e.g. ZXTRES_SKELETON).
set defines {}
foreach define [lrange $argv 2 end] { lappend defines -verilog_define $define }

proc read_list {name} {
    set fd [open $name r]
    set items [split [string trim [read $fd]] "\n"]
    close $fd
    return $items
}

read_vhdl -library work [read_list vhdl_sources.txt]
read_verilog -sv [read_list sv_sources.txt]
set mems [glob -nocomplain *.mem]
if {[llength $mems]} { read_mem $mems }
read_xdc zxtres_pcat.xdc

synth_design -top $top -part $part -include_dirs [read_list include_dirs.txt] {*}$defines
opt_design
place_design -directive ExtraTimingOpt
phys_opt_design -directive AggressiveExplore
route_design -directive AggressiveExplore
phys_opt_design -directive AggressiveExplore
write_checkpoint -force post_route.dcp

report_timing_summary -max_paths 10 -file timing_summary.rpt
report_timing -max_paths 200 -nworst 1 -unique_pins -slack_lesser_than 0 -file failing_paths.rpt
report_utilization -file utilization.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file utilization_hier.rpt
report_clock_utilization -file clocks.rpt
report_drc -file drc.rpt
report_cdc -file cdc.rpt

set fd [open result.txt w]
puts $fd "part $part"
puts $fd "top $top"
puts $fd "wns [get_property SLACK [get_timing_paths -setup -max_paths 1]]"
puts $fd "whs [get_property SLACK [get_timing_paths -hold -max_paths 1]]"
close $fd

write_bitstream -force zxtres_pcat.bit
