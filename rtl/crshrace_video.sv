//------------------------------------------------------------------------------
// Lethal Crash Race's video: the video memories and registers, their snapshot at the vertical blank, the raster, the three layers
// and MAME 0.289's mix of them (src/mame/vsystem/crshrace.cpp screen_update, vsystem_spr.cpp, src/devices/video/k053936.cpp).
//
// The memories (the 68000's side, at its addresses in rtl/crshrace_core.sv): sprite RAM 1 a00000 (32 K words: the VS9210's tile
// table), VRAM 0 d00000 (4 K words: the K053936 layer's 64 x 64 tiles), sprite RAM 0 e00000 (4 K words: the VS9108's list and
// attributes), VRAM 1 ffd000 (2 K words: the char layer), the palette ffe000 (2 K words, xBBBBBGGGGGRRRRR). Each is kept twice:
// the live copy the CPU reads and writes, and the display copy the picture is drawn from; the registers (gfxctrl fff001, the
// K053936 layer's tile bank ffc001, the K053936's control words fff020-fff03f) likewise.
//
// MAME draws the whole frame at the start of the vertical blank from the state of that instant, and then (its vblank callbacks)
// copies both sprite RAMs into their buffers (buffered_spriteram16_device): the sprites a frame shows are the RAMs as they were at
// the vblank before. The core does the same: at the vblank (vbl_ev) the live copies are copied into the display copies, 64 bits a
// clock (8,192 clocks, 85 us, for the 64 KB tile table; the others are done within its first 1,024; a 68000 write to an entry the
// copy has not yet reached waits for it, rtl/crshrace_core.sv), the sprite RAMs into one of two buffers each (flipped at every
// vblank), and the frame after it is drawn from them, the sprites from the other buffer.
//
// The raster: MAME's screen is 60 Hz, 512 x 256 with the visible area 320 x 224 at 0, 0 (no blanking times of the board are known:
// MAME: "TODO: PCB sports 32 MHz and 24 MHz XTALs"); the core draws it on a standard 15 kHz 240p raster of its own: 263 lines of 406
// dots of 15 clocks (a 6.4 MHz dot; 6,090 clocks, 15.76 kHz; 59.94 Hz), every line the same, the 224 picture lines first, then 8 lines
// of border, 3 of front porch, 3 of vsync and 25 to the next picture (8 of them its top border): the picture sits in the middle of a
// 240p frame. A RetroTINK 4K takes 262-264 lines as "MiSTer 240p", and a consumer CRT a standard 240p signal. The vblank begins at
// line 224 (vbl_ev): MAME's vblank, the 68000's IRQ 1. The raster runs from power-up on, through resets (the core starts the CPUs
// PRE clocks before a vblank, vbl_pre).
//
// Flip (the OSD's Flip Screen; MAME does not flip the game, MACHINE_NO_COCKTAIL, and the board's flip is not known): the picture
// turned 180 degrees, MAME's picture dot for dot: line y is drawn from MAME's row 223 - y and read out from its end. Taken at the
// vblank with the registers.
//
// Each visible line is drawn during the line before it into ping-pong line buffers (a layer each; the sprites' with a written bit a
// pixel) and mixed as the beam runs, in MAME's order (screen_update, by gfxctrl & 0xfb): 0x00 the sprites, the char layer, the
// K053936 layer; 0x01 / 0x02 the char layer, the K053936 layer, the sprites; anything else none of them; all over palette entry
// 0x1ff; gfxctrl bit 2 makes the picture black. Then the palette.
//------------------------------------------------------------------------------
`default_nettype none

module crshrace_video #(
    parameter int PRE = 33              // vbl_pre: this many clocks before vbl_ev
) (
    input  logic        clk,            // 96 MHz
    input  logic        rst_raster,     // the raster's power-up reset
    input  logic        reset,          // the machine's
    input  logic        flip,           // the OSD's Flip Screen

    // the 68000's port to the video memories and registers
    input  logic        c_spr1,
    input  logic        c_vr0,
    input  logic        c_spr0,
    input  logic        c_vr1,
    input  logic        c_pal,
    input  logic        c_rozb,
    input  logic        c_gfx,
    input  logic        c_k36,
    input  logic [15:1] c_addr,         // the word in the region
    input  logic [15:0] c_wdata,
    input  logic  [1:0] c_be,           // {UDS, LDS}
    input  logic        c_we,           // one clock
    output logic [15:0] c_rdata,        // the word at c_addr, one clock after it

    output logic        c_hold,         // the write at c_addr must wait: the snapshot has not yet copied its entry
    output logic        vbl_ev,         // one clock: the vertical blank begins
    output logic        vbl_pre,        // one clock, PRE clocks before vbl_ev

    // the SDRAM clients: 0 chars, 1 K053936, 2 sprites
    output logic        m_req   [3],
    output logic [23:0] m_addr  [3],
    output logic  [4:0] m_len   [3],
    input  logic        m_ack   [3],
    input  logic        m_valid [3],
    input  logic [15:0] m_rdata,

    output logic        ce_pix,
    output logic        o_hs,
    output logic        o_vs,
    output logic        o_hblank,
    output logic        o_vblank,
    output logic        o_vblank_next,  // the next line is in the vertical blank
    output logic  [7:0] o_r,
    output logic  [7:0] o_g,
    output logic  [7:0] o_b
);
    // ================================================================== the raster
    localparam logic  [8:0] L = 9'd263, VIS = 9'd224, VS_A = 9'd235, VS_B = 9'd238, HS_A = 9'd334, HS_B = 9'd364;
    localparam logic  [3:0] DOTC = 4'd15;
    localparam logic [12:0] LLEN = 13'd6090;

    logic [12:0] hc;                            // clock in the line
    logic  [3:0] sub;                           // clock in the dot
    logic  [8:0] dot;
    logic  [8:0] line;
    wire         line_end = (hc == LLEN - 13'd1);
    assign ce_pix = (sub == DOTC - 4'd1) || line_end;   // the last clock of a dot
    wire  [8:0]  nline  = (line == L - 9'd1) ? 9'd0 : line + 9'd1;

    always_ff @(posedge clk) begin
        if (rst_raster) begin
            hc <= 13'd0; sub <= 4'd0; dot <= 9'd0; line <= VIS;
        end else if (line_end) begin
            hc <= 13'd0; sub <= 4'd0; dot <= 9'd0;
            line <= nline;
        end else begin
            hc <= hc + 13'd1;
            if (sub == DOTC - 4'd1) begin sub <= 4'd0; dot <= dot + 9'd1; end
            else sub <= sub + 4'd1;
        end
    end

    wire line_start = (hc == 13'd0);
    assign vbl_ev  = line_start && (line == VIS) && !rst_raster;
    assign vbl_pre = (hc == LLEN - 13'(PRE)) && (line == VIS - 9'd1) && !rst_raster;

    // ================================================================== the video memories
    // live copies, 64-bit entries of four words: port A the 68000's, port B the snapshot's read
    logic [63:0] s1_lq, v0_lq, s0_lq, v1_lq, pl_lq;
    logic [63:0] s1_lb, v0_lb, s0_lb, v1_lb, pl_lb;
    logic [12:0] cp_ra;                         // the snapshot's read address

    wire  [1:0] cw   = c_addr[2:1];             // the word in a 64-bit entry
    wire  [7:0] be_w = {6'd0, c_be} << {cw, 1'b0};
    wire        we   = c_we && !c_hold;
    crshrace_bram #(.AW(13), .NB(8)) u_s1_l (.clk(clk), .a_addr(c_addr[15:3]), .a_wdata({4{c_wdata}}), .a_be(be_w),
                                             .a_we(we && c_spr1), .a_q(s1_lq), .b_addr(cp_ra), .b_q(s1_lb));
    crshrace_bram #(.AW(10), .NB(8)) u_v0_l (.clk(clk), .a_addr(c_addr[12:3]), .a_wdata({4{c_wdata}}), .a_be(be_w),
                                             .a_we(we && c_vr0), .a_q(v0_lq), .b_addr(cp_ra[9:0]), .b_q(v0_lb));
    crshrace_bram #(.AW(10), .NB(8)) u_s0_l (.clk(clk), .a_addr(c_addr[12:3]), .a_wdata({4{c_wdata}}), .a_be(be_w),
                                             .a_we(we && c_spr0), .a_q(s0_lq), .b_addr(cp_ra[9:0]), .b_q(s0_lb));
    crshrace_bram #(.AW(9), .NB(8)) u_v1_l (.clk(clk), .a_addr(c_addr[11:3]), .a_wdata({4{c_wdata}}), .a_be(be_w),
                                            .a_we(we && c_vr1), .a_q(v1_lq), .b_addr(cp_ra[8:0]), .b_q(v1_lb));
    crshrace_bram #(.AW(9), .NB(8)) u_pl_l (.clk(clk), .a_addr(c_addr[11:3]), .a_wdata({4{c_wdata}}), .a_be(be_w),
                                            .a_we(we && c_pal), .a_q(pl_lq), .b_addr(cp_ra[8:0]), .b_q(pl_lb));

    // the registers
    logic  [7:0] gfx_l, gfx_d, rozb_l, rozb_d;
    logic [15:0] k36_l [16];
    logic [15:0] k36_d [7];
    always_ff @(posedge clk) begin
        if (reset) begin
            gfx_l <= 8'd0; rozb_l <= 8'd0;                          // machine_reset, the K053936's device_reset
            for (int i = 0; i < 16; i++) k36_l[i] <= 16'd0;
        end else if (we) begin
            if (c_gfx && c_be[0])  gfx_l  <= c_wdata[7:0];
            if (c_rozb && c_be[0]) rozb_l <= c_wdata[7:0];
            if (c_k36) begin
                if (c_be[1]) k36_l[c_addr[4:1]][15:8] <= c_wdata[15:8];
                if (c_be[0]) k36_l[c_addr[4:1]][7:0]  <= c_wdata[7:0];
            end
        end
    end

    // the 68000's read: the word of the entry
    logic       r_s1, r_v0, r_s0, r_v1, r_pl;
    logic [1:0] r_cw;
    always_ff @(posedge clk) begin
        r_s1 <= c_spr1; r_v0 <= c_vr0; r_s0 <= c_spr0; r_v1 <= c_vr1; r_pl <= c_pal; r_cw <= cw;
    end
    always_comb begin
        if      (r_s1) c_rdata = s1_lq[16 * r_cw +: 16];
        else if (r_v0) c_rdata = v0_lq[16 * r_cw +: 16];
        else if (r_s0) c_rdata = s0_lq[16 * r_cw +: 16];
        else if (r_v1) c_rdata = v1_lq[16 * r_cw +: 16];
        else if (r_pl) c_rdata = pl_lq[16 * r_cw +: 16];
        else           c_rdata = 16'h0000;
    end

    // ------------------------------------------------------------------ the snapshot
    // from vbl_ev: entry i is read from the live copies at clock i and written to the display copies at clock i + 1 (8,192 entries;
    // the smaller memories take the first 1,024 or 512); the sprite RAMs go to buffer `sb` (flipped at each vblank), the frame shows
    // ~sb
    logic        cp_on, cp_w;
    logic [12:0] cp_wa;
    logic        flip_d;
    /* verilator lint_off PROCASSINIT */
    logic        sb = 1'b0;
    /* verilator lint_on PROCASSINIT */
    initial for (int i = 0; i < 7; i++) k36_d[i] = 16'd0;
    always_ff @(posedge clk) begin
        cp_w <= 1'b0;
        if (reset) begin
            cp_on <= 1'b0; cp_ra <= 13'd0; flip_d <= 1'b0; gfx_d <= 8'd0; rozb_d <= 8'd0;
        end else if (vbl_ev) begin
            cp_on <= 1'b1; cp_ra <= 13'd0;
            sb <= ~sb;
            gfx_d <= gfx_l; rozb_d <= rozb_l; flip_d <= flip;
            for (int i = 0; i < 7; i++) k36_d[i] <= k36_l[i];
        end else if (cp_on) begin
            cp_w  <= 1'b1;
            cp_wa <= cp_ra;
            cp_ra <= cp_ra + 13'd1;
            if (cp_ra == 13'h1fff) cp_on <= 1'b0;
        end
    end
    // a write waits while the snapshot is still to copy its entry (from vbl_ev, the snapshot's instant, until the copy's read has
    // passed the entry: the copy reads entry cp_ra in this clock, so a write to an entry below it changes only the live copy)
    wire [12:0] c_ent = c_spr1 ? c_addr[15:3] : (c_vr0 || c_spr0) ? {3'd0, c_addr[12:3]} : {4'd0, c_addr[11:3]};
    wire        c_mem = c_spr1 || c_vr0 || c_spr0 || c_vr1 || c_pal;
    assign c_hold = vbl_ev || (cp_on && c_mem && (c_ent >= cp_ra));

    // display copies: port A the snapshot's write, port B the drawing's read
    logic [11:0] v0_a;                          // the K053936 layer's word
    logic [10:0] v1_a;                          // the char layer's word
    logic  [9:0] s0_a;                          // the sprites' entry
    logic [12:0] s1_a;                          // the tile table's entry
    logic  [8:0] p_a;
    logic [63:0] v0_q, v1_q, s0_q, s1_q, p_q;
    logic [63:0] ua0, ua1, ua2, ua3, ua4;
    crshrace_dpram #(.AW(10), .DW(64)) u_v0_d (.clk(clk), .a_addr(cp_wa[9:0]), .a_wdata(v0_lb), .a_we(cp_w && cp_wa < 13'd1024),
                                               .a_q(ua0), .b_addr(v0_a[11:2]), .b_q(v0_q));
    crshrace_dpram #(.AW(9), .DW(64)) u_v1_d (.clk(clk), .a_addr(cp_wa[8:0]), .a_wdata(v1_lb), .a_we(cp_w && cp_wa < 13'd512),
                                              .a_q(ua1), .b_addr(v1_a[10:2]), .b_q(v1_q));
    crshrace_dpram #(.AW(9), .DW(64)) u_pl_d (.clk(clk), .a_addr(cp_wa[8:0]), .a_wdata(pl_lb), .a_we(cp_w && cp_wa < 13'd512),
                                              .a_q(ua2), .b_addr(p_a), .b_q(p_q));
    crshrace_dpram #(.AW(11), .DW(64)) u_s0_d (.clk(clk), .a_addr({sb, cp_wa[9:0]}), .a_wdata(s0_lb),
                                               .a_we(cp_w && cp_wa < 13'd1024), .a_q(ua3), .b_addr({~sb, s0_a}), .b_q(s0_q));
    crshrace_dpram #(.AW(14), .DW(64)) u_s1_d (.clk(clk), .a_addr({sb, cp_wa}), .a_wdata(s1_lb), .a_we(cp_w), .a_q(ua4),
                                               .b_addr({~sb, s1_a}), .b_q(s1_q));
    logic [1:0] v0_w, v1_w;
    always_ff @(posedge clk) begin v0_w <= v0_a[1:0]; v1_w <= v1_a[1:0]; end
    wire [15:0] v0_word = v0_q[16 * v0_w +: 16];
    wire [15:0] v1_word = v1_q[16 * v1_w +: 16];

    // ================================================================== drawing the next line
    // at the start of each line the next visible line is started (MAME's row; flipped, row 223 - line) into line buffer bank line[0]
    wire        r_go = line_start && (nline < VIS) && !reset && !rst_raster;
    wire  [7:0] r_yb = flip_d ? 8'd223 - nline[7:0] : nline[7:0];
    logic       c_busy, z_busy, s_busy;

    logic        c_lwe, z_lwe, s_lwe;
    logic  [9:0] c_lwa, z_lwa, s_lwa;
    logic  [7:0] c_lwd, z_lwd;
    logic  [9:0] s_lwd;

    crshrace_chars #(.GFX_W(24'h200000)) u_chars (
        .clk(clk), .reset(reset), .start(r_go), .yb(r_yb), .bank(nline[0]), .busy(c_busy),
        .v_addr(v1_a), .v_q(v1_word),
        .m_req(m_req[0]), .m_addr(m_addr[0]), .m_len(m_len[0]), .m_ack(m_ack[0]), .m_valid(m_valid[0]), .m_rdata(m_rdata),
        .lb_we(c_lwe), .lb_addr(c_lwa), .lb_data(c_lwd)
    );

    crshrace_roz #(.GFX_W(24'h400000)) u_roz (
        .clk(clk), .reset(reset), .start(r_go), .yb(r_yb), .bank(nline[0]), .busy(z_busy),
        .ctrl0(k36_d[0]), .ctrl1(k36_d[1]), .ctrl2(k36_d[2]), .ctrl3(k36_d[3]), .ctrl4(k36_d[4]), .ctrl5(k36_d[5]),
        .ctrl6(k36_d[6]), .tbank(rozb_d),
        .v_addr(v0_a), .v_q(v0_word),
        .m_req(m_req[1]), .m_addr(m_addr[1]), .m_len(m_len[1]), .m_ack(m_ack[1]), .m_valid(m_valid[1]), .m_rdata(m_rdata),
        .lb_we(z_lwe), .lb_addr(z_lwa), .lb_data(z_lwd)
    );

    logic       d_bank;
    logic [8:0] d_x;
    logic       s_have;
    crshrace_sprites #(.GFX_W(24'h600000)) u_spr (
        .clk(clk), .reset(reset), .start(r_go), .yb(r_yb), .bank(nline[0]), .busy(s_busy),
        .s_addr(s0_a), .s_q(s0_q), .t_addr(s1_a), .t_q(s1_q),
        .m_req(m_req[2]), .m_addr(m_addr[2]), .m_len(m_len[2]), .m_ack(m_ack[2]), .m_valid(m_valid[2]), .m_rdata(m_rdata),
        .lb_we(s_lwe), .lb_addr(s_lwa), .lb_data(s_lwd), .d_bank(d_bank), .d_x(d_x), .d_have(s_have)
    );

    // the line buffers: port A the drawing's, port B the display's
    logic [7:0] c_px, z_px, lb_u0, lb_u1;
    logic [9:0] s_px, lb_u2;
    crshrace_dpram #(.AW(10), .DW(8)) u_lb_c (.clk(clk), .a_addr(c_lwa), .a_wdata(c_lwd), .a_we(c_lwe), .a_q(lb_u0),
                                              .b_addr({d_bank, d_x}), .b_q(c_px));
    crshrace_dpram #(.AW(10), .DW(8)) u_lb_z (.clk(clk), .a_addr(z_lwa), .a_wdata(z_lwd), .a_we(z_lwe), .a_q(lb_u1),
                                              .b_addr({d_bank, d_x}), .b_q(z_px));
    crshrace_dpram #(.AW(10), .DW(10)) u_lb_s (.clk(clk), .a_addr(s_lwa), .a_wdata(s_lwd), .a_we(s_lwe), .a_q(lb_u2),
                                               .b_addr({d_bank, d_x}), .b_q(s_px));

    // ================================================================== the dot
    // sub 0: the line buffers' address (the dot); sub 1: their words, the mix (MAME's order), the palette's address; sub 2: the
    // palette entry; sub 3: the colour. Latched with the raster's signals at the dot's last clock (ce_pix): the outputs are one dot
    // behind the counters, all of them together. Flipped, the line is read from its end.
    always_ff @(posedge clk) begin
        d_bank <= line[0];
        d_x    <= flip_d ? 9'd319 - dot : dot;
    end

    wire        ch_op = (c_px != 8'hff);                            // the char layer: pens 0..254 of palette entries 0..255
    wire        rz_op = (z_px[3:0] != 4'hf);                        // the K053936 layer: 0x100 + colour * 16 + pen, pen 15 clear
    wire [10:0] ch_i  = {3'b000, c_px};
    wire [10:0] rz_i  = {3'b001, z_px};
    wire [10:0] sp_i  = 11'h200 + {1'b0, s_px};                     // the sprites: 0x200 + colour * 16 + pen
    wire  [7:0] mode  = gfx_d & 8'hfb;
    logic [10:0] mix;
    always_comb begin
        mix = 11'h1ff;
        if (mode == 8'h00) begin
            if (s_have) mix = sp_i;
            if (ch_op)  mix = ch_i;
            if (rz_op)  mix = rz_i;
        end else if (mode == 8'h01 || mode == 8'h02) begin
            if (ch_op)  mix = ch_i;
            if (rz_op)  mix = rz_i;
            if (s_have) mix = sp_i;
        end
    end

    logic [1:0] p_sel;
    always_ff @(posedge clk) begin
        p_a   <= mix[10:2];
        p_sel <= mix[1:0];
    end
    wire [15:0] pw = p_q[16 * p_sel +: 16];
    // xGGGGGBBBBBRRRRR (MAME's xGBR_555: red bits 4:0, blue 9:5, green 14:10), pal5bit
    wire  [4:0] c5r = pw[4:0];
    wire  [4:0] c5g = pw[14:10];
    wire  [4:0] c5b = pw[9:5];
    logic [7:0] cr, cg, cb;
    always_ff @(posedge clk) begin
        cr <= {c5r, c5r[4:2]};
        cg <= {c5g, c5g[4:2]};
        cb <= {c5b, c5b[4:2]};
    end

    wire pic_l   = (line < VIS);
    wire pic_n   = (nline < VIS);
    wire visible = (dot < 9'd320) && pic_l && !gfx_d[2];            // gfxctrl bit 2: the picture black (MAME's black_pen)
    always_ff @(posedge clk) begin
        if (ce_pix) begin
            o_r <= (visible && !reset) ? cr : 8'd0;
            o_g <= (visible && !reset) ? cg : 8'd0;
            o_b <= (visible && !reset) ? cb : 8'd0;
            o_hblank <= (dot >= 9'd320);
            o_hs     <= (dot >= HS_A) && (dot < HS_B);
            o_vblank <= !pic_l;
            o_vs     <= (line >= VS_A) && (line < VS_B);
            o_vblank_next <= !pic_n;
        end
    end

    wire unused = &{1'b0, c_busy, z_busy, s_busy, ua0, ua1, ua2, ua3, ua4, lb_u0, lb_u1, lb_u2, pw[15], k36_l[7], k36_l[8],
                    k36_l[9], k36_l[10], k36_l[11], k36_l[12], k36_l[13], k36_l[14], k36_l[15]};
endmodule
`default_nettype wire
