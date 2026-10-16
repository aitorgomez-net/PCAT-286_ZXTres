# KFPC-XT components

PCAT-286 keeps these blocks from kitune-san's
[KFPC-XT](https://github.com/kitune-san/KFPC-XT), under the MIT license in
[LICENSE](LICENSE):

- `HDL/KF8259` - the master and slave 8259 interrupt controllers.
- `HDL/KF8253` - the 8254-compatible programmable interval timer.
- `HDL/KFSDRAM` - the SDRAM controller used when the AT RAM is on the MiSTer
  SDRAM module.

The other files under `HDL/` are PCAT-286 glue inherited from PCXT-EGA_MiSTer
(EGA VRAM front end, ROM presence latch and the splash F12 hold).
