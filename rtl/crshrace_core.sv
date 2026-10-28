//------------------------------------------------------------------------------
// Lethal Crash Race (Video System, 1993; VSEC-24): the machine, written from MAME 0.289's src/mame/vsystem/crshrace.cpp.
//
//   MC68000 at 16 MHz (fx68k; MAME: "16 MHz ???", the board has 32 and 24 MHz crystals); the sound board (rtl/crshrace_sound.sv:
//   Z80, YM2610); the video (rtl/crshrace_video.sv: the 8 x 8 char layer, the K053936 layer, the VS9108 / VS9210 sprites, the
//   palette).
//
// The 68000's memory map (MAME's main_map; anything else reads 0, MAME's unmapped value, and ignores writes):
//   000000-07ffff ROM (512 KB)            300000-3fffff user1 ROM (1 MB)    400000-4fffff user2 ROM (1 MB), mirrored at 500000-5fffff
//   a00000-a0ffff sprite RAM 1 (the VS9210's tile table, 32 K words)        d00000-d01fff VRAM 0 (the K053936 layer, 64 x 64 tiles)
//   e00000-e01fff sprite RAM 0 (the VS9108's list and attributes)           fe0000-feffff RAM
//   ffc001        the K053936 layer's tile bank (write)                     ffd000-ffdfff VRAM 1 (the char layer, 64 x 32 of 64 x 64)
//   ffe000-ffefff palette (2,048 words, xGGGGGBBBBBRRRRR)
//   fff000 P1 (read) / fff001 gfxctrl (write)     fff002 P2     fff004 DSW0     fff006 DSW2 (bit 15: the sound latch's pending flag)
//   fff009 the sound latch (write)                fff00a DSW1   fff00e P3       fff020-fff03f the K053936's control words (write)
// IRQ 1 (autovectored) at every vblank, held until acknowledged (MAME's irq1_line_hold).
//
// Clocking and MAME's timeline (the owner's Aquarium core's scheme, unchanged): one 96 MHz clock. The 68000's clock is a pair of
// phase enables (fx68k's enPhi1 / enPhi2), one every 3 clocks (32 MHz: the CPU at 16 MHz). MAME's memory is instant and has no wait
// states; here the ROMs are read through a cache from the SDRAM (rtl/crshrace_cache.sv) and the video memories are copied at the
// vblank (a CPU write to an entry not yet copied waits for it). DTACK is always asserted at once; where the data is not there yet
// when the CPU would take it, or a write has to wait, the CPU's phases are held, and the phases it missed are given back right
// after, at one every 2 clocks, so its program stays on MAME's timeline. The IRQ, raised while the CPU is behind, reaches it after
// the phases it owes.
//------------------------------------------------------------------------------
`default_nettype none

module crshrace_core (
    input  logic        clk,            // 96 MHz
    input  logic        rst_raster,     // the raster's power-up reset
    input  logic        reset,          // the machine's (a ROM load, the OSD's reset)
    input  logic        flip,           // the OSD's Flip Screen (the picture turned 180 degrees; taken at a vblank)

    // SDRAM read clients: 0 the 68000's ROM cache, 1 the Z80's ROM cache, 2 ADPCM-A, 3 ADPCM-B, 4 chars, 5 K053936, 6 sprites
    output logic        m_req   [7],
    output logic [23:0] m_addr  [7],
    output logic  [4:0] m_len   [7],
    input  logic        m_ack   [7],
    input  logic        m_valid [7],
    input  logic [15:0] m_rdata,

    // MAME's input ports, as read (active low where MAME's are; DSW2's bit 15, the latch's pending flag, is the board's)
    input  logic [15:0] in_p1,
    input  logic  [7:0] in_p2,
    input  logic  [7:0] in_p3,
    input  logic [15:0] dsw0,
    input  logic  [7:0] dsw1,
    input  logic  [3:0] region,         // DSW2 bits 11:8

    output logic        ce_pix,
    output logic        hs,
    output logic        vs,
    output logic        hblank,
    output logic        vblank,
    output logic        vblank_next,
    output logic  [7:0] r,
    output logic  [7:0] g,
    output logic  [7:0] b,

    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,

    output logic        running,        // the CPUs run
    output logic        frame_tick,     // one clock at each vblank while running (MAME's frame_done)
    output logic [23:0] dbg_pc
);
    // ================================================================== the start
    // MAME's screen begins at the start of a vblank at time 0 without its callbacks; its first vblank (the IRQ, the sprite buffers,
    // frame_done 0) is a frame later. The CPUs start START_EARLY clocks before a vblank of the raster (from vbl_pre, a frame after the
    // vblank that arms the start), which is then the time-0 vblank and is skipped; the next one is frame 0. (The Aquarium core's
    // measured lead of the core's 68000 over MAME's bus timing.)
    localparam int START_EARLY = 32;
    logic        vbl_ev, vbl_raw, vbl_pre, vid_hold;
    logic        run;
    logic        armed;
    logic        skip_vbl;              // the time-0 vblank is still to come
    always_ff @(posedge clk) begin
        if (reset) begin
            run <= 1'b0; armed <= 1'b0; skip_vbl <= 1'b0;
        end else if (!run) begin
            if (vbl_raw) armed <= 1'b1;
            else if (armed && vbl_pre) begin run <= 1'b1; skip_vbl <= 1'b1; end     // run from START_EARLY clocks before vbl_raw
        end else if (vbl_raw) skip_vbl <= 1'b0;
    end
    assign vbl_ev = vbl_raw && run && !skip_vbl;
    wire game_reset = !run;
    // the sound board starts at MAME's time 0, START_EARLY clocks after the 68000
    logic [5:0] snd_cnt;
    logic       snd_run;
    always_ff @(posedge clk) begin
        if (!run) begin snd_cnt <= 6'd0; snd_run <= 1'b0; end
        else if (!snd_run) begin
            if (snd_cnt == 6'(START_EARLY - 1)) snd_run <= 1'b1;
            snd_cnt <= snd_cnt + 6'd1;
        end
    end
    assign running = run;
    assign frame_tick = vbl_ev;

    // ================================================================== the 68000
    // the phase enables: decided a clock ahead (registered: they fan out to the whole CPU); never two in a row
    logic  [1:0] pdiv;                  // the nominal grid: a phase at pdiv == 0
    logic        en;                    // this clock is a phase of the CPU
    logic        ph;                    // the next phase is PHI2
    logic  [9:0] owed;                  // nominal phases the CPU has not had yet
    logic        hold;                  // the bus cycle cannot go on yet
    wire         tick = (pdiv == 2'd0);
    wire  [9:0]  owed_n = owed + {9'd0, tick && run} - {9'd0, en && run};
    wire         tick_n = (pdiv == 2'd2);
    wire         en_n = !en && (game_reset ? tick_n : (!hold && (owed_n != 10'd0 || tick_n)));
    always_ff @(posedge clk) begin
        if (reset) begin
            pdiv <= 2'd0; en <= 1'b0; ph <= 1'b0; owed <= 10'd0;
        end else begin
            pdiv <= (pdiv == 2'd2) ? 2'd0 : pdiv + 2'd1;
            en   <= en_n;
            if (en) ph <= ~ph;
            owed <= game_reset ? 10'd0 : owed_n;
        end
    end
    wire en_phi1 = en && !ph;
    wire en_phi2 = en &&  ph;

    logic        as_n, uds_n, lds_n, rw_n;
    logic  [2:0] fc;
    logic [23:1] eab;
    logic [15:0] cpu_dout;
    logic [15:0] cpu_din;
    logic        dtack_n, vpa_n, ipl0_n;
    logic  [1:0] wr_dsn;                // the write's {UDS, LDS}, from AS on (vendored fx68k: modules/VENDOR.md)
    logic        e_unused, vma_unused, bg_unused, oreset_unused, ohalted_unused;

    fx68k u_cpu (
        .clk(clk), .HALTn(1'b1), .extReset(game_reset), .pwrUp(game_reset), .enPhi1(en_phi1), .enPhi2(en_phi2),
        .eRWn(rw_n), .ASn(as_n), .LDSn(lds_n), .UDSn(uds_n), .E(e_unused), .VMAn(vma_unused),
        .FC0(fc[0]), .FC1(fc[1]), .FC2(fc[2]), .BGn(bg_unused), .oRESETn(oreset_unused), .oHALTEDn(ohalted_unused),
        .DTACKn(dtack_n), .VPAn(vpa_n), .BERRn(1'b1), .BRn(1'b1), .BGACKn(1'b1),
        .IPL0n(ipl0_n), .IPL1n(1'b1), .IPL2n(1'b1),
        .iEdb(cpu_din), .oEdb(cpu_dout), .eab(eab), .oWrDSn(wr_dsn)
    );
    assign dbg_pc = {eab, 1'b0};

    // ------------------------------------------------------------------ the bus cycle
    // fx68k's outputs are its registers (they change the clock after a phase). A cycle begins when AS goes low: the address, the
    // direction and the function code are taken then; a read's data is taken by the CPU at the fifth phase after AS fell (the end of
    // S6). A write is made as soon as AS is low, with its data and its byte lanes (wr_dsn), as MAME makes it at the start of the bus
    // cycle. `nph` counts the phases since AS fell: from the fourth on, the CPU is held while the read's data is not on iEdb or the
    // write is not done.
    logic        in_cyc;
    logic  [2:0] nph;
    logic        rd_ok, wr_done;
    wire         cs   = !as_n && !in_cyc;                   // the cycle begins (this clock)
    wire         iack = (fc == 3'b111);
    wire  [23:0] A    = {eab, 1'b0};

    // the decode (of the address on the bus)
    wire sel_prg  = (A[23:19] == 5'd0);                     // 000000-07ffff
    wire sel_u1   = (A[23:20] == 4'h3);                     // 300000-3fffff
    wire sel_u2   = (A[23:21] == 3'b010);                   // 400000-5fffff (user2 and its mirror)
    wire sel_rom  = sel_prg || sel_u1 || sel_u2;
    wire sel_spr1 = (A[23:16] == 8'ha0);
    wire sel_vr0  = (A[23:13] == 11'h680);                  // d00000-d01fff
    wire sel_spr0 = (A[23:13] == 11'h700);                  // e00000-e01fff
    wire sel_wram = (A[23:16] == 8'hfe);
    wire sel_rozb = (A[23:1] == 23'h7fe000);                // ffc000 (the byte at ffc001)
    wire sel_vr1  = (A[23:12] == 12'hffd);
    wire sel_pal  = (A[23:12] == 12'hffe);
    wire sel_io   = (A[23:8] == 16'hfff0);
    wire sel_gfx  = sel_io && (A[7:1] == 7'h00);            // fff001 (write)
    wire sel_k36  = sel_io && (A[7:5] == 3'b001);           // fff020-fff03f (write)
    wire sel_vmem = sel_spr1 || sel_vr0 || sel_spr0 || sel_vr1 || sel_pal;
    wire sel_vid  = sel_vmem || sel_rozb || sel_gfx || sel_k36;

    // the ROMs' word in the SDRAM: maincpu at 0, user1 at byte 0x080000, user2 at 0x180000 (rtl/crshrace_loader.sv)
    wire [20:0] rom_w = sel_prg ? {3'd0, A[18:1]} : sel_u1 ? 21'h040000 + {2'd0, A[19:1]} : 21'h0C0000 + {2'd0, A[19:1]};

    logic        rd_pend;                                   // a non-ROM read: the data is there two clocks after the cycle began
    logic  [1:0] rd_cnt;
    logic        rom_wait;
    logic        c_ack, c_ready_unused;
    logic [15:0] c_q;
    wire         wr_go    = !as_n && !rw_n && !wr_done && !iack && !(sel_vid && vid_hold);
    wire   [1:0] wr_be    = ~wr_dsn;                        // {UDS, LDS} of the write

    always_ff @(posedge clk) begin
        if (game_reset) begin
            in_cyc <= 1'b0; nph <= 3'd0; rd_ok <= 1'b0; wr_done <= 1'b0; rd_pend <= 1'b0; rom_wait <= 1'b0;
        end else begin
            if (as_n) begin
                in_cyc <= 1'b0; rd_ok <= 1'b0; wr_done <= 1'b0; rd_pend <= 1'b0; rom_wait <= 1'b0;
            end else if (cs) begin
                in_cyc <= 1'b1; nph <= 3'd0; rd_ok <= 1'b0; wr_done <= wr_go;
                if (rw_n && !iack) begin
                    if (sel_rom) rom_wait <= 1'b1;
                    else begin rd_pend <= 1'b1; rd_cnt <= 2'd0; end
                end
            end else begin
                if (en && nph != 3'd7) nph <= nph + 3'd1;
                if (rom_wait && c_ack) begin rom_wait <= 1'b0; rd_ok <= 1'b1; end
                if (rd_pend) begin
                    rd_cnt <= rd_cnt + 2'd1;
                    if (rd_cnt == 2'd1) begin rd_pend <= 1'b0; rd_ok <= 1'b1; end
                end
                if (wr_go) wr_done <= 1'b1;
            end
        end
    end
    always_comb hold = in_cyc && !iack && (nph >= 3'd4) && !(rw_n ? rd_ok : wr_done);

    assign dtack_n = !(in_cyc && !iack);
    assign vpa_n   = !(in_cyc && iack);

    // ------------------------------------------------------------------ the ROMs (through the cache): 2.5 MB, 4,096 lines of 16 bytes
    crshrace_cache #(.AW(21), .IDX(10), .BASE(24'h000000)) u_cache (
        .clk(clk), .reset(reset), .ready(c_ready_unused),
        .req(cs && rw_n && !iack && sel_rom), .addr(rom_w), .ack(c_ack), .q(c_q),
        .m_req(m_req[0]), .m_addr(m_addr[0]), .m_len(m_len[0]), .m_ack(m_ack[0]), .m_valid(m_valid[0]), .m_data(m_rdata)
    );

    // ------------------------------------------------------------------ the work RAM
    logic [15:0] wram_q, wram_b_unused;
    crshrace_bram #(.AW(15), .NB(2)) u_wram (
        .clk(clk), .a_addr(A[15:1]), .a_wdata(cpu_dout), .a_be(wr_be), .a_we(wr_go && sel_wram), .a_q(wram_q),
        .b_addr(15'd0), .b_q(wram_b_unused)
    );

    // ------------------------------------------------------------------ the video memories and registers (rtl/crshrace_video.sv)
    logic [15:0] vid_q;

    // ------------------------------------------------------------------ I/O
    logic        latch_pending;
    logic        latch_wr;
    logic  [7:0] latch_din;
    always_ff @(posedge clk) begin
        latch_wr <= 1'b0;
        if (!game_reset && wr_go && sel_io && A[7:1] == 7'h04 && wr_be[0]) begin       // fff009, the low byte of fff008
            latch_wr <= 1'b1; latch_din <= cpu_dout[7:0];
        end
    end

    // the latch's pending flag as the 68000 reads it: the board's. (MAME_SYNC, the benches': as MAME's 68000 sees it, its own write at
    // once and the Z80's acknowledge only at the next vblank; MAME's soundlatch_pending_r makes the Z80 catch up first, so MAME's
    // value is the board's here, and the define is kept only to compare with MAME's scheduling.)
    logic        pend_seen;
`ifdef MAME_SYNC
    logic        pend_m = 1'b0;
    always_ff @(posedge clk) begin
        if (game_reset) pend_m <= 1'b0;
        else if (latch_wr) pend_m <= 1'b1;
        else if (vbl_ev) pend_m <= latch_pending;
    end
    assign pend_seen = pend_m;
`else
    assign pend_seen = latch_pending;
`endif
    logic [15:0] io_q;
    always_comb begin
        case (A[7:1])
            7'h00:   io_q = in_p1;                              // fff000
            7'h01:   io_q = {8'h00, in_p2};                     // fff002
            7'h02:   io_q = dsw0;                               // fff004
            7'h03:   io_q = {pend_seen, 3'b000, region, 8'h00}; // fff006
            7'h05:   io_q = {8'h00, dsw1};                      // fff00a
            7'h07:   io_q = {8'h00, in_p3};                     // fff00e
            default: io_q = 16'h0000;
        endcase
    end

    // the read data: the source of the cycle's address, taken when it is there
    logic        r_wram, r_vid, r_io;
    always_ff @(posedge clk) begin
        if (cs) begin r_wram <= sel_wram; r_vid <= sel_vmem; r_io <= sel_io; end
        if (rom_wait && c_ack) cpu_din <= c_q;
        else if (rd_pend && rd_cnt == 2'd1) cpu_din <= r_wram ? wram_q : r_vid ? vid_q : r_io ? io_q : 16'h0000;
    end

    // ------------------------------------------------------------------ IRQ 1: raised at the vblank, cleared by its acknowledge
    logic        irq1;
    logic        irq_pend;
    logic  [9:0] irq_wait;
    always_ff @(posedge clk) begin
        if (game_reset) begin
            irq1 <= 1'b0; irq_pend <= 1'b0;
        end else begin
            if (vbl_ev) begin
                if (owed_n == 10'd0) irq1 <= 1'b1;
                else begin irq_pend <= 1'b1; irq_wait <= owed_n; end
            end else if (irq_pend && en) begin
                irq_wait <= irq_wait - 10'd1;
                if (irq_wait == 10'd1) begin irq1 <= 1'b1; irq_pend <= 1'b0; end
            end
            if (cs && iack && A[3:1] == 3'd1) irq1 <= 1'b0;
        end
    end
    assign ipl0_n = !irq1;

    // ================================================================== the SDRAM clients of the sound (1..3) and the video (4..6)
    logic        v_req [3], v_ack [3], v_valid [3];
    logic [23:0] v_addr [3];
    logic  [4:0] v_len [3];
    logic        s_req [3], s_ack [3], s_valid [3];
    logic [23:0] s_addr [3];
    logic  [4:0] s_len [3];
    always_comb begin
        for (int i = 0; i < 3; i++) begin
            m_req[1 + i] = s_req[i]; m_addr[1 + i] = s_addr[i]; m_len[1 + i] = s_len[i];
            s_ack[i] = m_ack[1 + i]; s_valid[i] = m_valid[1 + i];
            m_req[4 + i] = v_req[i]; m_addr[4 + i] = v_addr[i]; m_len[4 + i] = v_len[i];
            v_ack[i] = m_ack[4 + i]; v_valid[i] = m_valid[4 + i];
        end
    end

    // ================================================================== the video
    crshrace_video #(.PRE(START_EARLY + 1)) u_video (
        .clk(clk), .rst_raster(rst_raster), .reset(reset), .flip(flip),
        .c_spr1(sel_spr1), .c_vr0(sel_vr0), .c_spr0(sel_spr0), .c_vr1(sel_vr1), .c_pal(sel_pal),
        .c_rozb(sel_rozb), .c_gfx(sel_gfx), .c_k36(sel_k36),
        .c_addr(A[15:1]), .c_wdata(cpu_dout), .c_be(wr_be), .c_we(wr_go && sel_vid), .c_rdata(vid_q),
        .c_hold(vid_hold), .vbl_ev(vbl_raw), .vbl_pre(vbl_pre),
        .m_req(v_req), .m_addr(v_addr), .m_len(v_len), .m_ack(v_ack), .m_valid(v_valid), .m_rdata(m_rdata),
        .ce_pix(ce_pix), .o_hs(hs), .o_vs(vs), .o_hblank(hblank), .o_vblank(vblank), .o_vblank_next(vblank_next),
        .o_r(r), .o_g(g), .o_b(b)
    );

    // ================================================================== the sound board
    logic [15:0] snd_pc_unused;
    crshrace_sound u_sound (
        .clk(clk), .mreset(reset), .reset(!snd_run),
        .latch_wr(latch_wr), .latch_din(latch_din), .latch_pending(latch_pending),
        .m_req(s_req), .m_addr(s_addr), .m_len(s_len), .m_ack(s_ack), .m_valid(s_valid), .m_rdata(m_rdata),
        .audio_l(audio_l), .audio_r(audio_r), .dbg_pc(snd_pc_unused)
    );

    wire unused = &{1'b0, e_unused, vma_unused, bg_unused, oreset_unused, ohalted_unused, wram_b_unused, c_ready_unused,
                    snd_pc_unused, en_phi1, uds_n, lds_n, A[0]};
endmodule
`default_nettype wire
