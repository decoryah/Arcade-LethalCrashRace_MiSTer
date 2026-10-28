#!/usr/bin/env python3
"""Builds the Crash Race core's ROM image from a MAME 0.289 romset by MAME's loading rules (src/mame/vsystem/crshrace.cpp).

    python3 tools/crshrace_rom.py <crshrace.zip> <set> <out.rom>        (set: crshrace, crshrace2 or crshrace2a)

The layout is rtl/crshrace_loader.sv's: MAME's regions one after the other, in MAME's byte order (the ROM_LOAD16_WORD_SWAP
files' bytes swapped back, so a 16-bit word's high byte is the even byte). Parts are found by CRC (a merged romset keeps the clones'
files with the same names in subfolders). tools/make_mra.py checks every MRA against this.
"""
import sys, zipfile, zlib

# (region, file, crc, word swapped)
MAIN = {'crshrace': ('1.ic10', '21e34fb7'), 'crshrace2': ('01.ic10', 'b284aacd'), 'crshrace2a': ('01.ic10', 'b284aacd')}
SOUND = {'crshrace': 'e70a900f', 'crshrace2': 'e70a900f', 'crshrace2a': '7ef4f9dc'}


def layout(setname):
    m = MAIN[setname]
    return [
        ('maincpu',  m[0],        m[1],       True),
        ('user1',    'w21.ic14',  'a5df7325', True),
        ('user2',    'w22.ic13',  'fc9d666d', True),
        ('audiocpu', '2.ic58',    SOUND[setname], False),
        ('chars',    'h895.ic50', '36ad93c3', False),
        ('tiles',    'w18.rom-a', 'b15df90d', True),
        ('tiles',    'w19.rom-b', '28326b93', True),
        ('tiles',    'w20.rom-c', 'd4056ad1', True),
        ('sprites',  'h897.ic29', 'e3230128', False),
        ('sprites',  'h896.ic75', 'fff60233', False),
        ('adpcmb',   'h894.ic73', 'd53300c1', False),
        ('adpcma',   'h893.ic69', '32513b63', False),
    ]


def build(zpath, setname):
    by_crc = {}
    with zipfile.ZipFile(zpath) as z:
        for info in z.infolist():
            by_crc[f'{info.CRC:08x}'] = z.read(info)
    img = bytearray()
    for region, name, crc, swapped in layout(setname):
        if crc not in by_crc:
            sys.exit(f'error: {name} (crc {crc}, {region}) is not in {zpath}')
        data = bytearray(by_crc[crc])
        if zlib.crc32(data) & 0xffffffff != int(crc, 16):
            sys.exit(f'error: {name}: bad crc')
        if swapped:
            data[0::2], data[1::2] = data[1::2], data[0::2]
        img += data
    assert len(img) == 0xCA0000, hex(len(img))
    return img


if __name__ == '__main__':
    if len(sys.argv) != 4 or sys.argv[2] not in MAIN:
        sys.exit(__doc__)
    open(sys.argv[3], 'wb').write(build(sys.argv[1], sys.argv[2]))
