//------------------------------------------------------------------------------
// Lethal Crash Race's sound board: the Z80, the YM2610 and the 68000's sound latch, written from MAME 0.289's
// src/mame/vsystem/crshrace.cpp (with machine/gen_latch.cpp, sound/ymopn.cpp).
//
//   Z80 at 4 MHz (MAME: "4 MHz ???"): 0000-77ff ROM, 7800-7fff RAM, 8000-ffff a 32 KB bank of the 128 KB ROM (sh_bankswitch_w: the
//   byte's bits 1:0). I/O (8 bits): 00 the bank (write), 04 the sound latch (read) and its acknowledge (write), 08-0b the YM2610.
//   The NMI is the latch's pending flag (a separate acknowledge: reading does not clear it, writing 04 does); the IRQ (IM 1) is the
//   YM2610's. The 68000 writes the latch (fff009) and reads the pending flag (DSW2 bit 15).
//   YM2610 at 8 MHz (jt10, Jose Tejada's: its clock enable one in 12 clocks of 96 MHz). Its ADPCM-A ROM (h893.ic69) and ADPCM-B ROM
//   (h894.ic73), 1 MB each, are read from the SDRAM: a byte is fetched whenever the chip's address changes (a microsecond or more
//   before the chip takes it); addresses past the 1 MB read 0.
//
// The mix is MAME's: a stereo speaker, the YM2610's FM and ADPCM left and right at 1.0 each and its SSG at 0.75 to both. jt10's FM /
// ADPCM sums are 16-bit; its SSG output (10 bits, unsigned) is taken at 16 x with its DC removed (a first-order high-pass at about
// 9 Hz), then at 0.75.
//
// Clocking (the owner's Aquarium core's scheme): the Z80 steps once per 24 clocks of 96 MHz from its start, as MAME's Z80 starts at
// time 0. Its ROM is read through a cache from the SDRAM (rtl/crshrace_cache.sv); while a miss is filled its clock enable is held
// and the cycles it missed are given back right after at one step per 8 clocks, so the program stays on MAME's timeline; an
// interrupt raised meanwhile is held back by the steps still owed.
//------------------------------------------------------------------------------
`default_nettype none

module crshrace_sound (
    input  logic        clk,            // 96 MHz
    input  logic        mreset,         // the machine's reset (the ROM cache's: its tags are cleared before the CPUs start)
    input  logic        reset,          // the sound board's (its start: MAME's time 0)

    // the 68000's side of the latch
    input  logic        latch_wr,       // one clock
    input  logic  [7:0] latch_din,
    output logic        latch_pending,

    // SDRAM clients: 0 the Z80's ROM cache, 1 ADPCM-A, 2 ADPCM-B
    output logic        m_req   [3],
    output logic [23:0] m_addr  [3],
    output logic  [4:0] m_len   [3],
    input  logic        m_ack   [3],
    input  logic        m_valid [3],
    input  logic [15:0] m_rdata,

    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,
    output logic [15:0] dbg_pc
);
    localparam logic [23:0] ROM_W = 24'h140000, ADPA_W = 24'h800000, ADPB_W = 24'h880000;   // word addresses (crshrace_loader)

    // ------------------------------------------------------------------ clock enables
    logic [4:0] div;                    // the Z80's nominal cycle: one in 24 clocks
    always_ff @(posedge clk) div <= (reset || div == 5'd23) ? 5'd0 : div + 5'd1;
    wire  tick = (div == 5'd23);

    // the YM2610's clock: 8 MHz, one in 12 clocks. It runs while the board is held in reset too (jt10's shift registers take their
    // reset values only as they shift on cen); the board's start restarts it
    logic [3:0] ym_div;
    logic       ym_cen;
    always_ff @(posedge clk) begin
        ym_cen <= 1'b0;
        if (mreset || ym_div == 4'd11) begin ym_div <= 4'd0; ym_cen <= !mreset; end
        else ym_div <= ym_div + 4'd1;
    end

    // ------------------------------------------------------------------ the Z80
    logic        cpu_ce;
    logic        stall;
    logic  [7:0] owed;                  // nominal cycles the Z80 has not had yet
    logic  [2:0] gap;                   // clocks since its last step (saturating at 7)
    always_comb cpu_ce = !reset && !stall && (gap == 3'd7) && ((owed != 8'd0) || tick);
    always_ff @(posedge clk) begin
        if (reset) begin
            // one step at the first clock: tv80 spends a step after reset before its first fetch (the Hexion core's finding)
            owed <= 8'd1; gap <= 3'd7;
        end else begin
            gap <= cpu_ce ? 3'd0 : (gap == 3'd7) ? 3'd7 : gap + 3'd1;
            case ({tick, cpu_ce})
                2'b10:   owed <= (owed == 8'hff) ? owed : owed + 8'd1;
                2'b01:   owed <= owed - 8'd1;
                default: ;
            endcase
        end
    end
    wire  [7:0] owed_next = (tick && !cpu_ce) ? owed + 8'd1 : (cpu_ce && !tick) ? owed - 8'd1 : owed;   // after this clock

    logic        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;
    logic [15:0] A;
    logic  [7:0] cpu_di, cpu_do;
    logic        irq_line, nmi_line;

    tv80s_cen u_cpu (
        .reset_n(~reset), .clk(clk), .cen(cpu_ce), .wait_n(1'b1),
        .int_n(~irq_line), .nmi_n(~nmi_line), .busrq_n(1'b1),
        .m1_n(m1_n), .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n),
        .rfsh_n(rfsh_n), .halt_n(), .busak_n(), .A(A), .di(cpu_di), .dout(cpu_do)
    );
    assign dbg_pc = A;

    // The Z80 steps on a clock enable at least 8 clocks apart, so its outputs are multicycle paths (CrashRace.sdc): the board sees
    // the strobes four clocks after the CPU raises them. A write becomes one pulse per bus cycle. The interrupt acknowledge (M1 with
    // IORQ) is not an I/O read.
    wire  mem_rd_raw = !mreq_n && !rd_n;
    wire  mem_wr_raw = !mreq_n && !wr_n;
    wire  io_wr_raw  = !iorq_n && !wr_n;
    logic [4:0] rd_dl, wr_dl, iwr_dl;
    always_ff @(posedge clk) begin
        rd_dl  <= {rd_dl[3:0], mem_rd_raw};
        wr_dl  <= {wr_dl[3:0], mem_wr_raw};
        iwr_dl <= {iwr_dl[3:0], io_wr_raw};
    end
    wire  mem_rd   = rd_dl[3];
    wire  rd_start = rd_dl[3] && !rd_dl[4];
    wire  mem_wr   = wr_dl[3] && !wr_dl[4];
    wire  io_wr    = iwr_dl[3] && !iwr_dl[4];

    // ------------------------------------------------------------------ decode
    wire sel_ram  = (A[15:11] == 5'b01111);
    wire sel_rom  = A[15] || !sel_ram;
    wire [7:0] port = A[7:0];

    logic [1:0] bank;
    wire [16:0] rom_b = A[15] ? {bank, A[14:0]} : {2'd0, A[14:0]};

    // ------------------------------------------------------------------ the ROM (through the cache) and the RAM
    logic        c_ready, c_ack;
    logic [15:0] c_q;
    logic        rom_wait, rom_ok, rom_ok2;
    logic  [7:0] rom_byte;
    logic        rom_odd;
    crshrace_cache #(.AW(16), .IDX(8), .BASE(ROM_W)) u_cache (
        .clk(clk), .reset(mreset), .ready(c_ready),
        .req(rd_start && sel_rom), .addr(rom_b[16:1]), .ack(c_ack), .q(c_q),
        .m_req(m_req[0]), .m_addr(m_addr[0]), .m_len(m_len[0]), .m_ack(m_ack[0]), .m_valid(m_valid[0]), .m_data(m_rdata)
    );
    always_ff @(posedge clk) begin
        if (reset) begin
            rom_wait <= 1'b0; rom_ok <= 1'b0;
        end else begin
            if (rd_start && sel_rom) begin rom_wait <= 1'b1; rom_ok <= 1'b0; rom_odd <= rom_b[0]; end
            else if (rom_wait && c_ack) begin
                rom_wait <= 1'b0; rom_ok <= 1'b1;
                rom_byte <= rom_odd ? c_q[7:0] : c_q[15:8];
            end
            if (!mem_rd) rom_ok <= 1'b0;
        end
        rom_ok2 <= rom_ok && mem_rd;                // cpu_di has the byte (a clock after rom_byte)
    end

    logic [7:0] ram_q;
    crshrace_spram #(.AW(11), .DW(8)) u_ram (.clk(clk), .addr(A[10:0]), .wdata(cpu_do), .we(mem_wr && sel_ram), .q(ram_q));

    // the Z80 waits for a ROM read's word (a cache miss: an SDRAM burst)
    always_comb stall = mem_rd && sel_rom && !rom_ok2;

    // ------------------------------------------------------------------ the latch
    logic [7:0] latch;
    always_ff @(posedge clk) begin
        if (reset) begin
            latch <= 8'd0; latch_pending <= 1'b0;
        end else begin
            if (io_wr && port == 8'h04) latch_pending <= 1'b0;
            if (latch_wr) begin latch <= latch_din; latch_pending <= 1'b1; end
        end
    end

    // ------------------------------------------------------------------ the bank
    always_ff @(posedge clk) begin
        if (reset) bank <= 2'd0;
        else if (io_wr && port == 8'h00) bank <= cpu_do[1:0];
    end

    // ------------------------------------------------------------------ the YM2610 (jt10)
    // jt10 takes a register write on every clock its write is held: a write is given to it from the clock after a cen to the next cen,
    // one chip clock (writes wait in a 4-entry queue: catching up after a cache miss the Z80 can OUT twice within one such window)
    logic       ym_wr;
    logic [1:0] ym_wa;
    logic [7:0] ym_din;
    logic [9:0] ymq [4];
    logic [1:0] ymq_wp, ymq_rp;
    logic [2:0] ymq_n;
    wire        ymq_push = io_wr && port[7:2] == 6'd2;
    wire        ymq_pop  = ym_cen && !ym_wr && ymq_n != 3'd0;
    always_ff @(posedge clk) begin
        if (reset) begin ymq_wp <= 2'd0; ymq_rp <= 2'd0; ymq_n <= 3'd0; ym_wr <= 1'b0; end
        else begin
            if (ymq_push) begin ymq[ymq_wp] <= {port[1:0], cpu_do}; ymq_wp <= ymq_wp + 2'd1; end
            if (ymq_pop) begin {ym_wa, ym_din} <= ymq[ymq_rp]; ymq_rp <= ymq_rp + 2'd1; end
            case ({ymq_push, ymq_pop})
                2'b10:   ymq_n <= ymq_n + 3'd1;
                2'b01:   ymq_n <= ymq_n - 3'd1;
                default: ;
            endcase
            if (ym_cen) ym_wr <= ymq_pop;
        end
    end
    logic  [7:0] ym_dout;
    logic        ym_irq_n;
    logic [19:0] a_addr;
    logic  [4:0] a_bank;
    logic        a_roe_n, b_roe_n;
    logic [23:0] b_addr;
    logic  [7:0] a_data, b_data;
    logic signed [15:0] fm_l, fm_r, snd_l_unused, snd_r_unused;
    logic  [9:0] psg;
    logic  [7:0] psg_a_unused, psg_b_unused, psg_c_unused;
    logic        ym_sample;
    jt10 u_ym (
        .rst(reset), .clk(clk), .cen(ym_cen),
        .din(ym_din), .addr(ym_wr ? ym_wa : port[1:0]), .cs_n(!ym_wr), .wr_n(!ym_wr),
        .dout(ym_dout), .irq_n(ym_irq_n),
        .adpcma_addr(a_addr), .adpcma_bank(a_bank), .adpcma_roe_n(a_roe_n), .adpcma_data(a_data),
        .adpcmb_addr(b_addr), .adpcmb_roe_n(b_roe_n), .adpcmb_data(b_data),
        .psg_A(psg_a_unused), .psg_B(psg_b_unused), .psg_C(psg_c_unused),
        .fm_left(fm_l), .fm_right(fm_r), .psg_snd(psg), .snd_right(snd_r_unused), .snd_left(snd_l_unused),
        .snd_sample(ym_sample), .ch_enable(6'h3f)
    );

    // ------------------------------------------------------------------ the ADPCM ROMs
    // a byte is fetched whenever the chip's address changes; the chip latches its data on its clock enables long after
    crshrace_adpcm_rd #(.BASE(ADPA_W)) u_ada (
        .clk(clk), .reset(mreset), .addr({a_bank[3:0], a_addr}), .data(a_data),
        .m_req(m_req[1]), .m_addr(m_addr[1]), .m_len(m_len[1]), .m_ack(m_ack[1]), .m_valid(m_valid[1]), .m_rdata(m_rdata)
    );
    crshrace_adpcm_rd #(.BASE(ADPB_W)) u_adb (
        .clk(clk), .reset(mreset), .addr(b_addr), .data(b_data),
        .m_req(m_req[2]), .m_addr(m_addr[2]), .m_len(m_len[2]), .m_ack(m_ack[2]), .m_valid(m_valid[2]), .m_rdata(m_rdata)
    );

    // ------------------------------------------------------------------ the read data
    always_ff @(posedge clk) begin
        if (!iorq_n) begin
            case (port[7:2])
                6'd1:    cpu_di <= latch;
                6'd2:    cpu_di <= ym_dout;
                default: cpu_di <= 8'h00;
            endcase
        end
        else if (sel_ram) cpu_di <= ram_q;
        else              cpu_di <= rom_byte;
    end

    // ------------------------------------------------------------------ the interrupts
    // the NMI is the latch's pending flag, the IRQ the YM2610's line; either goes up on the Z80's own timeline (behind by the steps
    // it still owes after a wait, it sees the line on the step MAME's Z80 would)
    logic       irq_src_d, nmi_src_d;
    logic       irq_pend, nmi_pend;
    logic [7:0] irq_wait, nmi_wait;
    wire        irq_src = !ym_irq_n;
    wire        nmi_src = latch_pending;
    always_ff @(posedge clk) begin
        if (reset) begin
            irq_line <= 1'b0; nmi_line <= 1'b0; irq_pend <= 1'b0; nmi_pend <= 1'b0; irq_src_d <= 1'b0; nmi_src_d <= 1'b0;
        end else begin
            irq_src_d <= irq_src; nmi_src_d <= nmi_src;
            if (irq_src && !irq_src_d) begin
                if (owed_next == 8'd0) irq_line <= 1'b1;
                else begin irq_pend <= 1'b1; irq_wait <= owed_next; end
            end else if (!irq_src) begin
                irq_line <= 1'b0; irq_pend <= 1'b0;
            end else if (irq_pend && cpu_ce) begin
                irq_wait <= irq_wait - 8'd1;
                if (irq_wait == 8'd1) begin irq_line <= 1'b1; irq_pend <= 1'b0; end
            end
            if (nmi_src && !nmi_src_d) begin
                if (owed_next == 8'd0) nmi_line <= 1'b1;
                else begin nmi_pend <= 1'b1; nmi_wait <= owed_next; end
            end else if (!nmi_src) begin
                nmi_line <= 1'b0; nmi_pend <= 1'b0;
            end else if (nmi_pend && cpu_ce) begin
                nmi_wait <= nmi_wait - 8'd1;
                if (nmi_wait == 8'd1) begin nmi_line <= 1'b1; nmi_pend <= 1'b0; end
            end
        end
    end

    // ------------------------------------------------------------------ the mix
    // the SSG: 16 x its 10-bit output, less its average (y += (x - y) / 1024 a sample of jt10's, 55.6 kHz: about 9 Hz), times 0.75
    logic signed [25:0] psg_avg;                // 16.10 fixed point
    wire  signed [15:0] psg_x = $signed({2'b00, psg, 4'd0});
    wire  signed [16:0] psg_ac = 17'(psg_x) - 17'(psg_avg[25:10]);
    always_ff @(posedge clk) begin
        if (reset) psg_avg <= 26'd0;
        else if (ym_sample) psg_avg <= psg_avg + 26'(psg_ac);
    end
    logic signed [15:0] fm_lq, fm_rq;
    logic signed [17:0] ssg_q;
    always_ff @(posedge clk) begin
        fm_lq <= fm_l; fm_rq <= fm_r;
        ssg_q <= 18'(psg_ac) - (18'(psg_ac) >>> 2);
    end
    function automatic logic signed [15:0] clamp16(input logic signed [18:0] v);
        clamp16 = (v > 19'sd32767) ? 16'sd32767 : (v < -19'sd32768) ? $signed(16'h8000) : v[15:0];
    endfunction
    always_ff @(posedge clk) begin
        audio_l <= clamp16(19'(fm_lq) + 19'(ssg_q));
        audio_r <= clamp16(19'(fm_rq) + 19'(ssg_q));
    end

    wire unused = &{1'b0, rfsh_n, m1_n, c_ready, a_bank[4], a_roe_n, b_roe_n, snd_l_unused, snd_r_unused, psg_a_unused,
                    psg_b_unused, psg_c_unused};
endmodule

//------------------------------------------------------------------------------
// One of the YM2610's ADPCM ROMs (1 MB) in the SDRAM: the byte at `addr`, fetched again whenever `addr` changes (one word read);
// past the 1 MB the ROM reads 0 (MAME's region ends there).
//------------------------------------------------------------------------------
module crshrace_adpcm_rd #(
    parameter logic [23:0] BASE = 24'h800000
) (
    input  logic        clk,
    input  logic        reset,
    input  logic [23:0] addr,           // byte address
    output logic  [7:0] data,

    output logic        m_req,
    output logic [23:0] m_addr,
    output logic  [4:0] m_len,
    input  logic        m_ack,
    input  logic        m_valid,
    input  logic [15:0] m_rdata
);
    logic [23:0] cur;                           // the address of `data` (or being fetched)
    logic        busy, odd, again;
    always_ff @(posedge clk) begin
        if (reset) begin
            cur <= 24'hffffff; busy <= 1'b0; m_req <= 1'b0; data <= 8'd0; again <= 1'b0;
        end else begin
            if (m_ack) m_req <= 1'b0;
            if (busy) begin
                if (addr != cur) again <= 1'b1;
                if (m_valid) begin
                    busy <= 1'b0;
                    data <= odd ? m_rdata[7:0] : m_rdata[15:8];
                end
            end else if (addr != cur || again) begin
                cur <= addr; again <= 1'b0;
                if (addr[23:20] != 4'd0) data <= 8'd0;
                else begin
                    busy <= 1'b1; odd <= addr[0];
                    m_req <= 1'b1; m_addr <= BASE + {5'd0, addr[19:1]}; m_len <= 5'd1;
                end
            end
        end
    end
endmodule
`default_nettype wire
