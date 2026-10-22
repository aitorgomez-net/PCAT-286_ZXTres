# PCAT-286 on the ZXTRES+: specification

This file states what the ZXTRES+ port of PCAT-286 must do, what exists
today, and what is left to develop. It is a companion to
[PORT.md](PORT.md), which records how the port was built and what each
milestone verified.

Evidence levels used below:

- **Sim**: passes in the Verilator/GHDL board simulation in `sim/`.
- **Built**: synthesizes and meets timing in Vivado.
- **Board**: observed on a ZXTRES+. Nothing is at this level yet. The
  CPU-only demo (`README.md`) is the first board test and has not been
  reported back.

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
| Boot splash, HPS info notices | Not needed; the OSD shows missing ROMs. |
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
| Controller | Firmware in block RAM, 16 KiB here (`demistify_romspace` 14) | Every firmware feature competes for 16 KiB. Raise the constant if a build needs more. |
| Files | FAT16/32 reads and writes, 8.3 names, bookmarks | Cannot create files: CMOS and any writable image must already exist. |
| OSD | Pages (`P`), options (`O`, `T`), file select (`F`), disk mount (`S`); 7 entries per page | Status bits 0-61 only (digits 0-9, A-Z, a-z), so MiSTer bits 62 and up must be moved. No conditional entries (`h`), no `J`, `R`, `V` in the firmware. |
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

Branch `zxtres-port`. Everything below is Sim or Built. None is Board.

### 3.1 Built and simulated

| Piece | State | Where |
| --- | --- | --- |
| Toolchain: DeMiSTify and mist-modules (pinned), firmware from source, Vivado non-project flow to `.ZX3` | Built | `scripts/build_pcat.sh`, `build_firmware.sh`, `bit_to_zx3.py` |
| Board top: controller, joystick decoders, PS/2 and SD wiring, pin constraints | Built | `rtl/zxtres_pcat_top.sv`, `constraints/zxtres_pcat.xdc` |
| PC/AT machine: SPK286 CPU, bridge, PIC, DMA, PIT, 8042, RTC/CMOS, EMS/UMB, serial mouse, gameport, EGA, VGA 13h+ | Built, Sim | `rtl/pcat286_zxtres_guest.sv`, generated verbatim from `PCAT-286.sv` by `scripts/make_guest.py` (`--check` guards drift) |
| AT RAM in the board SDRAM through the MiSTer SDRAM owner, 50 MHz | Built, Sim (pin model) | guest |
| ROM loading from the card (`PCAT286.ROM`, `EGA.ROM`) with the machine held in reset | Built, Sim | `firmware/overrides.c` |
| OSD overlay and keyboard path (PS/2 to `ps2_key` events) | Built, Sim | `rtl/zxtres_ps2_rx.sv`, `zxtres_ps2_key.sv` |
| CMOS kept in `PCAT286.CMS` on the card, restored before the BIOS runs, saved on change | Built, Sim | `rtl/zxtres_cmos_store.sv`, `sim/run_cmos_store_test.sh` |
| Whole-board simulation: MR BIOS 1.65 with IBM EGA ROM reaches setup | Sim | `sim/run_bios_sim.sh` |
| CPU speed profiles (MAX to 25 MHz), monitor type, display tint, joystick mode | Built (OSD entries present) | guest `CONF_STR` |

Build figures *as of 15 October 2026*: 50 MHz closes with WNS +0.063 ns using
the `ExtraTimingOpt`/`AggressiveExplore` directives, 31.6k LUTs, 31.6k
registers, 87.5 of 135 block RAM tiles.

Reading of those figures: about 17k of the registers are the MiST `osd.v`
buffer (PORT.md, milestone 1), so the machine is nearer 15k. The sound
devices are probably missing from the count: the guest does not carry the
audio mixer, so the machine's sound outputs are unconnected and Vivado can
prune the devices behind them. Re-measure after section 5.3 and section 5.4.

### 3.2 Present in RTL, not connected

| Piece | State |
| --- | --- |
| Audio devices (OPL2, Sound Blaster, C/MS, Tandy, speaker) | Instantiated in the machine; `DAC_L/R` tied to 0; board pins `AUDIO_*`, `I2S_*` driven low |
| IDE | Machine IDE (AO486 `ide.v`) present; management window not served; `at_ide_request` unused |
| Floppy controller | Present; management window not served; `at_floppy_*` unused |
| Mouse | Serial mouse from the PS/2 port is wired (`MSMouseWrapper`); needs board test only |
| Firmware for IDE and block devices | Enabled in `config.h` (2 IDE units, 3 `diskimg` units) and calling `OpenHardfile` for `PCAT286A.VHD`/`PCAT286B.VHD`; the guest side is missing |

### 3.3 Not started

DisplayPort, a video path a VGA monitor can lock to (section 4, finding F1),
audio output, floppy, hard disk data path, full RAM size choice, the remaining
OSD settings, I/O timing constraints, return to the Spectrum core, any board
test.

## 4. Findings that change the plan

**F1. The VGA connector carries EGA's native raster, not 31 kHz.**
`rtl/video/ega_top.v` forces `ega_scandouble_active = 1'b0` (the MiSTer build
targets 15 kHz CRTs) and the guest drives `VGA_HS/VS` from the pipeline output
with no converter. EGA 200-line modes come out at about 15.7 kHz, 350-line
and MDA modes at about 21.8 and 18.4 kHz. Only the VGA 13h+ profiles
(31.4 kHz) are VGA rates. Most VGA monitors will not lock to the others.
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

**F4. Block-device slots.** `user_io` and the firmware support 4 `diskimg`
units. Floppy A, floppy B, IDE 0-0 and IDE 0-1 as `diskimg` units, plus the
CMOS file (unit 2 today), need 5.

**F5. Audio is not in the guest.** `make_guest.py` does not copy the mixer,
volume and compressor stage (`PCAT-286.sv` from the `audio_sum` lines to the
`AUDIO_L/R` assignments), so adding audio is a generator change, not only a
wire.

**F6. Joystick default.** The OSD order is Analog, Digital, Disabled, and the
guest ties the analog inputs to zero, so in the default Analog mode the stick
reads as fixed. DB9 pads are digital only, so Digital should be the default.

**F7. Installed RAM is limited in the OSD to 4 and 1 MiB.** The MiSTer core
also offers 2, 8 and 16 MiB, and the board SDRAM (64 MiB) is large enough. The
EMS backing uses SDRAM `200000h-3FFFFFh`
and the AT RAM above 2 MiB is translated upward by 2 MiB, so 16 MiB plus EMS
fits in 64 MiB; to be confirmed against the SDRAM owner's address range.

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
controller (5.2). Resolve F4 first: either lift the 4-unit limit in the
firmware and `user_io`, or keep CMOS and disk images within 4 units (for
example one floppy first). If the limit proves hard, fall back to B for IDE
only.

Pass condition: DOS boots from `PCAT286A.VHD` and a second disk is visible
as drive D; BIOS geometry matches what the firmware reports; writes survive a
power cycle. Test in simulation with the SD card model before the board.

### 5.2 Floppy drives (P1, M)

- A master on the F2xx window serving 512-byte sectors from `diskimg` units
  0 and 1: geometry from the image size (160K to 1.44M, IMG/IMA/VFD), media
  change on mount, write protect from the OSD.
- Check sector latency: a real 1.44M floppy gives a sector about every
  11 ms; SD reads through the firmware with bookmarks must stay well under
  that. Measure rather than assume.
- OSD: `S0,IMGIMAVFD,Floppy A:;`, `S1,...,Floppy B:;`, write protect option.
- Pass condition: boot a DOS 1.44M floppy, copy files both ways, read a 720K
  and a 360K image.

### 5.3 Audio (P1, M)

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

- **P0**: replace `mist-modules/osd.v` with a protocol-compatible block RAM
  version. It costs about 17k registers and 6k LUTs today; this also eases
  timing.
- Restore Installed RAM 1, 2, 4, 8 and 16 MiB (F7), the Joystick default
  (F6), joystick swap and CPU sync, write protect (5.2) and the ROM selection
  entries (`F`) so a user can pick other BIOS files than `PCAT286.ROM`.
- Keep options within the firmware's limits: 7 entries per page, status bits
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

1. **Stage 1, VGA pass-through plus doubler (P0, M).** Use `mist_video`'s
   scandoubler for the 15.7 kHz modes and the 31.4 kHz profiles unchanged,
   with the OSD over both. It leaves 350-line and MDA modes on an unusual
   rate, so those need a display that accepts about 18-22 kHz (CRT
   multisync, some capture devices).
2. **Stage 2, scan converter (P0, L).** Capture the machine's 57 MHz
   pipeline into a 6 bit frame store and read it out as 640x480 at about
   60 Hz, which is also what DisplayPort needs. The MiSTer core already has
   a capture and readout pair (`ega_fb_capture.v`, `ega_fb_readout.v`,
   `ega_ddr_arbiter.v`) for DDR3; back it with block RAM (about 37 RAMB36
   for 640x350) or the 2 MiB SRAM, which leaves block RAM free. Decide after
   the resource re-measure in 5.3. Frame-rate conversion between 70 Hz VGA
   modes and 60 Hz output drops a frame about one in seven.
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

- Board-test the PS/2 serial mouse path with CuteMouse (`/S14 /Y`).
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
2. 5.4 OSD buffer on block RAM, then 5.1 hard disks and 5.5 stage 1 video
   (independent; can be developed in parallel).
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
