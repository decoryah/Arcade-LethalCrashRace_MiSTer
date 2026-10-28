# Lethal Crash Race for MiSTer

A MiSTer FPGA core for **Lethal Crash Race / Bakuretsu Crash Race** (Video System, 1993), the top-down kart racer: a 68000, a Z80
with a YM2610, a char layer, a K053936 rotating / zooming layer and the VS9108 / VS9210 sprite chips. Written from MAME 0.289's
driver (`src/mame/vsystem/crshrace.cpp`, with `vsystem_spr.cpp`, `k053936.cpp` and the devices it uses), with MAME as the reference
for everything; the platform layer follows the owner's Aquarium core.

No ROMs are in this repository; you supply your own MAME `crshrace.zip`.

**Status.** Simulated with the game's real programs (`sim/run_sys.sh`) and compared with MAME 0.289: the power-on test, the
attract mode (the Video System logo, the K053936 zoom of the title, the title screen) and a credited race start are pixel-identical
to MAME's frames, and the 68000's sound commands come in the same frames as MAME's. The audio follows MAME's second by second (the
first seconds of the attract music some 25 % quieter: the SSG's mix level is still to be checked). Built with Quartus 17.0
(`releases/crashrace_20261028.rbf`: 38 % of the ALMs, 434 of 553 M10K blocks; timing met at 96 MHz with 0.30 ns of setup slack).
**Not yet tested on a real MiSTer.**

## Install

1. Copy the core (`releases/crashrace_<date>.rbf`) to `_Arcade/cores/`, `mra/Lethal Crash Race (set 1).mra` to `_Arcade/` and
   `mra/_alternatives/_Crash Race/` to `_Arcade/_alternatives/`. Keep the RBF's `crashrace_` name: MiSTer finds the core by the
   MRA's `<rbf>`.
2. Put your MAME 0.289 `crshrace.zip` (the merged set holds all three versions) in `/media/fat/games/mame/`.
3. Start `Lethal Crash Race (set 1)` (or a set 2 MRA) from the Arcade menu. A recent Main_MiSTer copies the 12.6 MB image to the
   DDR3 in one go (the MRAs' `address=`, the fast load) and the core reads it from there; an older one streams it.

| Set | MRA |
|---|---|
| `crshrace` | Lethal Crash Race (set 1) |
| `crshrace2` | Lethal Crash Race (set 2) |
| `crshrace2a` | Lethal Crash Race (set 2, alternate sound ROM) |

## Controls and OSD

An 8-way joystick and two buttons per player, Start and Coin, named for what they do: **Accel** (MAME's button 1) and **Brake**
(button 2). Keyboard: 1 / 2 start, 5 / 6 / 7 coin, 9 service, T tilt, F1 test.

| Option | Values |
|---|---|
| Aspect ratio | Original (3:4 turned, 4:3 with Orientation Horz), Full Screen, [ARC1], [ARC2] |
| Orientation | Vert (the default): the vertical game turned upright for HDMI through a frame buffer in the DDR3 (the framework's `screen_rotate`); Horz: as the board makes it, for a monitor on its side. The analog output is always the board's |
| Scale | Normal, V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+ (the framework's integer scaling for HDMI) |
| Scandoubler Fx | None, HQ2x, CRT 25 / 50 / 75 % |
| CRT Adjust (page) | Off, On; H-Size 0, +1 and -16 to -1, H-Position, V-Shift -16 to +15: rmonic79's CRT Adjust (`modules/crt-adjust`) for a 15 kHz analog output, the picture moved and sized through a line buffer while the sync keeps its timing. The position stops where the picture would reach into the hsync pulse or past the line's end. It does nothing while the scandoubler is on (31 kHz) |
| Flip Screen | Off, On: the picture turned 180 degrees by the core's renderer (analog and HDMI alike). It is not applied while the Service Mode is on: the test screens are drawn for the upright cabinet. The game's own Flip Screen DIP switch stays Off |
| DIP switches | MAME's: Demo Sounds, Free Play, Difficulty, Coin Slot, Coin A, Coin B, 2 to Start 1 to Continue, Reset on P.O.S.T. Error, Region |
| Service Mode | Off, On: the board's service switch (SW2:4). The game looks at it when it starts: set it, then Reset |
| Volume | Normal, -6 dB, -12 dB, +6 dB |
| Audio | Stereo, Mono |
| Swap stereo | No, Yes |

## The video timing

One raster: 263 lines of 406 dots at a 6.4 MHz dot (15.76 kHz, 59.94 Hz), the 320 x 224 picture with 39 blank lines; a standard
240p-class signal for a CRT, and what a RetroTINK 4K takes as "MiSTer 240p".

## How it is built

`rtl/` holds the machine (`crshrace_core.sv`: the 68000, its memory map and the start; `crshrace_video.sv`: the raster, the video
memories' display copies taken at the vblank as MAME draws there, the layers' line renderers `crshrace_chars.sv`, `crshrace_roz.sv`,
`crshrace_sprites.sv`, the mix and the palette; `crshrace_sound.sv`: the Z80, the latch and jt10 with its ADPCM ROMs read from the
SDRAM) and the platform layer (`crshrace_sdram.sv`, `crshrace_loader.sv`, `crshrace_fastload.sv`). Every ROM lives in the SDRAM; the
CPUs read theirs through caches, and the 68000 and the Z80 are held while a miss fills and given back the cycles they missed
afterwards, so their programs stay on MAME's timeline.

`tools/make_mra.py <crshrace.zip>` writes the MRAs and checks each against `tools/crshrace_rom.py`, which builds the image by MAME's
loading rules. `sim/lint.sh` lints the RTL with Verilator; `sim/run_sys.sh` runs the whole machine (the image downloaded through the
loader into a behavioural SDRAM) and writes its pictures.

Building: Quartus 17.0 Lite, `CrashRace.qpf`.

## Licence

GPL-3.0-or-later (`LICENSE`); the vendored modules keep their own (`modules/VENDOR.md`).
