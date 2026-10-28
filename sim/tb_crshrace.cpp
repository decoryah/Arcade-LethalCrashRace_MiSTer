// The whole-machine bench's driver: sim/run_sys.sh builds it.
//   Vtb_top +IMAGE=<crshrace.rom> [+FLIP] <frames> <out prefix>
// Environment: SNAPEVERY=n (a picture every n frames), SNAPFRAMES=a,b,c, SCHED=coin|play (the scripted inputs),
// AUDIO=1 (<prefix>.wav, 48 kHz stereo, the core's 16-bit output), TRACE=1 (a line per frame).
// Pictures are written as <prefix>.f<frame>.ppm (320 x 224): frame f is the picture drawn from the vblank of frame f (MAME's
// snapshot of frame f: MAME draws it at that vblank), which the raster shows in the frame after it.
#include "Vtb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <set>
#include <string>
#include <vector>

static std::set<int> parse_list(const char *s) {
    std::set<int> r;
    if (!s) return r;
    const char *p = s;
    while (*p) { r.insert(atoi(p)); while (*p && *p != ',') p++; if (*p) p++; }
    return r;
}

static const int W = 320, H = 224;

static void write_ppm(const std::string &fn, const std::vector<uint8_t> &fb) {
    FILE *f = fopen(fn.c_str(), "wb");
    if (!f) return;
    fprintf(f, "P6\n%d %d\n255\n", W, H);
    fwrite(fb.data(), 1, fb.size(), f);
    fclose(f);
}

// The scripted inputs: MAME's P1 / P2 ports (active low): 0 up, 1 down, 2 left, 3 right, 4 Accel, 5 Brake, 8 coin 1, 11 start 1.
// SCHED=play, the same as work/lua/probe.lua's (MAME's): a coin at frame 600, start 1 at 700, Accel held from 800, left held
// from 1200 one second in three. (The game ignores coins during its power-on test, until about frame 320.)
struct In { uint16_t p1; uint8_t p2; };
static In sched_in(const char *sched, int f) {
    In in = {0xffff, 0xff};
    if (!sched) return in;
    if (f >= 600 && f < 606) in.p1 &= ~0x0100;             // coin 1
    if (f >= 700 && f < 706) in.p1 &= ~0x0800;             // start 1
    if (f >= 800) in.p1 &= ~0x0010;                        // Accel
    if (f >= 1200 && (f / 60) % 3 == 0) in.p1 &= ~0x0004;  // left
    return in;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::vector<const char *> pos;
    for (int i = 1; i < argc; i++) if (argv[i][0] != '+') pos.push_back(argv[i]);
    if (pos.size() < 2) { fprintf(stderr, "usage: Vtb_top +IMAGE=<file> <frames> <out prefix>\n"); return 2; }
    int frames = atoi(pos[0]);
    std::string pre = pos[1];
    int snap_every = getenv("SNAPEVERY") ? atoi(getenv("SNAPEVERY")) : 0;
    std::set<int> snaps = parse_list(getenv("SNAPFRAMES"));
    const char *sched = getenv("SCHED");
    bool audio = getenv("AUDIO") && atoi(getenv("AUDIO"));
    bool trace = getenv("TRACE") && atoi(getenv("TRACE"));
    int lagfrom = 1 << 30;                                      // +LAG=<frame> (sim/tb_top.sv): from there frames are numbered one ahead
    for (int i = 1; i < argc; i++) if (!strncmp(argv[i], "+LAG=", 5)) lagfrom = atoi(argv[i] + 5);

    Vtb_top *top = new Vtb_top;
    std::vector<uint8_t> fb(W * H * 3, 0);
    std::vector<int16_t> wav;
    int x = 0, y = 0, frame = 0, shown = -1;
    bool prev_hb = true, line_had = false, prev_vb = true;
    uint64_t cyc = 0, run_at = 0;
    In in = sched_in(nullptr, 0);
    top->in_p1 = in.p1; top->in_p2 = in.p2;

    top->reset_in = 1;
    for (int i = 0; i < 20; i++) { top->clk = 0; top->eval(); top->clk = 1; top->eval(); }
    top->reset_in = 0;

    while (!Verilated::gotFinish()) {
        bool ce = top->ce_pix;
        bool ft = top->frame_tick;
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
        cyc++;
        if (!top->running) { run_at = cyc; continue; }
        if (audio && ((cyc - run_at) % 2000) == 0) {
            
            wav.push_back(top->audio_l); wav.push_back(top->audio_r);
        }
        if (ft) {
            if (trace) printf("F %d cyc %llu a %06x\n", frame, (unsigned long long)(cyc - run_at), top->dbg_pc);
            // frame_done of this frame: MAME's Lua sets the inputs of sched(frame) here
            int lbl = frame >= lagfrom ? frame + 1 : frame;
            in = sched_in(sched, lbl);
            top->in_p1 = in.p1; top->in_p2 = in.p2;
            // the picture just shown (lines 0-255 before this vblank) was drawn from the vblank before
            if (shown >= 0 && ((snap_every && shown % snap_every == 0) || snaps.count(shown)))
                write_ppm(pre + ".f" + std::to_string(shown) + ".ppm", fb);
            shown = lbl;                // the raster now shows the picture drawn from this vblank
            frame++;
            if (frame > frames) break;
        }
        if (ce) {
            // the outputs of this dot appeared at this edge
            bool hb = top->hblank, vb = top->vblank;
            prev_vb = vb;
            if (vb) { y = 0; x = 0; line_had = false; }
            else if (!hb) {
                if (x < W && y < H) {
                    uint8_t *p = &fb[(y * W + x) * 3];
                    p[0] = top->r; p[1] = top->g; p[2] = top->b;
                }
                x++; line_had = true;
            } else if (!prev_hb && line_had) { y++; x = 0; line_had = false; }
            prev_hb = hb;
        }
    }
    if (audio) {
        FILE *f = fopen((pre + ".wav").c_str(), "wb");
        if (f) {
            uint32_t n = wav.size() * 2, rate = 48000, br = rate * 4;
            fwrite("RIFF", 1, 4, f); uint32_t v = 36 + n; fwrite(&v, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
            v = 16; fwrite(&v, 4, 1, f); uint16_t s = 1; fwrite(&s, 2, 1, f); s = 2; fwrite(&s, 2, 1, f);
            fwrite(&rate, 4, 1, f); fwrite(&br, 4, 1, f); s = 4; fwrite(&s, 2, 1, f); s = 16; fwrite(&s, 2, 1, f);
            fwrite("data", 1, 4, f); fwrite(&n, 4, 1, f); fwrite(wav.data(), 2, wav.size(), f); fclose(f);
        }
    }
    top->final();
    printf("done: %d frames, %llu clocks\n", frame, (unsigned long long)cyc);
    delete top;
    return 0;
}
