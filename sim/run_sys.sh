#!/bin/sh
# The whole-machine bench: crshrace_core behind crshrace_sdram and a behavioural SDRAM, the image downloaded through crshrace_loader.
#   sim/run_sys.sh <crshrace.rom> <frames> <out prefix> [+FLIP]
# (tools/crshrace_rom.py <crshrace.zip> crshrace x.rom makes the image.) Environment: see sim/tb_crshrace.cpp (SNAPEVERY, SNAPFRAMES,
# SCHED, AUDIO, TRACE); REBUILD=1 rebuilds the model; THREADS=n.
set -e
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
IMG="$1"
[ -f "$IMG" ] && [ -n "$2" ] && [ -n "$3" ] || { echo "usage: $0 <crshrace.rom> <frames> <prefix>" >&2; exit 2; }
OBJ=${OBJ:-obj_sys}
M=../modules
if [ ! -x $OBJ/Vtb_top ] || [ -n "$REBUILD" ]; then
ln -sf ../modules/fx68k/microrom.mem ../modules/fx68k/nanorom.mem . 2>/dev/null || [ -e microrom.mem ]
verilator --cc --exe --build -j ${JOBS:-16} -O3 --no-assert ${THREADS:+--threads $THREADS} -CFLAGS "-O2 -march=native" -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME \
    -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE \
    -Wno-MULTIDRIVEN -Wno-LATCH -Wno-UNSIGNED -Wno-CMPCONST -Wno-PROCASSINIT -Wno-SYNCASYNCNET -Wno-BLKSEQ -Wno-ALWCOMBORDER \
    -Wno-INITIALDLY -Wno-COMBDLY -Wno-ASCRANGE -Wno-SELRANGE -Wno-ENUMVALUE \
    waivers.vlt $VFLAGS -I../rtl -I$M/fx68k -I$M/jt12/hdl --top-module tb_top --prefix Vtb_top -Mdir $OBJ \
    ../rtl/crshrace_core.sv ../rtl/crshrace_ram.sv ../rtl/crshrace_video.sv ../rtl/crshrace_chars.sv ../rtl/crshrace_roz.sv \
    ../rtl/crshrace_sprites.sv ../rtl/crshrace_sound.sv ../rtl/crshrace_cache.sv ../rtl/crshrace_sdram.sv ../rtl/crshrace_loader.sv \
    $M/fx68k/fx68k.sv $M/fx68k/fx68kAlu.sv $M/fx68k/uaddrPla.sv \
    +define+TV80_REFRESH $M/cpu-tv80/tv80s_cen.v $M/cpu-tv80/tv80_core.v $M/cpu-tv80/tv80_alu.v $M/cpu-tv80/tv80_mcode.v $M/cpu-tv80/tv80_reg.v \
    $M/jt12/hdl/jt10*.v $M/jt12/hdl/jt12*.v $M/jt12/hdl/adpcm/*.v $M/jt12/hdl/mixer/*.v $M/jt49/hdl/*.v \
    sdram_model.sv tb_top.sv tb_crshrace.cpp > $OBJ.log 2>&1 || { grep -E "%Error" $OBJ.log | head -40; tail -20 $OBJ.log; exit 1; }
fi
mkdir -p "$(dirname "$3")"
PRE="$3"; FR="$2"; shift 3
./$OBJ/Vtb_top +IMAGE="$IMG" "$@" "$FR" "$PRE"
