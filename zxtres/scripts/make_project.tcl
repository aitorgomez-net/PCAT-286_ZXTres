# Create a Vivado project for PCAT-286 on the ZXTRES+/ZXTRES++, from the
# build directory prepared by zxtres/scripts/build_pcat.sh in project mode.
# Arguments: PART TOP [DEFINE...]. The sources are the repository's own files
# (edit them in place); the generated lists, the memory images and the
# constraints come from this directory. The run options follow build_pcat.tcl.
lassign $argv part top
cd [file dirname [file normalize [info script]]]
set here [pwd]
set root [file normalize [file join $here .. .. ..]]

proc read_list {name} {
    set fd [open $name r]
    set items [split [string trim [read $fd]] "\n"]
    close $fd
    return $items
}
# A "src/<path>" entry names the repository file <path>; the one-line
# default_nettype helper exists only in the build directory.
proc resolve {entry} {
    global root here
    set path [string range $entry 4 end]
    if {$path eq "zxtres_nettype_wire.sv"} { return [file join $here $entry] }
    return [file normalize [file join $root $path]]
}

create_project -force pcat286_zxtres project -part $part
# Keep the order of the lists: a file that ends with `default_nettype none is
# followed by the helper that restores it, as in the batch build, so the
# compile order must not be rearranged by hierarchy.
set_property source_mgmt_mode DisplayOnly [current_project]
set vhdl {}
foreach f [read_list vhdl_sources.txt] { lappend vhdl [resolve $f] }
set sv {}
foreach f [read_list sv_sources.txt] { lappend sv [resolve $f] }
add_files -norecurse $vhdl
set_property library work [get_files $vhdl]
add_files -norecurse $sv
set_property file_type SystemVerilog [get_files $sv]
set mems [concat [glob -nocomplain *.mem] [glob -nocomplain *.hex]]
add_files -norecurse [lmap m $mems {file join $here $m}]
add_files -fileset constrs_1 -norecurse [file join $here zxtres_pcat.xdc]

set dirs {}
foreach d [read_list include_dirs.txt] { lappend dirs [resolve $d] }
set_property include_dirs $dirs [current_fileset]
set defines {}
foreach define [lrange $argv 2 end] { lappend defines [string map {: =} $define] }
set_property verilog_define $defines [current_fileset]
set_property top $top [current_fileset]

# The same directives as the batch build.
set impl [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraTimingOpt $impl
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true $impl
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore $impl
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AggressiveExplore $impl
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true $impl
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore $impl
close_project
puts "project: [file join $here project pcat286_zxtres.xpr]"
