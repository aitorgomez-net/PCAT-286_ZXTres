# JTOPL source provenance

This directory vendors the OPL implementation from [jotego/jtopl](https://github.com/jotego/jtopl), upstream commit `7ac0c819ad274e208206f2acccbbde80aa06ed1a` (2026-07-29).

The OPL2 RTL includes upstream rhythm/timbre corrections and the documented 2x percussion gain. The upstream `jtopl_acc.v` test-build per-channel attenuation was omitted because it applies fixed, board-wide channel gains rather than modeling YM3812 behavior. Simulation-only file logging hooks were also omitted. The upstream license is retained in `LICENSE`.
