# Lethal Crash Race: the hardware as the core implements it

Everything here is MAME 0.289's (`src/mame/vsystem/crshrace.cpp`, `vsystem_spr.cpp`, `src/devices/video/k053936.cpp`,
`src/devices/machine/gen_latch.cpp`, `src/devices/sound/ymopn.cpp`, `src/emu/tilemap.cpp`, `drawgfx.cpp`, `emupal.cpp`) unless it says
otherwise. The RTL's file headers say the same in more detail, next to the logic.

## The board (Video System, 1993)

| | |
|---|---|
| CPU | MC68000 at 16 MHz (MAME: "16 MHz ???"; the PCB has 32 MHz and 24 MHz crystals, the dividers are not verified) |
| Sound CPU | Z80 at 4 MHz (MAME: "4 MHz ???") |
| Sound | YM2610 at 8 MHz: FM, SSG, ADPCM-A (h893.ic69, 1 MB) and ADPCM-B (h894.ic73, 1 MB) |
| Video | an 8 x 8 x 8 char layer; a 16 x 16 x 4 tilemap through a Konami K053936 (rotation and zoom); the VS9108 sprite generator with the VS9210 tile table (MAME's `vsystem_spr_device`); a 2,048-colour xGBR_555 palette |
| Other | the sound latch (MAME's `generic_latch_8` with a separate acknowledge; its pending flag is readable by the 68000) |
| Screen | ROT270 (a vertical game); MAME: 60 Hz, 512 x 256 with the visible area 320 x 224 at 0, 0 (no blanking times of the board are known) |

Three sets: `crshrace` (set 1), `crshrace2` (set 2: another 68000 program) and `crshrace2a` (set 2 with another sound program,
`2.ic58` CRC 7ef4f9dc). Every other ROM is shared.

## The 68000's memory map

| address | read | write |
|---|---|---|
| 000000-07ffff | program ROM (512 KB) | |
| 300000-3fffff | user1 ROM (w21.ic14, 1 MB) | |
| 400000-4fffff | user2 ROM (w22.ic13, 1 MB), mirrored at 500000-5fffff | |
| a00000-a0ffff | sprite RAM 1: the VS9210's tile table (32 K words) | sprite RAM 1 |
| d00000-d01fff | VRAM 0: the K053936 layer's 64 x 64 tiles | VRAM 0 |
| e00000-e01fff | sprite RAM 0: the VS9108's list and attributes | sprite RAM 0 |
| fe0000-feffff | work RAM (64 KB) | work RAM |
| ffc001 | | the K053936 layer's tile bank |
| ffd000-ffdfff | VRAM 1: the char layer (64 x 32 of its 64 x 64 tiles) | VRAM 1 |
| ffe000-ffefff | palette (2,048 words, xGGGGGBBBBBRRRRR) | palette |
| fff000 | P1 (below) | fff001: gfxctrl (the layers' order, bit 2 blanks the picture, bit 5 MAME's unused flip) |
| fff002 | P2 | |
| fff004 | DSW0 (SW2 in bits 7:0, SW1 in bits 15:8) | |
| fff006 | DSW2: the region in bits 11:8, the sound latch's pending flag in bit 15 | |
| fff009 | | the sound latch |
| fff00a | DSW1 (SW3) | |
| fff00e | P3 (the third player, unused by the released game) | |
| fff020-fff03f | | the K053936's control words |
| fff044-fff047 | | MAME: ignored ("moves during race"); the core ignores it too |

Anything else reads 0 (MAME's unmapped value) and ignores writes. IRQ 1 (autovectored) at every vblank, held until acknowledged
(MAME's `irq1_line_hold`).

P1 (active low): 0 up, 1 down, 2 left, 3 right, 4 button 1 (**Accel**), 5 button 2 (**Brake**), 6 button 3 (unused by the game
as far as MAME's play shows; the core leaves it released), 8 / 9 / 10 coins 1 / 2 / 3, 11 / 12 start 1 / 2, 13 test, 14 tilt, 15
service. P2: the second player's joystick and buttons in bits 7:0.

## The Z80's maps

| address | |
|---|---|
| 0000-77ff | ROM |
| 7800-7fff | RAM (2 KB) |
| 8000-ffff | a 32 KB bank of the 128 KB ROM (the bank register's bits 1:0) |

| port | read | write |
|---|---|---|
| 00 | | the bank |
| 04 | the sound latch | its acknowledge (clears the pending flag) |
| 08-0b | the YM2610 | the YM2610 |

The NMI is the latch's pending flag: reading the latch does not clear it, only the write to port 04 does. The IRQ (IM 1) is the
YM2610's.

## The ROM image

`tools/crshrace_rom.py` builds it by MAME's loading rules; the MRAs assemble the same bytes (`tools/make_mra.py` checks them). MAME's
regions one after the other, in MAME's byte order (the ROM_LOAD16_WORD_SWAP files swapped back, so a word's high byte is the even
byte), the same layout for every set:

| offset | region | size | |
|---|---|---|---|
| 0x000000 | maincpu | 512 KB | 1.ic10 / 01.ic10 |
| 0x080000 | user1 | 1 MB | w21.ic14 |
| 0x180000 | user2 | 1 MB | w22.ic13 |
| 0x280000 | audiocpu | 128 KB | 2.ic58 |
| 0x2A0000 | chars | 1 MB | h895.ic50 (8 x 8 x 8 raw) |
| 0x3A0000 | tiles | 3 MB | w18.rom-a, w19.rom-b, w20.rom-c (16 x 16 x 4 packed, msb first; MAME's region is 4 MB, the last quarter empty) |
| 0x6A0000 | sprites | 4 MB | h897.ic29, h896.ic75 (16 x 16 x 4 packed, lsb first) |
| 0xAA0000 | adpcmb | 1 MB | h894.ic73 |
| 0xBA0000 | adpcma | 1 MB | h893.ic69 |
| 0xCA0000 | (end: 12.6 MB) | | |

Everything lives in the SDRAM (`rtl/crshrace_loader.sv`): the CPUs' ROMs at their image offsets, the chars at 0x400000, the tiles
at 0x800000 (rearranged into 4 x 4 pixel blocks, so the K053936 layer reads a block with one burst at any angle), the sprites at
0xC00000, ADPCM-A at 0x1000000, ADPCM-B at 0x1100000.

## The video

**The layers.**

* The **char layer** (MAME's `m_tilemap[1]`): 64 x 64 tiles of 8 x 8 x 8, never scrolled, so only the top left 40 x 28 tiles are
  ever seen; a tile is one VRAM 1 word (its code); the pen is the palette entry; pen 0xff is transparent.
* The **K053936 layer** (`m_tilemap[0]`, drawn by `k053936_device::zoom_draw` in its "simple" mode, the only one the game uses):
  64 x 64 tiles of 16 x 16 x 4 (1,024 x 1,024 pixels, wrapping); a tile is one VRAM 0 word, its code plus the tile bank x 0x1000,
  its colour (palette 0x100 + colour x 16); pen 15 is transparent. Each bitmap pixel (x, y) is the tilemap's pixel at
  cx = 256 ctrl[0] + 21 incyx + 48 incxx + y incyx + x incxx (and cy alike), in 1/2048 pixel steps (`set_offsets(-48, -21)`).
* The **sprites** (`vsystem_spr_device::draw_sprites`): a list of up to 512 entries in sprite RAM 0 pointing at four attribute
  words each; a sprite is (ysize + 1) x (xsize + 1) blocks of a 16 x 16 tile, zoomed by (32 - zoom) / 32, flipped in x and y; its
  n-th block takes its tile from the VS9210's table (sprite RAM 1) at map + n; colour 0x200 + colour x 16; pen 15 transparent; later
  blocks cover earlier ones; positions wrap at 512.

**The mix** (`screen_update`, by gfxctrl & 0xfb): 0x00 (the high score screen) the sprites, then the char layer, then the K053936
layer on top; 0x01 / 0x02 the char layer, the K053936 layer, then the sprites on top; anything else none of them; all over palette
entry 0x1ff; gfxctrl bit 2 makes the picture black.

**When.** MAME draws the whole frame at the start of the vblank from the state of that instant, and then copies both sprite RAMs
into their buffers (`buffered_spriteram16_device`), so the sprites a frame shows are the RAMs as they were at the vblank before. The
core does the same: at the vblank its live copies of the video memories and registers are copied into display copies (8,192
clocks, 85 us, 64 bits a clock; a 68000 write to an entry the copy has not reached yet waits for it, and the CPU gets the cycles
back right after), the sprite RAMs into one of two buffers each, and the next frame is drawn from them, a line at a time during the
line before it, into a line buffer per layer, mixed and looked up in the palette as the beam runs.

**The palette.** xGBR_555: red in bits 4:0, blue in 9:5, green in 14:10, each widened to 8 bits as MAME's `pal5bit` does.

## The core's timing

**The raster.** MAME's screen has no blanking times of the board; the core draws MAME's 320 x 224 picture on a standard 15 kHz
240p raster of its own: 263 lines of 406 dots of 15 clocks of 96 MHz (a 6.4 MHz dot; 6,090 clocks a line, 15.76 kHz; 59.94 Hz),
every line the same: the 224 picture lines, 8 lines of border, 3 of front porch, 3 of vsync and 25 to the next picture (8 of them
its top border). The vblank (the 68000's IRQ 1) begins at line 224. So the game runs 0.1 % slower than MAME's 60 Hz.

**The CPUs on MAME's timeline.** One 96 MHz clock. The 68000 (fx68k) gets a pair of phase enables every 3 clocks (16 MHz); the Z80
(tv80) a step every 24 clocks (4 MHz); the YM2610 (jt10) a clock enable every 12 (8 MHz). MAME's memory is instant; the core's ROMs
are in the SDRAM behind caches. When the CPU would take data that is not there yet (a cache miss), or a write has to wait for the
vblank copy, its clock enables are held and the cycles it missed are given back right after, faster than its own speed (the 68000
a phase every 2 clocks, the Z80 a step every 8), so its program stays on MAME's timeline; an interrupt raised meanwhile reaches it
after the cycles it still owes.

**The YM2610's ROMs.** jt10 asks for an ADPCM byte by its address; the core fetches the byte from the SDRAM whenever that address
changes, a microsecond or more before the chip takes it.

**The sound mix.** MAME's: the FM and the ADPCM left and right at 1.0, the SSG at 0.75 to both. jt10's SSG output (10 bits,
unsigned) is taken at 16 x with its DC removed (a first-order high-pass at about 9 Hz).

## The platform

| | |
|---|---|
| Flip Screen | The OSD's: the renderer draws line y from MAME's row 223 - y and reads each line out from its end: MAME's picture turned 180 degrees, on the analog output and HDMI alike. Not applied while the OSD's Service Mode (the board's SW2:4) is on: the test screens are drawn for the upright cabinet. The game's own Flip Screen DIP (SW2:1) is held Off: MAME does not flip this game (`MACHINE_NO_COCKTAIL`, "TODO: handle screen flip correctly") |
| Orientation | The framework's `screen_rotate` (`MISTER_FB`): the picture written turned 90 degrees counter-clockwise into a frame buffer in the DDR3 and scanned out upright for HDMI. Horz: the board's picture as it is, for a monitor on its side. The analog output is always the board's |
| CRT Adjust | rmonic79's module (`modules/crt-adjust`), with a 10-bit line buffer for the 406-dot line and V-Shift counting 263 lines |
| Fast load | The MRA's `address=`: Main_MiSTer copies the 12.6 MB image into the DDR3 at 0x32000000, `rtl/crshrace_fastload.sv` reads it back into the loader. The DDR3 port is the fast load's while it runs and `screen_rotate`'s otherwise |
| DIP switches | The MRA's `<switches>` (ioctl index 254): byte 0 SW2 (DSW0 bits 7:0), byte 1 SW1 (DSW0 bits 15:8), byte 2 SW3 (DSW1), byte 3 the region (DSW2 bits 11:8: World, USA & Canada, Japan, Korea, Hong Kong & Taiwan) |
