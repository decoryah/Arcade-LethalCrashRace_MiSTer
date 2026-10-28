# Vendored modules

Third-party HDL copied into the tree (no submodules, so the build is self-contained and reproducible). Each keeps its own licence
alongside.

| module | upstream | licence |
|---|---|---|
| fx68k | https://github.com/ijor/fx68k @ 0602ee4627b10f301298f2673d826cdd6baa9327 (Jorge Cwik's cycle-exact 68000); copied from the owner's Aquarium core with its two local changes (below) | GPL-3.0 or later |
| cpu-tv80 | https://github.com/hoglet67/tv80 (Guy Hutchison's tv80), with the `tv80s_cen.v` clock-enable wrapper from plasticbugs/punchout; copied from the owner's Aquarium core with the Hexion core's local changes (below) | MIT |
| jt12 | https://github.com/jotego/jt12 @ efa4068a12c9771643fb98bcaaea58c860f5b000 (Jose Tejada's YM2612 / YM2610: `hdl/*.v`, `hdl/adpcm`, `hdl/mixer`; the core uses `jt10`, the YM2610), unchanged | GPL-3.0 or later |
| jt49 | https://github.com/jotego/jt49 @ 6f1247fe0282a70c86ea2b4d8aa901f5332c94db (Jose Tejada's AY-3-8910, the YM2610's SSG; jt12's submodule, copied beside it), unchanged | GPL-3.0 or later |
| crt-adjust | https://github.com/rmonic79/MiSTer-CRT-Adjust @ c682de9f4acc61d8f4c7779efb48149d3baa3a8e (upstream's `rtl/crt_adjust.sv`), by rmonic79 (Umberto Parisi) with Andrea Bogazzi (asturur); copied from the owner's Aquarium core with its local changes (below) | GPL-3.0 or later |

To update one: re-copy from upstream at the new commit and record it here.

## fx68k (the Aquarium core's changes, kept)

`fx68k.sv`, the three `typedef struct` of its decoded signals: declared `packed` (Verilator rejects upstream's unpacked structs
assigned partly in `always_ff` and partly by `assign`; Quartus builds either the same way).

`fx68k.sv` (marked "Aquarium core"): a new output `oWrDSn`, the data strobes a write cycle will assert, valid from AS on, so the
core makes a write in the clock MAME's time reaches it.

The microcode ROMs are read with `$readmemb("microrom.mem")` / `"nanorom.mem"`: Quartus finds them through the search path
(`files.qip`), the benches link them into `sim/`.

## cpu-tv80 (the Hexion core's changes, kept)

Built with `TV80_REFRESH` (the R register). `tv80_core.v`, `tv80_reg.v`: MAME 0.289's power-on register values. `tv80_core.v`,
`tv80_mcode.v`: the NMI's acknowledge takes 11 T-states, as a Z80's and MAME's do; Crash Race's sound Z80 takes an NMI for every
command the 68000 writes to the latch.

## crt-adjust (the Hexion and Aquarium cores' changes, kept)

The line buffer's size `AW` is a parameter (CrashRace.sv: 10, for its 406-dot line); a `vtotal` input sets a negative V-Shift's tap
(CrashRace.sv: 263); `hoff_s` sign-extends `hoffset` explicitly.
