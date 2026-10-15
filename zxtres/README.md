# SPK286 bring-up demo for the ZXTRES+

A first hardware test of the SPK286 CPU on the ZXTRES+ (Xilinx Artix-7
XC7A100T). It is not the PC/AT machine: it has no chipset, disk, keyboard or
OSD. The CPU, in the same `spk286_machine_cpu` wrapper and MAX profile the
MiSTer core uses, runs a self-checking x86 program from block RAM and shows
the results on VGA.

## What the program does

`demo/demo.asm` (NASM) starts at the 80286 reset vector and does the
following:

1. It measures the CPU clock against the VGA frame rate.
2. It runs 17 instruction tests in real mode, including the CPU checks that
   tell an 80286 from an 8086 or an 80386.
3. It runs the BYTE sieve benchmark (8191 flags, ten passes) timed with the
   hardware cycle counter. It must find 1899 primes.
4. It enters protected mode (LGDT, LIDT, LMSW and a far jump to a selector).
5. It tests protected mode:
   - 24-bit addressing of the RAM above 1 MiB;
   - LAR, LSL, VERR and VERW;
   - a #GP fault on a bad selector.
6. It stays in protected mode, updating an uptime counter, the VGA frame
   number and a spinner.

A failing check shows `[FAIL]` and the ROM offset of the check. `demo.lst`,
written by the build, maps that offset to the source line. An unexpected
exception prints its vector and stack on the bottom text row and halts.

## Hardware

`rtl/zxtres_demo_system.sv` holds the CPU and the following memory and
devices:

- 64 KiB of RAM at 0;
- 64 KiB of RAM at 1 MiB;
- a 64 KiB ROM at F0000h, mirrored at FF0000h;
- an 80x25 text screen at B8000h, shown on VGA at 640x480 60 Hz;
- a cycle counter, the CPU clock and a VGA frame counter on I/O ports.

The CPU clock is 40 MHz by default. Below the 25 text rows, a status line
drawn in hardware shows:

- the last POST code;
- the CPU's CS:IP;
- HLT, SHUTDOWN and FAULT;
- the VGA frame counter.

That line works even if the program never runs. While the CPU has not written
to the screen, the screen shows "The CPU has not written to the screen yet".

The two LEDs:

- **led[0]** blinks from the 50 MHz oscillator, which shows the core is
  loaded.
- **led[1]** blinks once per second when every check passed, and stays lit
  if any failed.

## Building

```sh
zxtres/scripts/build.sh [40|50]      # Vivado 2025.2, xc7a100tfgg484-2
zxtres/sim/run_sim.sh                # Verilator simulation, from WSL/Linux
```

`build.sh` writes `build/zxtres-demo/<MHz>mhz/SPK286DEMO.ZX3`, the `.bit`
file and the timing and utilization reports. `run_sim.sh` simulates the same
system and writes the following to `build/zxtres-demo/sim`:

- the text screen (`zxtres_demo_screen.txt`);
- two VGA frames captured from the sync and colour outputs, as PNG;
- the POST log.

## Loading it on the ZXTRES+

It needs a VGA monitor; this core has no DisplayPort output.

1. Copy `SPK286DEMO.ZX3` to the microSD card.
2. In the ZX Spectrum core, press F5 for the NMI browser, select the file
   and load it. The core goes to a temporary flash slot, so the installed
   cores are not changed.
3. To return to the ZX Spectrum core, power cycle the board.
