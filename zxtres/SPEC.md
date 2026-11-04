# PCAT-286 on the ZXTRES+: specification

This file states what the ZXTRES+ port of PCAT-286 must do, what exists
today, and what is left to develop. It is a companion to
[PORT.md](PORT.md), which records how the port was built and what each
milestone verified.

Evidence levels used below:

- **Sim**: passes in the Verilator/GHDL board simulation in `sim/`.
- **Built**: synthesizes and meets timing in Vivado.
- **Board**: observed on a ZXTRES+, with the date of the observation. Hard
  disks, floppies, the CMOS file, the 480p video paths and the audio jack
  have it; the rows that lack it say so.

Figures marked *as of 15 October 2026* are the build recorded in PORT.md on
that date. They change with every rebuild.

## 1. Goal and scope

Run the PC/AT machine of the MiSTer core on the ZXTRES+ (Artix-7 XC7A100T)
with the same RTL for the machine, so that a fix in one build reaches the
other. Only the glue around the machine is board specific. The port is
delivered as a `.ZX3` core loaded from the microSD card, using DeMiSTify for
the controller, OSD and storage.

In scope: BIOS boot, EGA and VGA 13h+ video on VGA and DisplayPort, PS/2
keyboard and mouse, DB9 joysticks, hard disks and floppies from image files,
audio, CMOS persistence, the OSD settings that make sense on this board.

Out of scope on this board (no hardware or no equivalent service):

| MiSTer feature | Reason |
| --- | --- |
| AT RAM in HPS DDR3 (`PCAT286_RAM_DDR3`) | No HPS. The 64 MiB SDRAM holds the AT RAM. |
| 480i/240p 15 kHz framebuffer for 350-line modes (DDR3) | Replaced by the board scan converter (section 5.5). |
| MiSTer scaler, HDMI, aspect ratio, HQ2x | Replaced by the board video path. |
| MT32-pi, USER I/O MIDI and COM2 | No user port. Optional later through the edge connector (section 5.9). |
| HPS info notices | Not needed; the OSD shows missing ROMs. |
| Second SD card as IDE (`2nd SD card`) | The one microSD slot is the controller's. |

## 2. Platform

### 2.1 ZXTRES+ resources

| Resource | Value |
| --- | --- |
| FPGA | Xilinx Artix-7 XC7A100T-2, FGG484: about 63k LUTs and 4.9 Mbit (135 RAMB36) of block RAM |
| Memory | 64 MiB SDRAM (16 bit), 2 MiB asynchronous SRAM |
| Storage | microSD (SPI mode), 32 MB SPI flash holding the installed cores |
| Video | 8-bit-per-channel DAC on the VGA connector; DisplayPort through a GTP transceiver |
| Audio | Sigma-delta (3.5 mm jack) and I2S |
| Input | Two PS/2 ports (keyboard, mouse), two DB9 ports (Atari, Mega Drive pads). The USB port is not operational. |
| Not present | Real-time clock, HPS or ARM, DDR3 |

Cores are loaded as `.ZX3` files with the Spectrum core's NMI browser or the
BIOS and do not replace the installed cores. The board returns to the Spectrum
core by power cycle, or by a multiboot request (section 5.9).

### 2.2 What DeMiSTify provides, and its limits

DeMiSTify replaces the MiST ARM controller with the EightThirtyTwo soft CPU
and a C firmware, and talks to the core over the MiST SPI protocol
(`mist-modules`: `user_io`, `data_io`, `osd`). The ZXTRES target adds the
`zx3w` wrapper (VGA, DisplayPort, audio, joysticks, return to the Spectrum
core). The capabilities the port relies on, and the limits that shape it:

| Area | Capability | Limit for PCAT |
| --- | --- | --- |
| Controller | Firmware in block RAM, 24 KiB here (`demistify_romspace` 15, chunks of 16 and 8 KiB) | Code, data and stack share it. The OSD, menu and settings code took the 16 KiB of the first builds; raise `demistify_romsize1/2` again if a build needs more. |
| Files | FAT16/32 reads and writes, 8.3 names, bookmarks | Cannot create files: CMOS and any writable image must already exist. |
| OSD | Pages (`P`), options (`O`, `T`), file select (`F`), disk mount (`S`); 15 entries plus a footer per page | Status bits 0-61 only (digits 0-9, A-Z, a-z), so MiSTer bits 62 and up must be moved. No conditional entries (`h`), no `J`, `R`, `V` in the firmware. |
| Status word | 64 bits with `CONFIG_STATUSWORD_64BIT` | MiSTer uses 128. Reordered in `make_guest.py`. |
| ROM loading | `data_io` stream by index, from a file chosen in the OSD or loaded by `autoboot()` | No wait signal: the core must take each word as it arrives. |
| Block devices | `diskimg`: files mounted as sector-addressed units over `user_io sd_*` | At most 4 units in the current firmware and `user_io`. |
| Hard disks | IDE service: MiST `ide` module over `data_io` hdd channel, two units, PC geometry from the file size | Serves the Minimig-style `ide`, not the AO486 `ide.v` the AT machine uses. |
| Keyboard | PS/2, read by the firmware for the OSD and blocked from the core while the OSD is open | PS/2 only. |
| Mouse | PS/2 in the firmware, or on the wires to the core | The machine reads the wires itself (serial mouse on COM1). |
| Joysticks | 8-bit words (`CONFIG_JOYBITS`), extended protocol | Directions plus up to 4 buttons. |
| RTC | `user_io rtc` from a board clock | The ZXTRES+ has none. |
| Video | `mist_video` and `scandoubler` in `mist-modules` (scandoubler, scanlines, OSD mix); `osd` overlay | They double 15 kHz rasters from a pixel enable. They do not change refresh rate. |
| `zx3w` wrapper | VGA, DisplayPort, sigma-delta and I2S audio, joystick decoder, SRAM pass-through, ICAP return to core 1 | Frame store is fixed at 640x240x18 bit (about 75 RAMB36), input must be PAL/NTSC-like with separate syncs, output is fixed at 640x480. See 5.5. |

Reference cores on the same route: `zxtres/PCXT_DeMiSTify` (PCXT, same
author as this core's machine blocks), `zxtres/jupiter_ace` (wrapper
integration, SRAM use, 3 bit framebuffer), `zxtres/zxtres_wrapper`. The PCXT
port boots IDE images from the card but has **no floppy support**, and its
Xilinx notes list the keyboard as buggy. Floppy here is therefore new ground.

## 3. Current state

Branch `zxtres-port`. Each row below gives its evidence level; a row with no
Board entry has not been observed on a board.

### 3.1 Built and simulated

| Piece | State | Where |
| --- | --- | --- |
| Toolchain: DeMiSTify and mist-modules (pinned), firmware from source, Vivado non-project flow to `.ZX3` | Built | `scripts/build_pcat.sh`, `build_firmware.sh`, `bit_to_zx3.py` |
| Board top: controller, joystick decoders, PS/2 and SD wiring, pin constraints | Built | `rtl/zxtres_pcat_top.sv`, `constraints/zxtres_pcat.xdc` |
| PC/AT machine: SPK286 CPU, bridge, PIC, DMA, PIT, 8042, RTC/CMOS, EMS/UMB, serial mouse, gameport, EGA, VGA 13h+ | Built, Sim | `rtl/pcat286_zxtres_guest.sv`, generated verbatim from `PCAT-286.sv` by `scripts/make_guest.py` (`--check` guards drift) |
| AT RAM in the board SDRAM through the MiSTer SDRAM owner, 50 MHz | Built, Sim (pin model) | guest |
| ROM loading from the card with the machine held in reset: `PCAT286.ROM` and `EGA.ROM` (in the folder `PCAT286` or else the root) by default, any other file chosen in the OSD page `BIOS` and kept in `PCAT286.CFG` | Built, Sim | `firmware/overrides.c` |
| OSD overlay and keyboard path (PS/2 to `ps2_key` events) | Built, Sim | `rtl/zxtres_ps2_rx.sv`, `zxtres_ps2_key.sv` |
| CMOS kept in `PCAT286.CMS` on the card (folder `PCAT286`, or the root without it), restored before the BIOS runs, saved on change | Built, Sim | `rtl/zxtres_cmos_store.sv`, `sim/run_cmos_store_test.sh` |
| Hard disks: the machine's own IDE device served through its management window by an RTL master, from fixed VHD images chosen in the OSD (any folder; the paths are kept in `PCAT286.CFG`) as `user_io` block devices 0 and 1 | Built, Sim (unit test against the real `ide.v`), Board (2026-10-27: owner reports it works; the second disk, write persistence and read speed were not recorded separately) | `rtl/zxtres_ide_store.sv`, `rtl/zxtres_sd_arb.sv`, `sim/run_ide_store_test.sh` |
| Whole-board simulation: MR BIOS 1.65 with IBM EGA ROM reaches setup | Sim | `sim/run_bios_sim.sh` |
| Serial mouse: the PS/2 mouse port (pins P4 and N5, the same as DeMiSTify's ZXTRES template, with pull-ups) to the machine's COM1 (3F8h, IRQ4) through `MSMouseWrapper`, which is a PS/2 host for the mouse (reset, stream mode) and relays Microsoft serial packets; the firmware's own PS/2 mouse code stays off (`config.h`) so the two never answer the same device. COM2 and MIDI have no pins on the board | Built, Sim (a model of a real PS/2 mouse completes the reset and stream handshake on the open-collector bus, and the movement and the RTS identification come out on the serial line), Board: not tested | `rtl/zxtres_pcat_top.sv`, `rtl/pcat286_zxtres_guest.sv`, `sim/run_mouse_test.sh` |
| CPU speed profiles (MAX to 25 MHz), monitor type, display tint, joystick mode | Built (OSD entries present) | guest `CONF_STR` |

Build figures *as of 15 October 2026*: 50 MHz closes with WNS +0.063 ns using
the `ExtraTimingOpt`/`AggressiveExplore` directives, 31.6k LUTs, 31.6k
registers, 87.5 of 135 block RAM tiles.

Reading of those figures: about 17k of the registers were the MiST `osd.v`
buffer, which `zxtres_osd.sv` has since replaced (5.4): the build of
25 October 2026 has 24.4k LUTs, 15.0k registers, 88.5 block RAM tiles and
WNS +0.085 ns. The sound
devices are probably missing from the count: the guest does not carry the
audio mixer, so the machine's sound outputs are unconnected and Vivado can
prune the devices behind them. Re-measure after section 5.3 and section 5.4.

### 3.2 Present in RTL, not connected

Nothing: the audio devices reach the jack (section 5.3) and the mouse reaches
COM1 (section 3.1).

### 3.3 Not started

DisplayPort, I/O timing constraints, return to the Spectrum core from the
OSD. Board tests still to do: the mouse, the joysticks, the CPU speed
profiles below MAX, and the 480i and 240p outputs on a TV.

## 4. Findings that change the plan

**F1. The VGA connector carries EGA's native raster, not 31 kHz.**
`rtl/video/ega_top.v` forces `ega_scandouble_active = 1'b0` (the MiSTer build
targets 15 kHz CRTs) and the guest drives `VGA_HS/VS` from the pipeline output
with no converter. EGA 200-line modes come out at about 15.7 kHz, 350-line
and MDA modes at about 21.8 and 18.4 kHz. Only the VGA 13h+ profiles
(31.4 kHz) are VGA rates. Most VGA monitors will not lock to the others.
Stage 1 (5.5) since doubles the 200-line modes to 31.4 kHz; the 350-line and
MDA ones stay native until stage 2.
PORT.md's mapping table used to say VGA at 31 kHz shows those modes natively;
that was wrong for EGA modes and has been corrected. The comment in the guest that calls the
5153/CGA monitor profile "31 kHz-capable" looks inconsistent with this: that
profile is the 15.7 kHz one.

**F2. The stock `zx3w` frame store does not fit with the machine.** The A100T
wrapper keeps a 640x240 frame at 18 bits per pixel in block RAM: about 75
RAMB36. The machine already takes 87.5 of 135 (as of 15 October 2026). It
also holds only 240 lines, so 350-line EGA and the 480-line VGA modes do not
fit, and its input has to be PAL/NTSC-like. The wrapper's DisplayPort
transmitter and its 640x480 stream generator are reusable; its frame store is
not. EGA is 2 bits per channel, so a 6 bit frame store is enough: about 25
RAMB36 at 640x240 packed six pixels per word, about 37 at 640x350.

**F3. IDE service mismatch.** DeMiSTify's IDE service speaks to the MiST `ide`
module. The AT machine uses the AO486 `ide.v`, served on MiSTer by the HPS
through the management window (F0xx IDE, F2xx floppy, F4xx RTC). PORT.md
milestone 3 assumes the MiST module replaces it. That changes device
behaviour the MiSTer core is verified against, and the MiST module is proven
in the PCXT port with the XT-IDE BIOS, not with AT BIOSes. See 5.1.

**F4. Block-device slots (resolved).** `user_io` takes any number of units
(`SD_IMAGES`; its `drive_sel` is four bits wide), but DeMiSTify's
`diskimg_poll` read the unit of a request in two bits. IDE 0-0 and 0-1, the
CMOS file and the two floppy drives are five units, so `build_firmware.sh`
stages `diskimg.c` with a three-bit mask (units 0 and 1 hard disks, 2 CMOS,
3 and 4 floppies).

**F5. Audio is not in the guest.** `make_guest.py` does not copy the mixer,
volume and compressor stage (`PCAT-286.sv` from the `audio_sum` lines to the
`AUDIO_L/R` assignments), so adding audio is a generator change, not only a
wire.

**F6. Joystick default.** The OSD order is Analog, Digital, Disabled, and the
guest ties the analog inputs to zero, so in the default Analog mode the stick
reads as fixed. DB9 pads are digital only, so Digital should be the default.

**F7. Installed RAM (resolved).** The OSD offers the MiSTer choices, 4, 8,
16, 1 and 2 MiB in that order (status bits 46-48 into `hps_status[74:72]`).
The EMS backing uses SDRAM `200000h-3FFFFFh` and the AT RAM above 2 MiB is
translated upward by 2 MiB, all within the 25-bit (32 MiB) backend address
of `spk286_at_mister_sdram_owner`, so 16 MiB plus EMS fits the 64 MiB SDRAM.
A 1 MiB setting saved with the old single bit (53) now reads as 4 MiB.

## 5. Remaining work

Priorities: **P0** is needed for a usable system on the board, **P1** for
parity with the daily use of the MiSTer core, **P2** is polish. Effort is a
rough size (S under a week, M one to three weeks, L more) and is an estimate.

### 5.0 First board bring-up (P0, S)

- Load `SPK286DEMO.ZX3`, then the skeleton guest (`build_pcat.sh skeleton`),
  then the PC/AT guest. Each step answers one question: does the board and
  clock work, does the controller reach the core, does the machine boot.
- Add the missing I/O constraints: `set_input_delay`/`set_output_delay` for
  SDRAM and the per-crossing constraints of `SYSTEM.sdc` instead of blanket
  asynchronous clock groups (PORT.md, milestone 2 to-do).
- Pass condition: BIOS POST text and setup on a monitor, ROMs loaded from a
  real card, CMOS saved across power cycles, keyboard working with the OSD
  open and closed.

### 5.1 Hard disks (P0, M)

Serve the machine's IDE window from DeMiSTify. Two designs:

| | A: serve the AO486 `ide.v` | B: swap in the MiST `ide` |
| --- | --- | --- |
| Machine RTL | Unchanged | IDE register logic replaced, behind a define |
| New RTL | A management-window master that moves sectors between the IDE FIFO window and `user_io sd_*` | Wiring of `ide` to `data_io` hdd channel |
| Firmware | `diskimg` units for the two disks | Existing IDE service (`CONFIG_IDE`) |
| Block slots | Uses 2 of 4 | Uses none |
| Precedent | `zxtres_cmos_store.sv` already is such a master (Sim) | PCXT port (XT-IDE BIOS) |
| Risk | Slot limit (F4) | Unverified on AT BIOSes; MiSTer behaviour diverges |

Recommendation: **A**. It keeps the verified IDE device and reuses the
pattern the CMOS store proved, and the same master serves the floppy
controller (5.2). F4 was resolved by widening the firmware's unit number.

Pass condition: DOS boots from the first disk's image and a second disk is visible
as drive D; BIOS geometry matches what the firmware reports; writes survive a
power cycle. Test in simulation with the SD card model before the board.

Board (2026-10-27): DOS boots from `PCAT286A.VHD`, the second disk is
recognised as D:, the CMOS configuration survives a power cycle, and a file
created on a disk is still there after one. Read speed is not recorded.

### 5.2 Floppy drives (P1, M)

Built: `zxtres_fdd_store.sv`, a master on the F2xx window serving 512-byte
sectors from block devices 3 and 4: geometry from the image size (160K to
2.88M, IMG/IMA/VFD), media present on mount and absent on eject, write
protect from the OSD. It shares the window with the CMOS and IDE stores, and
`zxtres_sd_arb.sv` the card lines. Unit test against `floppy.v`
(`zxtres/sim/run_fdd_store_test.sh`): mount, read from both drives, write,
eject. The machine's controller ends a non-DMA transfer only on the last
head, so the test reads head 1; a BIOS uses DMA.

Board (2026-10-27): works. Speed is not recorded.

- A master on the F2xx window serving 512-byte sectors from `diskimg` units
  3 and 4: geometry from the image size (160K to 1.44M, IMG/IMA/VFD), media
  change on mount, write protect from the OSD.
- Check sector latency: a real 1.44M floppy gives a sector about every
  11 ms; SD reads through the firmware with bookmarks must stay well under
  that. Measure rather than assume.
- OSD (root page): `S3,IMGIMAVFD,Floppy A:;`, `S4,...,Floppy B:;`, write
  protect options (status bits 19 and 20). Choose an image, then Reset to
  boot from it.
- Pass condition: boot a DOS 1.44M floppy, copy files both ways, read a 720K
  and a 360K image.

### 5.3 Audio (P1, M)

Built: `make_guest.py` copies the mixer and compressor of the MiSTer top (the
MT32-pi source is dropped), does the stereo mix the MiSTer framework did, and
drives `DAC_L/R`; `zxtres_pcat_top.sv` feeds them to the sigma-delta and I2S
modules of `zx3w` at 50 MHz. The sound devices of the machine blocks default
to off (as in the Quartus build), so `build_pcat.sh` and the BIOS sim define
`ENABLE_OPL2`, `ENABLE_CMS`, `ENABLE_TANDY_AUDIO` and `ENABLE_SB`; a define
in the guest file reaches only the files compiled after it. The Vivado
`.bat` splits arguments at `=`, so defines with a value are written
`NAME:VALUE`. Sim (`+BEEP_TEST`): a forced 1 kHz speaker reaches the DAC at
the expected amplitude and both codec pins toggle. Vivado: 34858 LUTs (55 %),
95 block RAMs, WNS +0.217 ns. OSD page Audio: 220h, OPL2, Tandy, speaker
volume, boost, stereo mix (share of the other channel 1/8, 1/4, 1/2).

Board (2026-10-28): sound is heard on the 3.5 mm jack with the board's sound
switch in either position (sigma-delta and I2S). Which source was tried
(speaker, AdLib, Sound Blaster) is not recorded here.

Tandy (2026-11-01, PCAT-286 issue 3): the SN76489 answers at `1E0h–1E3h` as
well as `C0h–CFh` (the shared machine decode, so MiSTer has it too); SCI1.1's
`TANDY3V.DRV` writes to `1E0h` on an AT BIOS. The DMA controller decodes
`C0h–DFh` itself, so it took every C0h write too, and while the chip was busy
(about 9 us per write) it took the write alone and the note was lost. Music
sounded garbled (the `tandy64` demo). A first fix withdrew `C0h–CFh` from the
DMA controller; that broke the POST (test 09 writes and reads back DMA2
there: board with Tandy on, no video after a reset). Now DMA2 keeps the whole
block, and a Tandy-window write is held until the device router is idle, so DMA2
and the chip take it in the same cycle (the CPU waits while the chip is busy). The
router also offers a request to the sound adapter only while it is idle,
so a busy chip cannot take one twice. The SN76489 is reset with the CPU's
warm reset (8042 pulse). Sim: `scripts/test_at_tandy.sh` (chip, machine decode,
DMA2 read-back of FF/00/AA/55 with the chip on, a burst of 8 writes reaching
the chip and DMA2 once each in 77 us) and a BIOS run with Tandy on
(`zxtres/sim/run_bios_sim.sh` now builds the sound devices as the board does;
before that the sim had Tandy compiled out). Not tried with a game.

- Extend `make_guest.py` to copy the mixer, volume, compressor and mix stage.
- Drive `AUDIO_L/R` (sigma-delta) and the I2S pins from the 16-bit output,
  reusing `zx3w/sigma_delta_codec.v` and `zx3w/i2s_sound.v` (the I2S module is
  parameterised on its clock, 81 MHz in the wrapper).
- Add the OSD entries the MiSTer core has for audio: Audio 220h, OPL2, Tandy,
  speaker volume, stereo mix, compression (these exist for 220h, OPL2 and
  Tandy; volume and mix are missing).
- Re-measure resources and timing: the sound devices enter the netlist for
  the first time (F5).
- Pass condition: speaker beep, AdLib music and Sound Blaster digital sound
  under DOS games, with no dropouts at the default CPU speed.

### 5.4 OSD and settings (P0 for the buffer, P1 for the rest, S to M)

- **P0, character-grid OSD done (Sim, Built); 32x16 grid verified in simulation**:
  `mist-modules/osd.v` is replaced by `rtl/zxtres_osd.sv` on block RAM. The
  original implementation saves 16.7k registers and 6.2k LUTs. The 32x16
  grid covers 256x128 dots at 15 kHz (8-dot cells) and 192x256 dots at
  31 kHz (6-dot cells with each glyph scanline doubled). The firmware sends
  character codes, not pixels (`firmware/osd.c`, `overrides.mk`); the
  font is `rtl/common/font0.hex` (jtframe, GPL v3) plus the menu symbols and
  icons (codes 80h-92h, `make_mem.py`). The centered, fixed cyan
  `PCAT-286 ZXTres` title, an information line and a help line, and an
  EGA-style blue corner frame surround the menu. The 31 kHz
  line doubling, header/frame colors and SPI row addressing pass the OSD
  testbench.
  Tuning: glyph width and the 300-line threshold are in `zxtres_osd.sv`.
- **OSD look (Built, Sim)**: each row carries a colour per character (eight
  colours, `rtl/zxtres_osd.sv`), the selected row is a blue bar with white
  text, the panel is the picture dimmed with a blue tint and a shadow, and the
  box can sit in the centre or a corner (`0x50 | n`). The SPI row is the
  command, an attribute byte, 32 characters and 32 colour bytes; rows 16 and
  17 (commands `0x30`, `0x31`) are the information line under the title (CPU
  speed, RAM, monitor) and the help line at the foot (what Enter does on the
  row under the cursor). In a label, codes 1-8 select a colour (8 is white)
  and take no column, and a first character from 88h up is an icon. The look
  is made by `Menu_DrawRow` and `Menu_DrawExtras` in `firmware/overrides.c`,
  which tell the row kinds by their actions: an option shows the name, the
  value in a column of its own, and `<` `>` around it on the row under the
  cursor, where left and right change it (`Menu_AdjustRow`); a page shows an
  icon and an arrow; an image shows its name in green. `L,Title;` entries of
  the configuration string are rules that group rows (`expand_demistify_osd.py`
  adds the entry type); messages are centred on the last row in green, yellow
  or red; the file selector shows `NAME.EXT` and the size. `OSD position`
  (status bits 11-13) is applied by `Menu_DrawExtras`.
  `sim/run_osd_test.sh` draws three pages at both line counts and four box
  positions; `sim/run_bios_sim.sh ... +OSD_TOUR` walks the real menu of the
  firmware with the cursor keys and saves a frame of each page.
- **Menu layout (Built)**: the root page lists the four drives with the name
  of the mounted image after each label (`S3`, `S4` floppies; `S0`, `S1` hard
  disks, extensions VHD and IMG), a `Machine` group with CPU speed, installed
  RAM and the floppy write protect, then the pages `Video` (Picture: monitor,
  display, CRT H offset 0-15 and CRT V offset 0-7, which centre the picture on a TV
  as on MiSTer (status bits 49-52 and 53-55, wired to the machine's
  `crt_h_offset`/`crt_v_offset`; Tandy moved to bit 56); Output: VGA 13h, scandoubler, scan converter; Boot splash: splash
  time), `Audio` (sound cards,
  levels), `Input` (joysticks), `BIOS` (the system and EGA BIOS files, below)
  and `Settings`, and Reset. The name comes from
  `imagename()` in `firmware/overrides.c`, recorded when `loadimage()` mounts
  a file, and is shown by a hook that `expand_demistify_osd.py` adds to the
  file selector entries of `main.c`. Choosing a hard disk needs a Reset for
  the BIOS to detect it. The same script gives the cursor keys auto-repeat in
  `menu.c` (first repeat after 400 ms, then every 80 ms) and makes the cursor
  skip the empty rows and rules, so down from the last entry lands on Back.
  Pages keep to 14 entries: a page of 15 makes the menu think it can scroll.
- **ESC (Built, Sim)**: as on MiSTer, ESC backs out of the menu: from a page
  (or a file list) to the main page, from the main page it closes the OSD.
  `expand_demistify_osd.py` adds the key to `Menu_Run()` in `menu.c`, which
  calls `osd_escape()` in `overrides.c`; an ESC pressed while the OSD was
  hidden belongs to the machine and is dropped by the menu code, not by
  the machine (the controller already hides the keyboard while the OSD is
  open).
- **BIOS files (Built, Sim)**: `P5,BIOS;` holds two file selectors, `SB`
  (System BIOS, extensions ROM and BIN) and `SE` (EGA BIOS), which are the
  firmware's units `B` and `E` (`BIOS_UNIT`, `EGA_UNIT`). Choosing a file
  makes `loadimage()` hold the machine in reset, send the file with the same
  ROM upload as at start-up (index 0 for the system BIOS, 3 for the EGA, at
  most 32 KB), and release the reset, so the new BIOS runs from the start;
  entering the selector leaves the loaded one in place. `PCAT286.ROM` and
  `EGA.ROM` stay the defaults: `autoboot()` loads them when the CFG names no
  file, or the named one is gone, and Reset to defaults loads them again.
  The new page adds a row to the main page, which now fills all 16 rows of
  the OSD (the tour's `tour_root.osd` shows it); another entry there needs a
  page of its own.
- **Video info page (Built)**: `P1PP,Video info;` at the end of the Video
  page opens `MENUPAGE_VIDEO` (`video_page()` in `overrides.c`; hook, and a
  refresh about twice a second while it is open, in `main.c` through
  `expand_demistify_osd.py`). It shows what the machine draws (size of the
  picture in dots and lines, and whether it goes through the line doubler, the
  scan converter or neither) and what really leaves the VGA pins (line and
  frame frequency, lines per frame, line time, width and polarity of HSync and
  VSync), as MiSTer's Video info does, to see the raster the BIOS puts out.
  `rtl/zxtres_vidinfo.sv` measures the pins with the 50 MHz clock and the
  picture with the video clock, and returns 18 bytes (signature `A5`, flags,
  line period, HSync high time, frame period, VSync high time, lines per frame,
  dots and lines of the picture) over the `user_io` "keyboard LED" command
  (`0x1f`, whose answer was a constant): the firmware sends the command and
  clocks 18 bytes out; the module counts the bytes itself because user_io only
  keeps the value of `leds` it is given, and takes a snapshot on every
  chip-select so that a read is consistent. `sim/run_vidinfo_test.sh` checks the
  module with a synthetic CGA raster and the real `user_io`; `sim/
  run_bios_sim.sh ... +OSD_TOUR` (or `+VINFO_ONLY`) saves the page.
- **Settings page (Built)**: `P3,Settings;` holds the `Info` page (core,
  machine and mounted images, `info_page()`), `OSD position`, and two triggers, `T1` Save
  settings and `T2` Reset to defaults (status bits 1 and 2, never set: the
  `toggle()` override in `overrides.c` catches them). Each opens a page of its
  own (`MENUPAGE_CONFIRM`, hook in `main.c`) that asks Yes/No; Back is the
  default row. Save writes `PCAT286.CFG` (version 3) in the folder `PCAT286`
  of the card, or in the root when there is no such folder: the status word
  and the path from the root of each of the four drives' images and of the
  two BIOS files (`DISKS/DOS.VHD`, traced back from the directory cluster
  through the `..` entries; six paths of 80 bytes, one that does not fit is
  not kept; `sim/make_cfg_file.py` writes one). `autoboot()` reads it, loads
  the BIOS files it names (else the defaults) and mounts the images; nothing
  is mounted by default. A version 2 file (four paths of 112 bytes, no BIOS)
  is still read.
  Every drive gets a mount event at start-up, empty or not: the IDE store
  answers the BIOS only after it has seen both units (`all_ready`), so a
  start-up that skipped an empty disk 1 left disk 0 undetected. The firmware
  cannot create files, so the folder must hold a 512-byte `PCAT286.CFG`
  (zeroes, or a version 1 file, mean no settings). Reset to defaults zeroes
  the status word, blanks the file and pulses the machine reset.
- **OSD key (Built, Sim)**: Win+F12 opens the OSD, as on MiSTer with
  `F12KEYMOD`, so F12 alone stays with the machine. The firmware's menu key
  (`Menu_OsdKey`, added to `menu.c` by `expand_demistify_osd.py`) is F12 with
  either Windows key down or pressed since the last look; an F12 without one
  is forgotten, and while the OSD is open F12 alone closes it. The controller
  hides the keyboard from the core while the OSD is open (`intercept`, the
  guest's `OSD_OPEN`); `zxtres_ps2_key.sv` gives no event for an F12 pressed
  with a Windows key down nor for its release, and counts both Windows keys
  as up when the OSD closes, since their releases may have gone unseen.
  `sim/run_ps2_key_test.sh` checks the filter; the board testbench opens the
  OSD with Win+F12, and `+F12_ALONE` checks that F12 alone leaves it closed.
- **Boot splash (Built, Sim)**: the MiSTer splash with "ZXTres" in place of
  "MiSTer" beside the title (`zxtres/splash/`, made from
  `SW/splash_vga_320x200.png` by `scripts/make_splash.py`). As on MiSTer it is
  the initial content of the 64 KiB mode 13h framebuffer, drawn by the mode
  13h raster with the 256-colour palette `rtl/video/splash_vga_palette.hex`
  before the CPU starts, so it takes no block RAM of its own; the build
  defines `SPK286_AT_BOOT_SPLASH`. `spk286_at_splash_control` holds the
  machine in reset for a second of settling and then the splash, which fades
  in and out. One entry, `Video > Splash time` (status bits 8-9), sets it to
  5, 10 or 15 seconds (the module's `duration` input) or to 0 s, no splash
  (its `option_off`, MiSTer's Splash Screen No); 5 s is the default and first
  value, so the list reads 5, 10, 15, 0. Like on MiSTer it shows when the core
  is loaded, not on Reset, and a program that has drawn in mode 13h leaves it
  black until the core is loaded again.
- **Credits (Built, Sim)**: the MiSTer core's F12 credits, `jtframe_credits`
  scrolling the text over the dimmed picture, placed ahead of the line
  doubler and the scan converter so both paths carry it. The text is
  `zxtres/credits/msg`, the MiSTer one with "ZXTRES+" in the subtitle and a
  line for DeMiSTify and MiST; `msg.bin` is made from it by
  `credits/msg2hex.cc` (fed without carriage returns) and cut to its first
  8192 lines, the size of the four-page text memory (Verilator rejects more).
  F12 on the splash holds it with the credits until F12 again
  (`splash_f12_pause`, which also stops the splash timer); the board
  testbench checks it with `+CREDITS_TEST`.
- **F12 pause (Built, Sim)**: as on MiSTer, F12 (alone, see OSD key) pauses
  the running machine: `spk286_at_pause_key` takes the key out of the AT
  keyboard stream and toggles the pause on its release, the CPU is held off
  the bus, the audio is muted and the credits scroll; F12 again resumes. It
  does nothing during the splash, which has its own F12 hold. The board
  testbench checks it with `+PAUSE_TEST`.
- Restore the Joystick default
  (F6), joystick swap and CPU sync, write protect (5.2) and the ROM selection
  entries (`F`) so a user can pick other BIOS files than `PCAT286.ROM`.
- Keep options within the firmware's limits: 15 entries plus a footer per page, status bits
  0-61, no conditional entries. The MiSTer pages (System & BIOS, Audio &
  Video, Hardware) map to submenus `P1..P3`.
- Add "Exit to Spectrum core" (5.9) and a CMOS entry that shows whether
  `PCAT286.CMS` is mounted.

### 5.5 Video output (P0, L)

Goal: a picture on any VGA monitor and on DisplayPort, for every mode the
machine produces. Rasters to handle:

| Source | Rate | Native fit |
| --- | --- | --- |
| EGA/CGA 200-line | 15.7 kHz | Needs doubling |
| EGA 350-line, MDA | 21.8 / 18.4 kHz | Needs conversion |
| VGA 13h+ and Mode X profiles | 31.4 kHz, 60 or 70 Hz | Already VGA rates |

Staged design:

1. **Stage 1, VGA pass-through plus doubler (P0, M) - done, Board
   (2026-10-27): the 200-line CGA modes and VGA 13h in TV 60Hz leave as a
   480p picture the monitor locks to.** `zxtres/rtl/zxtres_linedouble.sv` doubles pictures of
   under 300 lines (the 200-line modes, whose 14.318 MHz dot is a fourth of
   the pipeline clock) to 31.4 kHz with `mist-modules`' `scandoubler_framing`
   and its own 6 bit line store, and drives the pair as -HSync/
   -VSync whatever the input polarity, the 640x480 at 59.9 Hz a monitor expects of about 525 lines
   (it was -HSync/+VSync, which monitors read as a 400-line mode). The OSD
   entry `VGA 13h+ CRT: Native 70Hz/TV 60Hz` (status bit 10, as on MiSTer)
   makes the VGA 13h+ modes 15.7 kHz/60 Hz, which the doubler then takes to
   31.4 kHz/60 Hz; with `Scandoubler: Off` they leave at 15.7 kHz, for a
   15 kHz display (the connector carries no composite sync) with +HSync, +VSync whatever the
   timing of the machine: the 200-line modes come in as +HSync, -VSync, and a 15 kHz TV on a
   SCART adapter lost the BIOS picture with that, while the credits (+/+) were fine
   (seen with Video info on hardware).
   350-line, MDA and the 31.4 kHz profiles
   pass through unchanged, with the OSD over both. The choice is made once
   per frame from the line count of the undoubled picture; the OSD entry
   `Scandoubler: Auto/Off` (status bit 60) turns it off. It leaves 350-line
   and MDA modes on an unusual rate, so those need a display that accepts
   about 18-22 kHz (CRT multisync, some capture devices) unless stage 2 is on. The
   core's own doubler in `ega_top.v` stays off: it is shared with the MiSTer
   build and would need ports through four modules.
2. **Stage 2, scan converter (P0, L) - done, validated on the
   board (26 October 2026).** `zxtres/rtl/zxtres_scanconv.sv` takes the pictures stage 1
   cannot (350 lines at under 26 kHz: the EGA 350-line modes and MDA) and
   writes them into the 2 MiB SRAM through `zxtres_sram_ctrl.sv`, then reads
   them out as CEA-861 480p: 720x480 at 59.94 Hz, 27 MHz (own MMCM,
   `u_scan_mmcm`), 858x525 dots, -HSync -VSync, the picture centred and
   unscaled. A pixel is stored as {R[5:4], G[5:4], B[5:4]}, two per 16-bit
   word, which brings EGA's two-bit channels back exactly; the 18 bit VGA
   pictures (31 kHz already) and the 200-line ones bypass the converter. Three
   buffers of 400x360 words (432k of the 1M words) make the writer and the
   reader independent: the writer never takes the buffer being read or the
   last complete one, so a 70 Hz or 50 Hz source never tears against the 59.94
   Hz output, a frame is repeated or dropped now and then. The 57 MHz side
   fills a block-RAM line store (two banks) one line ahead from the SRAM, on a
   toggle and a level from the 27 MHz side; no frame data crosses clocks
   except through that line store. The pins carry the converter's output when
   `conv_active`, else stage 1's, chosen per frame; the OSD has an instance on
   each path. OSD entry `350-line CRT` (status bits 34-35, as MiSTer's `350-line CRT`):
   `480p 31 kHz` (the default, above), `Native` (converter off), `480i 15 kHz` and
   `240p 15 kHz` (below). Cost: one
   more MMCM and RAMB18s for the line store and the second OSD, and none of
   the block RAM the DDR3-style frame store would have taken (about 37
   RAMB36). SRAM protocol: read 2 clocks (34.9 ns for a 10 ns part), write 3,
   one flip-flop-launched pin change per 17.5 ns. The load is about 65 % of
   the SRAM's slots in the worst case (350 lines at 70 Hz plus the readout).
   Not verified: the converter on the board (monitor lock, SRAM signal
   integrity at 57 MHz, tearing); the SRAM pin timing is covered by
   `set_false_path` and the two-clock protocol, not by Vivado analysis.

   **15.7 kHz outputs (480i, 240p), for a TV.** The same converter reads the
   frame store out on a 13.5 MHz dot (the 27 MHz clock halved by a dot
   enable, which also drives the OSD instance), 858 dots a line, so the
   picture is the same 720 dots wide as in 480p. `480i`: 525 lines in two
   fields of 262.5, 240 picture lines each, the image lines 2k+1 in the
   field that starts with its VSync on a line boundary and 2k in the one whose
   VSync starts mid-line 262 (that half line is what interlaces); both
   fields come from one stored frame, so a still picture does not comb and
   motion updates at 29.97 Hz. `240p`: one field of 262 lines, 224 of them
   picture, the 350 source lines squeezed into them 25 to 16 (a little over a
   third dropped), no flicker. Both leave with +HSync (64 dots) and +VSync
   (3 lines), like the not-doubled pictures of the machine (the 15 kHz TV on
   an adapter needs that, see above). The OSD `CRT H offset` (4 dots a step
   from 106 dots after the start of the sync) and `CRT V offset` (a line a
   step) move the picture against the sync. `sim/run_scanconv_test.sh` checks
   both from the pins alone: the row of every line follows from the time
   between the VSync and the HSync in half lines, the VSync of 480i comes
   every 262.5 lines, and the offsets move the picture by the steps above.
   Not verified: on a TV.
3. **Stage 3, DisplayPort (P2, M).** Take the wrapper's DisplayPort
   transmitter, hot-plug and AUX code and its 640x480 stream generator
   (27 MHz pixel clock from the 81 MHz symbol clock) from `zx3w`, and feed
   it from the scan converter's readout. The GTP reference clock and AUX
   pins must be constrained even when DisplayPort is unused. Add the DP pins
   to `zxtres_pcat.xdc`.

The OSD overlay must stay between the converter and the output. The picture
borders and aspect (4:3, borders from the EGA overscan) are a visual
decision to make with the converter, not a CRTC change.

### 5.6 Mouse, keyboard, joysticks (P1, S)

- Board-test the PS/2 serial mouse path with CuteMouse (`/S14 /Y`). The path
  is complete in the design (section 3.1) and `sim/run_mouse_test.sh` checks
  the PS/2 handshake and the serial packets against a model of a real mouse,
  so what is left is a real mouse on the board. It must be a PS/2 mouse (a
  USB one on a passive adapter works only if it speaks PS/2), plugged in
  before the core starts or before a reset of the machine from the OSD.
- Check keyboard behaviour with the OSD toggling; PCXT's port reports typing
  bugs on Xilinx.
- Joysticks: DB9 pads reach the gameport in digital mode (F6). Map Mega Drive
  pads' extra buttons only if a game needs them.

### 5.7 CPU speed and timing closure (P2, M)

- Hold the 50 MHz closure across rebuilds: the margin (+0.063 ns as of
  15 October 2026) is thin, and the audio, floppy, IDE and scan converter
  all add logic. Keep the seed and directives in the build script and
  re-record timing after each work package.
- Test every CPU speed profile on the board, not only MAX.

### 5.8 Return to the Spectrum core (P2, S)

A multiboot request through ICAP (`zx3w/return_to_core1.v`) wired to an OSD
item, instead of a power cycle. Without the full wrapper, only this module is
needed.

### 5.9 Optional (P2)

- Read the Spectrum BIOS video preference from the SRAM configuration the
  wrapper reads at power-on (VGA or RGB output, scanlines) to choose the
  output mode.
- COM2 or MIDI out on edge-connector pins, if a use appears.
- Real-time clock: none on the board; the BIOS clock comes from the CMOS file
  and the user sets the time in DOS.

## 6. Work order

1. 5.0 first board bring-up. Everything else assumes the build works on the
   board, and it can show problems (SDRAM timing, clocks) that change the
   plan.
2. 5.4 OSD buffer on block RAM (done), 5.5 stage 1 video (done, Board),
   then 5.1 hard disks (Board 2026-10-27, see 3.1 and 5.1).
3. 5.3 audio, then re-measure resources.
4. 5.5 stage 2 scan converter, 5.2 floppy.
5. 5.6, 5.7, 5.5 stage 3, 5.8, 5.9.

A usable system for DOS and games needs 5.0, 5.1, 5.4 (buffer), 5.5 stage 1
and 5.3. Floppy images and DisplayPort follow.

## 7. Verification

- Machine blocks are verified by PCAT's own regression
  (`scripts/run_regression.py`) and are copied verbatim; any change to them
  must keep the MiSTer build unchanged and pass the same suites.
- Board glue is verified by `sim/run_bios_sim.sh` (whole board with a real
  BIOS), `sim/run_cmos_store_test.sh` and `sim/run_board_sim.sh`. Each new
  guest module gets a testbench of the same kind: the hard disk and floppy
  masters against the SD card model, the scan converter against captured
  rasters.
- Each work package ends with a Board observation, recorded here with its
  date. A work package is not Board-verified by simulation.
- Keep the evidence levels apart: simulation, timing analysis and board
  observation are different claims, as the README's qualification limits say.
