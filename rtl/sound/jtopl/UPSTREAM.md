# JTOPL source provenance

This directory vendors the OPL implementation from [jotego/jtopl](https://github.com/jotego/jtopl), upstream commit `ff18c4718487fa35889d870b8e3bbaa7dc2ff46f` (2026-11-15).

The OPL2 RTL includes upstream rhythm/timbre corrections and the documented 2x percussion gain. The upstream `jtopl_acc.v` test-build per-channel attenuation was omitted because it applies fixed, board-wide channel gains rather than modeling YM3812 behavior. Simulation-only file logging hooks were also omitted. The GPLv3 license text is in the repository-root [LICENSE](../../../LICENSE); per-file notices retain their terms.
