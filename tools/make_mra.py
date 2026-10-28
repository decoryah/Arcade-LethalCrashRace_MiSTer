#!/usr/bin/env python3
"""Writes the Crash Race MRAs (mra/*.mra) from MAME 0.289's ROM lists and input ports (src/mame/vsystem/crshrace.cpp).

    python3 tools/make_mra.py <crshrace.zip>

The romset (MAME 0.289's merged crshrace.zip, the clones' files in crshrace2/ and crshrace2a/) is needed for the md5 each MRA
carries (MiSTer's: of the parts' bytes as it reads them, before the interleave; it does not load a ROM whose md5 does not match).
Every MRA is assembled by tools/mra_build.py and compared with the image tools/crshrace_rom.py builds by MAME's loading rules; they
must be identical. The layout is rtl/crshrace_loader.sv's.
"""
import os, sys, hashlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..')
sys.path.insert(0, HERE)

SWITCHES = '''    <!--
      DIP switches (ioctl index 254), a 1 is "off", bit for bit as MAME reads them: byte 0 is DSW0's bits 7:0 (SW2), byte 1 its bits
      15:8 (SW1), byte 2 DSW1 (SW3), byte 3 the region (DSW2's bits 11:8; a board setting, not a switch). MAME's defaults: FF, FF,
      FF, 01. The game's Flip Screen switch (SW2:1) is the OSD's Flip Screen and its service switch (SW2:4) the OSD's Service Mode.
    -->
    <switches default="FF,FF,FF,01" base="16">
        <dip bits="1"     name="Demo Sounds" ids="Off,On"/>
        <dip bits="2"     name="Free Play" ids="On,Off"/>
        <dip bits="6,7"   name="Difficulty" ids="Hardest,Hard,Easy,Normal"/>
        <dip bits="8"     name="Coin Slot" ids="Individual,Same"/>
        <dip bits="9,11"  name="Coin A" ids="1C/6C,1C/5C,1C/4C,1C/3C,1C/2C,3C/1C,2C/1C,1C/1C"/>
        <dip bits="12,14" name="Coin B (Coin Slot: Same)" ids="1C/6C,1C/5C,1C/4C,1C/3C,1C/2C,3C/1C,2C/1C,1C/1C"/>
        <dip bits="15"    name="2 to Start, 1 to Cont." ids="On,Off"/>
        <dip bits="23"    name="Reset on P.O.S.T. Error" ids="No,Yes"/>
        <dip bits="24,27" name="Region" ids="Japan,World,Korea,Hong Kong &amp; Taiwan,USA &amp; Canada" values="0,1,2,4,8"/>
    </switches>'''

TEMPLATE = '''<misterromdescription>
    <name>{name}</name>
    <setname>{setname}</setname>
    <mameversion>0289</mameversion>
    <year>1993</year>
    <manufacturer>Video System Co.</manufacturer>
    <players>2</players>
    <joystick>8</joystick>
    <rotation>vertical (ccw)</rotation>
    <rbf>crashrace</rbf>
    <platform>Crash Race</platform>

    <!--
      The image of the Crash Race core (rtl/crshrace_loader.sv, tools/crshrace_rom.py), MAME's regions in MAME's byte order (the
      ROM_LOAD16_WORD_SWAP ROMs swapped back by a one-part interleave), the same layout for every set:
        0x000000  0x080000  maincpu    the 68000's program
        0x080000  0x100000  user1      its data ROM at 300000
        0x180000  0x100000  user2      its data ROM at 400000
        0x280000  0x020000  audiocpu   the Z80's program and its banks
        0x2A0000  0x100000  chars      the 8 x 8 x 8 char layer
        0x3A0000  0x300000  tiles      the K053936 layer's 16 x 16 tiles
        0x6A0000  0x400000  sprites    the sprites
        0xAA0000  0x100000  adpcmb     the YM2610's ADPCM-B samples
        0xBA0000  0x100000  adpcma     its ADPCM-A samples
      Expects the MAME 0.289 merged romset or the split sets: parts are found by name and CRC. The md5 is MiSTer's (of the parts'
      bytes as read, before the interleave; the image itself is {img_md5}).
      address= is the fast load: a recent Main_MiSTer copies the image into the DDR3 at that byte and the core reads it from there
      (rtl/crshrace_fastload.sv); an older one streams it.
    -->

{switches}

    <!-- the buttons as the game names them (MAME's notes and the cabinet's panel): button 1 accelerates, button 2 brakes -->
    <buttons names="Accel,Brake,Start,Coin" default="A,B,Start,Select"/>

    <rom index="0" zip="{zips}" md5="{md5}" address="0x32000000">
{parts}
    </rom>
</misterromdescription>
'''


def common(sound_crc):
    return [
        ('user1', 'w21.ic14', 'a5df7325', True),
        ('user2', 'w22.ic13', 'fc9d666d', True),
        ('audiocpu', '2.ic58', sound_crc, False),
        ('chars', 'h895.ic50', '36ad93c3', False),
        ('tiles', 'w18.rom-a', 'b15df90d', True),
        ('tiles', 'w19.rom-b', '28326b93', True),
        ('tiles', 'w20.rom-c', 'd4056ad1', True),
        ('sprites', 'h897.ic29', 'e3230128', False),
        ('sprites', 'h896.ic75', 'fff60233', False),
        ('adpcmb', 'h894.ic73', 'd53300c1', False),
        ('adpcma', 'h893.ic69', '32513b63', False),
    ]


SETS = [
    dict(setname='crshrace', name='Lethal Crash Race (set 1)', zips='crshrace.zip',
         parts=[('maincpu', '1.ic10', '21e34fb7', True)] + common('e70a900f')),
    dict(setname='crshrace2', name='Lethal Crash Race (set 2)', zips='crshrace2.zip|crshrace.zip',
         parts=[('maincpu', '01.ic10', 'b284aacd', True)] + common('e70a900f')),
    dict(setname='crshrace2a', name='Lethal Crash Race (set 2, alternate sound ROM)', zips='crshrace2a.zip|crshrace.zip',
         parts=[('maincpu', '01.ic10', 'b284aacd', True)] + common('7ef4f9dc')),
]


def parts_text(parts):
    out = []
    for label, name, crc, swapped in parts:
        if swapped:
            out.append(f'        <!-- {label} (ROM_LOAD16_WORD_SWAP: the bytes of each word swapped) -->')
            out.append('        <interleave output="16">')
            out.append(f'            <part name="{name}" crc="{crc}" map="12"/>')
            out.append('        </interleave>')
        else:
            out.append(f'        <!-- {label} -->')
            out.append(f'        <part name="{name}" crc="{crc}"/>')
    return '\n'.join(out)


def mra_text(s, md5, img_md5):
    return TEMPLATE.format(name=s['name'], setname=s['setname'], zips=s['zips'], md5=md5, img_md5=img_md5,
                           switches=SWITCHES, parts=parts_text(s['parts']))


def path_of(s):
    if s['setname'] == 'crshrace':
        return os.path.join(ROOT, 'mra', f"{s['name']}.mra")
    return os.path.join(ROOT, 'mra', '_alternatives', '_Crash Race', f"{s['name']}.mra")


def main():
    if len(sys.argv) != 2 or not os.path.isfile(sys.argv[1]):         # before anything overwrites the MRAs
        sys.exit(__doc__)
    import crshrace_rom, mra_build
    z = sys.argv[1]
    for s in SETS:
        p = path_of(s)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        # first without the md5, to compute it the way MiSTer does; then with it, and check
        open(p, 'w', newline='\n').write(mra_text(s, 'None', '?'))
        img, md5 = mra_build.build(p, z)
        img_md5 = hashlib.md5(img).hexdigest()
        open(p, 'w', newline='\n').write(mra_text(s, md5, img_md5))
        img2, md5b = mra_build.build(p, z)
        ref = bytes(crshrace_rom.build(z, s['setname']))
        ok = (img2 == ref) and (md5b == md5)
        print(f"wrote {os.path.relpath(p, ROOT)}: image {len(img2):#x} bytes, md5 {img_md5}, MiSTer's md5 {md5}: "
              + ('identical to crshrace_rom.py' if ok else 'DIFFERS from crshrace_rom.py'))
        if not ok:
            sys.exit(f'{sum(1 for i in range(min(len(img2), len(ref))) if img2[i] != ref[i])} bytes differ, lengths {len(img2)} / {len(ref)}')


if __name__ == '__main__':
    main()
