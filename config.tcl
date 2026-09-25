# Project-specific assignments for the single PCAT-286 AT profile.
# Keep this organizational include even though PCAT-286.qsf is the only
# Quartus project revision in the repository.
set_global_assignment -name VERILOG_MACRO "SPK286_AT_CDC"
set_global_assignment -name VERILOG_MACRO "SPK286_P05_PARALLEL_LIMIT_CHECK"
# Functional access optimizations shared with the simulation profile.
set_global_assignment -name VERILOG_MACRO "SPK286_P01_FAST_MEMORY_START"
set_global_assignment -name VERILOG_MACRO "SPK286_P02_FETCH_CHAIN"
set_global_assignment -name VERILOG_MACRO "SPK286_P06_EARLY_MEMORY_ADDRESS"
# Keep this assignment to build the boot splash and expose its OSD toggle.
# Remove or comment it out to omit the splash and its OSD option entirely.
# set_global_assignment -name VERILOG_MACRO "SPK286_AT_BOOT_SPLASH"
# The release build remains observer-free. Comment NO_DEBUG to build the
# compact single-page hardware observer used for fault diagnosis.
set_global_assignment -name VERILOG_MACRO "SPK286_AT_NO_DEBUG"
# With NO_DEBUG commented, this optional diagnostic mode runs only SPK286 at
# 25 MHz. Leave it disabled for the normal 50 MHz observer build.
# set_global_assignment -name VERILOG_MACRO "SPK286_AT_DEBUG_CPU_DIV2"

# Sound Blaster Pro uses DMA channel 1 (8-bit), selectable IRQ 5/7, and shares
# the 220h I/O block with C/MS. The OSD keeps those two cards exclusive.
set_global_assignment -name VERILOG_MACRO "ENABLE_SB=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_OPL2=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_CMS=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_TANDY_AUDIO=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_MIDI=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_EMS=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_UMB=1"
