# Project-specific assignments for the single PCAT-286 AT profile.
# Keep this organizational include even though PCAT-286.qsf is the only
# Quartus project revision in the repository.
set_global_assignment -name VERILOG_MACRO "SPK286_AT_CDC"
set_global_assignment -name VERILOG_MACRO "SPK286_P05_PARALLEL_LIMIT_CHECK"
set_global_assignment -name VERILOG_MACRO "SPK286_AT_NO_DEBUG"

# Non-Sound-Blaster audio devices carried over from the source XT profile.
# Sound Blaster remains intentionally absent from this AT build.
set_global_assignment -name VERILOG_MACRO "ENABLE_OPL2=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_CMS=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_TANDY_AUDIO=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_MIDI=1"
