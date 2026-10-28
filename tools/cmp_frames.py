#!/usr/bin/env python3
"""cmp_frames.py [--lag n] <mame dir> <bench prefix> [frames a,b,c]: the system bench's pictures (<prefix>.f<n>.ppm, 320 x 224 as
the board makes them) against MAME's snapshots (<mame dir>/snap_<nnnnn>.png, tools/lua/probe.lua or snap.lua; 224 x 320, MAME's
ROT270 applied): the bench's picture is turned 90 degrees counter-clockwise first, as MAME turns it. --lag n: the bench's frame f
against MAME's f + n (MAME's frame_done count runs one ahead of the bench's labels in some stretches). By default every picture
the bench wrote that MAME has. A dot differs when a channel differs by more than 8 (MAME's pal5bit and the core's agree exactly;
the margin is for PNG tools that dither).

cmp_frames.py --rot180 <prefix a> <prefix b> [frames]: the bench's pictures b (with +FLIP) against a's (without) turned 180
degrees: the Flip Screen's check."""
import sys, os, re, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio


def ppm(p):
    d = open(p, 'rb').read()
    parts = d.split(b'\n', 3)
    w, h = map(int, parts[1].split())
    return w, h, parts[3]


def rot_ccw(w, h, px):
    out = bytearray()
    for y in range(w):
        for x in range(h):
            i = (x * w + (w - 1 - y)) * 3
            out += px[i:i + 3]
    return h, w, bytes(out)


def frames_of(pre, have=lambda f: True):
    fr = sorted(int(re.search(r'\.f(\d+)\.ppm$', p).group(1)) for p in glob.glob(pre + '.f*.ppm'))
    return [f for f in fr if have(f)]


def main():
    args = sys.argv[1:]
    if args and args[0] == '--rot180':
        pa, pb = args[1], args[2]
        fr = [int(x) for x in args[3].split(',')] if len(args) > 3 else frames_of(pb, lambda f: os.path.exists(f'{pa}.f{f}.ppm'))
        same = 0
        for f in fr:
            w, h, a = ppm(f'{pa}.f{f}.ppm')
            _, _, b = ppm(f'{pb}.f{f}.ppm')
            n = sum(1 for i in range(w * h) if a[i * 3:i * 3 + 3] != b[(w * h - 1 - i) * 3:(w * h - 1 - i) * 3 + 3])
            print(f'frame {f}: {n} of {w * h} dots differ from the 180-degree turn')
            same += n == 0
        print(f'{same} of {len(fr)} identical')
        return 0 if same == len(fr) else 1
    lag = 0
    if args and args[0] == '--lag':
        lag = int(args[1])
        args = args[2:]
    mdir, pre = args[0], args[1]
    snap = lambda f: os.path.join(mdir, f'snap_{f + lag:05d}.png')
    fr = [int(x) for x in args[2].split(',')] if len(args) > 2 else frames_of(pre, lambda f: os.path.exists(snap(f)))
    same = 0
    for f in fr:
        w, h, a = rot_ccw(*ppm(f'{pre}.f{f}.ppm'))
        mw, mh, b = pngio.read(snap(f))[:3]
        assert (w, h) == (mw, mh), ((w, h), (mw, mh))
        bpp = len(b) // (w * h)
        rows = {}
        n = 0
        for i in range(w * h):
            pa, pb = a[i * 3:i * 3 + 3], b[i * bpp:i * bpp + 3]
            if max(abs(pa[k] - pb[k]) for k in range(3)) > 8:
                n += 1
                rows[i // w] = rows.get(i // w, 0) + 1
        worst = sorted(rows.items(), key=lambda r: -r[1])[:6]
        print(f'frame {f} (MAME {f + lag}): {n} of {w * h} dots differ' + (f'; rows with most: {worst}' if n else ''))
        same += n == 0
    print(f'{same} of {len(fr)} identical')
    return 0 if same == len(fr) else 1


if __name__ == '__main__':
    sys.exit(main())
