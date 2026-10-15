# Vivado non-project build of the PCAT-286 ZXTRES+ target. Run from the
# build directory prepared by zxtres/scripts/build_pcat.sh, which holds
# vhdl_sources.txt, sv_sources.txt, the .mem images and the constraints.
# Arguments: PART TOP.
lassign $argv part top

proc read_list {name} {
    set fd [open $name r]
    set items [split [string trim [read $fd]] "\n"]
    close $fd
    return $items
}

read_vhdl -library work [read_list vhdl_sources.txt]
read_verilog -sv [read_list sv_sources.txt]
read_mem [glob *.mem]
read_xdc zxtres_pcat.xdc

synth_design -top $top -part $part -include_dirs [list src]
opt_design
place_design
phys_opt_design
route_design

report_timing_summary -max_paths 10 -file timing_summary.rpt
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
