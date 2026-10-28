## Lethal Crash Race for MiSTer - 20261028

Video System's **Lethal Crash Race / Bakuretsu Crash Race** (1993), the top-down kart racer (a 68000 at 16 MHz, a Z80 with a
YM2610, an 8 x 8 char layer, a K053936 rotating / zooming layer and the VS9108 / VS9210 sprite chips), with three MRAs: set 1,
set 2 and set 2 with the alternate sound ROM.

**First release. Checked in simulation against MAME 0.289 (below); not yet tested on a real MiSTer.**

### Install

1. Unzip `LethalCrashRace_MiSTer_20261028.zip` over the root of the SD card. It adds `Lethal Crash Race (set 1).mra` to `_Arcade/`,
   `Lethal Crash Race (set 2).mra` and `Lethal Crash Race (set 2, alternate sound ROM).mra` to `_Arcade/_alternatives/_Crash Race/`
   and `_Arcade/cores/crashrace_20261028.rbf`.
2. Put your own MAME 0.289 romset `crshrace.zip` (the merged set holds all three versions) in `games/mame/`. No ROMs are included.
   The MRAs check the romset's md5 the way MiSTer computes it: another dump of the set gives "md5 mismatch", and MiSTer then does
   not load it.
3. Start the game from the Arcade menu. The ROM image is 12.6 MB: with a recent Main_MiSTer it is copied to the DDR3 in one go (the
   MRAs' `address=` attribute), with an older one it is streamed, with the same RBF and MRAs. The game's power-on test then runs, as
   on the board.

The OSD's version line reads `v261028`. The game's settings are its DIP switches (the OSD's DIP page); it has no NVRAM.

### Video

- **Orientation:** Vert (the default) turns the vertical game upright on HDMI through a frame buffer in the DDR3 (the framework's
  `screen_rotate`); Horz leaves the board's picture as it is, for a monitor on its side. The analog output is always the board's.
- **Scale:** Normal, V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+.
- **The signal:** MAME's 320 x 224 picture on a standard 15 kHz 240p raster: 263 lines of 406 dots at a 6.4 MHz dot (15.76 kHz,
  59.94 Hz), every line the same; for a CRT, and what a RetroTINK 4K takes as "MiSTer 240p".
- **CRT Adjust** (its own OSD page): rmonic79's module for a 15 kHz analog output. H-Size -16 to +1, H-Position (it stops where the
  picture would reach into the hsync pulse or past the line's end), V-Shift -16 to +15. Off while the scandoubler is on.
- **Flip Screen:** the core turns the picture 180 degrees, on the analog output and HDMI alike. Not applied while Service Mode is
  on, so the test screens stay readable. The game's own Flip Screen DIP switch is held Off (MAME does not flip this game).

### Controls

An 8-way joystick and two buttons, **Accel** and **Brake** (MAME's buttons 1 and 2), Start and Coin, for two players; the names
show up in MiSTer's button mapping. Keyboard: 1 / 2 start, 5 / 6 / 7 coin, 9 service, T tilt, F1 test.

### OSD

Aspect ratio, Orientation, Scale, Scandoubler Fx (None, HQ2x, CRT 25 / 50 / 75 %), CRT Adjust, Flip Screen, the DIP switches
(MAME's: Demo Sounds, Free Play, Difficulty, Coin Slot, Coin A, Coin B, 2 to Start 1 to Continue, Reset on P.O.S.T. Error, Region),
Service Mode (the board's switch: set it, then Reset), Volume (Normal, -6 dB, -12 dB, +6 dB), Audio (Stereo, Mono), Swap stereo,
Reset.

### Checked

- **ROM path:** `tools/make_mra.py` assembles all three MRAs' images by the MiSTer MRA rules (the md5 as MiSTer computes it) and
  compares them with the image `tools/crshrace_rom.py` builds by MAME's loading rules: identical.
- **The whole machine** (`sim/run_sys.sh`: both CPUs running the game's programs, the ROM image loaded through the SDRAM controller
  into an SDRAM model that checks its timing, the video, the YM2610), against MAME 0.289's snapshots:
  - with no inputs: the power-on test and the attract mode (the Video System logo, the K053936 zoom of the title, the title
    screen) pixel-identical;
  - with MAME's scripted inputs (a coin, start, Accel, steering): the credited title, the car select, the stage map and a race's
    start pixel-identical;
  - the 68000's sound commands in the same order and frames as MAME's.
- **Flip Screen:** a flipped picture is the unflipped one turned 180 degrees, dot for dot.
- **Sound:** the loudness second by second against MAME's recording: the same from the sixth second on.
- **Quartus 17.0:** 38 % of the ALMs (15,771), 434 of 553 M10K, 44 DSPs; every clock's slack positive (the 96 MHz machine clock
  +0.295 ns setup, +0.249 ns hold; the HDMI clock +0.369 / +0.256 ns). `releases/crashrace_20261028.fit.summary` / `.sta.summary`.

### Where the core is not MAME

- **The frame rate:** 59.94 Hz on the core's 263-line raster, not MAME's 60.00 (MAME's screen for this driver has no blanking
  times): the game runs 0.1 % slower.
- **Flip Screen:** MAME does not flip this game; the core turns MAME's picture 180 degrees. Where the board puts its flipped
  picture is not known.
- **The YM2610 is jt10**, not MAME's ymfm.

### Known differences / open points

- **Not yet run on real hardware.** The MiSTer top level (`screen_rotate`, CRT Adjust, the fast load) is built and timed but was
  not simulated; reports from a real MiSTer, an RT4K or a CRT are welcome.
- The first five seconds of the attract music are some 25 % quieter than MAME's; the SSG's mix level is the likely cause.
- MAME lists a third button per player that the game does not appear to use; the core leaves it released.
- MAME's own open points stay open: the CPUs' and the YM2610's clocks are MAME's "???" values (the PCB has 32 and 24 MHz crystals).

### Credits

MAME (the crshrace driver by Nicola Salmoria, the Video System sprite device by Nicola Salmoria and David Haywood, the K053936 by
David Haywood, the generic latch, ymfm by Aaron Giles), Jorge Cwik's fx68k, Guy Hutchison's tv80, Jose Tejada's jt10 / jt12 and
jt49, rmonic79's CRT Adjust (with Andrea Bogazzi), the repository owner's Aquarium core (the platform layer, the benches, the
packaging) and through it the Rabbit, Hexion and Gunpey cores, and the MiSTer framework.
