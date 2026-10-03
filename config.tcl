# Project-specific assignments for the single PCAT-286 AT profile.
# Keep this organizational include even though PCAT-286.qsf is the only
# Quartus project revision in the repository.
# CPU and memory optimizations are the single RTL implementation. CPU,
# bridge and SDRAM service use the common 50 MHz clock, without an observer.
# Keep this assignment to build the boot splash and expose its OSD toggle.
# Remove or comment it out to omit the splash and its OSD option entirely.
# set_global_assignment -name VERILOG_MACRO "SPK286_AT_BOOT_SPLASH"
# Sound Blaster Pro uses DMA channel 1 (8-bit), selectable IRQ 5/7, and shares
# the 220h I/O block with C/MS. The OSD keeps those two cards exclusive.
set_global_assignment -name VERILOG_MACRO "ENABLE_SB=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_OPL2=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_CMS=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_TANDY_AUDIO=1"
set_global_assignment -name VERILOG_MACRO "ENABLE_MIDI=1"
