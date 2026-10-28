#!/bin/sh
# Verilator lint of the machine and the platform modules: sim/lint.sh [max lines] (the vendored modules are waived, waivers.vlt)
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
M=../modules
verilator --lint-only -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-UNUSEDPARAM -Wno-SYNCASYNCNET \
    -Wno-TIMESCALEMOD waivers.vlt -I../rtl -I$M/fx68k -I$M/jt12/hdl --top-module crshrace_core \
    ../rtl/crshrace_core.sv ../rtl/crshrace_ram.sv ../rtl/crshrace_video.sv ../rtl/crshrace_chars.sv ../rtl/crshrace_roz.sv \
    ../rtl/crshrace_sprites.sv ../rtl/crshrace_sound.sv ../rtl/crshrace_cache.sv \
    $M/fx68k/fx68k.sv $M/fx68k/fx68kAlu.sv $M/fx68k/uaddrPla.sv \
    $M/jt12/hdl/jt10*.v $M/jt12/hdl/jt12*.v $M/jt12/hdl/adpcm/*.v $M/jt12/hdl/mixer/*.v $M/jt49/hdl/*.v \
    +define+TV80_REFRESH $M/cpu-tv80/tv80s_cen.v $M/cpu-tv80/tv80_core.v $M/cpu-tv80/tv80_alu.v $M/cpu-tv80/tv80_mcode.v \
    $M/cpu-tv80/tv80_reg.v 2>&1 | grep -E "^%(Error|Warning)" | head -${1:-80}
echo "--- loader, sdram, fastload"
for m in crshrace_loader crshrace_sdram crshrace_fastload; do
    verilator --lint-only -Wall -Wno-fatal -Wno-DECLFILENAME --top-module $m ../rtl/$m.sv 2>&1 | grep -E "^%(Error|Warning)" | head -${1:-40}
done
