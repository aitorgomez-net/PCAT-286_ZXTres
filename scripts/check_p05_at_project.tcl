# Read-only single-project check; run in an isolated copy when using Quartus.
package require ::quartus::project

set revisions $quartus(args)
if {![llength $revisions]} { set revisions {PCAT-286} }
if {[llength $revisions] != 1 || [lindex $revisions 0] ne "PCAT-286"} {
    error "Only the PCAT-286 AT project is supported: $revisions"
}

project_open PCAT-286 -revision PCAT-286

set sdc_files {}
foreach_in_collection a [get_all_global_assignments -name SDC_FILE] {
    lappend sdc_files [file tail [lindex $a 2]]
}
if {[lsearch -exact $sdc_files SYSTEM.sdc] < 0 ||
    [lsearch -exact $sdc_files PCAT-286.sdc] >= 0 ||
    [lsearch -exact $sdc_files PCAT-286_AT.sdc] >= 0 ||
    [lsearch -exact $sdc_files sys_top.sdc] < 0} {
    error "PCAT-286 selected wrong SDC set: $sdc_files"
}

set macros {}
foreach_in_collection a [get_all_global_assignments -name VERILOG_MACRO] {
    lappend macros [lindex $a 2]
}
foreach required {AT_PROFILE SPK286_P05_PARALLEL_LIMIT_CHECK SPK286_AT_NO_DEBUG} {
    if {[lsearch -exact $macros $required] < 0} {
        error "PCAT-286 missing macro: $required ($macros)"
    }
}

set output_dir [get_global_assignment -name PROJECT_OUTPUT_DIRECTORY]
if {$output_dir ne "output_files"} {
    error "PCAT-286 selected wrong output directory: $output_dir"
}

# QSF parsing does not remove Tcl-style braces from a -to token. A braced
# vector pattern silently names different pins and leaves the generic fast
# output assignment active. Require the intended literal vector names.
foreach {name targets} {
    FAST_OUTPUT_REGISTER {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*]}
    FAST_OUTPUT_ENABLE_REGISTER {SDRAM_DQ[*]}
} {
    foreach target $targets {
        set found 0
        foreach_in_collection a [get_all_instance_assignments -name $name] {
            set assigned_to [lindex $a 2]
            if {[string first "\{SDRAM_" $assigned_to] >= 0} {
                error "Literal braces in $name pin assignment: $assigned_to"
            }
            if {$assigned_to eq $target && [lindex $a 4] eq "OFF"} { set found 1 }
        }
        if {!$found} { error "Missing explicit $name OFF for $target" }
    }
}

puts "PCAT_AT_PROJECT_PASS revision=PCAT-286 sdc=$sdc_files output=$output_dir macros=$macros"
project_close -dont_export_assignments
