# Read a completed fitted project; do not change or export assignments.
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

set registers [get_registers *]
set locations [open "$output/register-locations.tsv" w]
puts $locations "location\tname"
foreach_in_collection r $registers {
    puts $locations "[get_node_info -location $r]\t[get_register_info -name $r]"
}
close $locations

set src [get_registers -nowarn {*video_stats|payload_q[*]}]
set dst [get_registers -nowarn {*video_stats|dst_data[*]}]
if {[get_collection_size $src] != 163 || [get_collection_size $dst] != 163} {
    error "Missing, duplicated or changed video-statistics banks"
}
set other_src [remove_from_collection [get_keepers *] $src]
set other_dst [remove_from_collection [get_keepers *] $dst]
set inventory [open "$output/collections.txt" w]
puts $inventory "registers=[get_collection_size $registers]"
puts $inventory "video_stats_payload=[get_collection_size $src]"
puts $inventory "video_stats_capture=[get_collection_size $dst]"
close $inventory

set counts [open "$output/path-counts.txt" w]
foreach condition [get_available_operating_conditions] {
    set_operating_conditions $condition
    update_timing_netlist
    set corner [string map {" " "_" "/" "_"} $condition]
    # The complete global minimum remains unfiltered. The other two groups
    # partition the paths outside the payload-to-capture bank for diagnosis;
    # they never replace the complete-design timing acceptance gate.
    foreach {label selectors paths} [list \
        global {} 200 \
        payload [list -from $src -to $dst] 200 \
        non_payload_source [list -from $other_src] 40 \
        payload_other_destination [list -from $src -to $other_dst] 40] {
        set result [eval report_timing -setup $selectors -npaths $paths \
            -detail full_path -file "$output/${corner}_${label}_setup.rpt"]
        puts $counts "$corner $label setup $result"
        flush $counts
    }
}
close $counts
delete_timing_netlist
project_close -dont_export_assignments
puts "AT_VIDEO_REGISTER_PLACEMENT_EXTRACTED: $output (diagnosis, not closure)"
