# Run against the fitted production workspace. OUTPUT must be new.
package require ::quartus::project
package require ::quartus::sta
if {[llength $quartus(args)] != 2} {
    error "Usage: report_code_buffer_timing.tcl REVISION OUTPUT"
}
lassign $quartus(args) revision output
if {[file exists $output]} { error "Report directory already exists: $output" }
file mkdir $output
project_open $revision -revision $revision
create_timing_netlist -model slow
read_sdc
update_timing_netlist
set buffer [get_registers -nowarn {*u_at_sdram_read_buffer|*}]
set clk50 [get_clocks {FPGA_CLK2_50}]
set count [get_collection_size $buffer]
if {$count == 0} { error "Instruction-buffer register collection is empty" }
set inventory [open "$output/collection.txt" w]
puts $inventory "code_buffer_registers=$count"
close $inventory
foreach condition [get_available_operating_conditions] {
    set_operating_conditions $condition
    update_timing_netlist
    set label [string map {" " "_" "/" "_"} $condition]
    set dir "$output/$label"
    file mkdir $dir
    foreach kind {setup hold} {
        report_timing -$kind -to $buffer -npaths 20 -detail full_path \
            -file "$dir/to_buffer_$kind.rpt"
        report_timing -$kind -from $buffer -npaths 20 -detail full_path \
            -file "$dir/from_buffer_$kind.rpt"
        report_timing -$kind -from_clock $clk50 -to $buffer -npaths 20 -detail full_path \
            -file "$dir/clk50_to_buffer_$kind.rpt"
    }
}
delete_timing_netlist
project_close
puts "CODE_BUFFER_TIMING_REPORT_PASS $output"
