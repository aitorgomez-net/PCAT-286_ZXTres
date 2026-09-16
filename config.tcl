# Project-specific assignments for the single PCAT-286 AT profile.
# Keep this organizational include even though PCAT-286.qsf is the only
# Quartus project revision in the repository.
set_global_assignment -name VERILOG_MACRO "SPK286_AT_CDC"
set_global_assignment -name VERILOG_MACRO "SPK286_P05_PARALLEL_LIMIT_CHECK"
set_global_assignment -name VERILOG_MACRO "SPK286_AT_NO_DEBUG"