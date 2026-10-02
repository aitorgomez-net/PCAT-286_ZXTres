# Read an existing fitted candidate and audit every explicitly bounded net.
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
set src [get_registers -nowarn {*video_stats|payload_q[*]}]
set dst [get_registers -nowarn {*video_stats|dst_data[*]}]
if {![get_collection_size $src] || ![get_collection_size $dst]} {
    error "Video-statistics payload/capture endpoints are missing"
}
set receipt [open "$output/collections.txt" w]
puts $receipt "video_stats_payload=[get_collection_size $src]"
puts $receipt "video_stats_capture=[get_collection_size $dst]"
close $receipt
foreach condition [get_available_operating_conditions] {
    set_operating_conditions $condition
    update_timing_netlist
    set corner [string map {" " "_" "/" "_"} $condition]
    # No top-N limit: retain every edge of the bounded payload collection.
    report_net_delay -file "$output/${corner}_net_delay.rpt"
    report_timing -setup -from $src -to $dst -npaths 200 -detail full_path \
        -file "$output/${corner}_payload_setup.rpt"
}
delete_timing_netlist
project_close -dont_export_assignments
puts "AT_NET_DELAY_AUDIT_EXTRACTED"
