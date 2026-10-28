//------------------------------------------------------------------------------
// Lethal Crash Race's sprites, a line at a time into a line buffer: MAME 0.289's vsystem_spr_device::draw_sprites (the VS9108,
// src/mame/vsystem/vsystem_spr.cpp) with crshrace_state::tile_callback (the VS9210's tile table) for one bitmap row.
//
// Sprite RAM 0 (the display buffer: as it was at the vblank before the frame's, rtl/crshrace_video.sv), 4 K words: the list is its
// first 512 words, up to the first with bit 14 set (the end); an entry with bit 15 set is skipped, otherwise its bits 9:0 are the
// sprite, whose four attribute words are at word 4 * sprite:
//   w0: bits 8:0 oy, 11:9 ysize, 15:12 zoomy          w1: bits 8:0 ox, 11:9 xsize, 15:12 zoomx
//   w2: bit 14 flip x, 15 flip y, 13:8 the colour (palette 0x200 + colour * 16), bit 0 the map's bit 16     w3: the map's bits 15:0
// MAME draws the list in order (no priority callback here), each sprite as (ysize + 1) x (xsize + 1) blocks of a 16 x 16 tile,
// rows (ycnt) from 0 to ysize (from ysize down with flip y), in each the blocks (xcnt) from 0 to xsize (down with flip x); the n-th
// block drawn takes tile table[(map + n) & 0x7fff] (a word of sprite RAM 1, the buffer as at the vblank before), modulo 32,768 (the
// 4 MB region's tiles). With Z = 32 - zoom, a block is at ox + xcnt * Z / 2, oy + ycnt * Z / 2 (integer division) and drawn with
// gfx_element::zoom_transpen at the scale Z / 32: (Z + 1) / 2 pixels wide (9..16), source pixel (i * (16 << 16) / width) >> 16 (from
// the far end with the flip), pen 15 transparent; flip x / y also flip each tile. Each block is drawn four times, at its place and
// 512 pixels to the left and / or up (MAME's wrap): here the block's x and y are taken modulo 512. Later blocks cover earlier ones.
//
// The gfx (16 x 16 x 4 packed, lsb first: gfx_16x16x4_packed_lsb) in the SDRAM: a tile row is a 4-word burst at GFX_W + code * 64 +
// row * 4; pixel s is in word s / 4, its even byte (bits 15:8) for s / 2 even, the low nibble for s even.
//
// The work: the scan (four clocks a sprite, two for a skipped entry) finds the block rows that cover the line (all eight at once)
// and queues their blocks; one block's tile table read and 4-word burst are made while the one before is drawn, a pixel a clock.
//------------------------------------------------------------------------------
`default_nettype none

module crshrace_sprites #(
    parameter logic [23:0] GFX_W = 24'h600000
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        start,          // one clock: render bitmap row `yb` into line buffer bank `bank` (aborts a render under way)
    input  logic  [7:0] yb,
    input  logic        bank,
    output logic        busy,

    // sprite RAM 0's display buffer (64-bit entries of four words, word i in bits 16i+15:16i; two clocks after the address)
    output logic  [9:0] s_addr,
    input  logic [63:0] s_q,
    // the tile table's (sprite RAM 1)
    output logic [12:0] t_addr,
    input  logic [63:0] t_q,

    // the SDRAM client
    output logic        m_req,
    output logic [23:0] m_addr,
    output logic  [4:0] m_len,
    input  logic        m_ack,
    input  logic        m_valid,
    input  logic [15:0] m_rdata,

    // the line buffer: {colour, pen}; a pixel has a sprite where its bit is set
    output logic        lb_we,
    output logic  [9:0] lb_addr,
    output logic  [9:0] lb_data,
    input  logic        d_bank,         // the display's read of the bits (registered)
    input  logic  [8:0] d_x,
    output logic        d_have
);
    // ------------------------------------------------------------------ the written bits
    logic [319:0] have0, have1;                 // banks 0 and 1 (two vectors: Quartus 17 fails on the 2-D array's partial writes)
    logic         lbank;

    // the 16.16 source step of a block `w` pixels wide: (16 << 16) / w
    function automatic logic [16:0] f_dx(input logic [3:0] wm1);    // w - 1
        case (wm1)
            4'd8:    f_dx = 17'd116508;
            4'd9:    f_dx = 17'd104857;
            4'd10:   f_dx = 17'd95325;
            4'd11:   f_dx = 17'd87381;
            4'd12:   f_dx = 17'd80659;
            4'd13:   f_dx = 17'd74898;
            4'd14:   f_dx = 17'd69905;
            default: f_dx = 17'd65536;
        endcase
    endfunction

    // ------------------------------------------------------------------ the scan
    typedef enum logic [3:0] { S_IDLE, S_L1, S_L2, S_L3, S_A1, S_A2, S_ROWS, S_R2, S_JOBS, S_DONE } sst_e;
    sst_e        sst;
    logic  [7:0] ly;
    logic  [9:0] offs;                          // the list's word (0..512)
    logic  [1:0] l_w;                           // its word in the entry, two clocks on
    logic [15:0] lw_q;                         // the list word, registered (S_L3)

    wire  [15:0] lw     = s_q[16 * l_w +: 16];  // the list word
    // the attributes (S_A2)
    wire  [15:0] a0 = s_q[15:0], a1 = s_q[31:16], a2 = s_q[47:32], a3 = s_q[63:48];
    wire   [5:0] zy_a = 6'd32 - {2'b00, a0[15:12]};
    wire   [3:0] hm1_a = 4'(((zy_a + 6'd1) >> 1) - 6'd1);           // the block height - 1 (8..15)
    // the eight block rows against the line: j = (line - (oy + ycnt * Z / 2)) mod 512 < height
    logic  [7:0] hit_a;
    always_comb begin
        for (int i = 0; i < 8; i++) begin
            logic [8:0] top, j;
            top = a0[8:0] + 9'(({3'd0, 3'(i)} * zy_a) >> 1);
            j   = {1'b0, ly} - top;
            hit_a[i] = (3'(i) <= a0[11:9]) && (j <= {5'd0, hm1_a});
        end
    end

    // the sprite being queued
    logic  [8:0] q_oy, q_ox;
    logic  [2:0] q_ys, q_xs;
    logic  [5:0] q_zy, q_zx;
    logic  [3:0] q_hm1, q_wm1;
    logic        q_fx, q_fy;
    logic  [5:0] q_col;
    logic [16:0] q_map;                         // the map index of the row's first block
    logic  [7:0] q_hit;
    logic  [2:0] q_iy, q_ix;                    // the row and block in drawing order
    wire   [2:0] by     = q_fy ? q_ys - q_iy : q_iy;
    wire   [2:0] bx     = q_fx ? q_xs - q_ix : q_ix;
    wire   [8:0] r_top  = q_oy + 9'(({3'd0, by} * q_zy) >> 1);
    wire   [8:0] r_j    = {1'b0, ly} - r_top;                       // the row in the block (0..height - 1)
    logic  [3:0] rj_q;                          // r_j, registered (S_ROWS to S_R2)
    wire   [3:0] r_m    = q_fy ? q_hm1 - rj_q : rj_q;
    wire  [16:0] dy     = f_dx(q_hm1);
    wire  [20:0] r_prod = 21'(r_m) * 21'(dy);
    wire   [3:0] r_src  = r_prod[19:16];                            // the tile's source row
    wire   [9:0] b_x    = {1'b0, q_ox} + 10'(({3'd0, bx} * q_zx) >> 1);

    // the job queue: {map index[14:0], x (0..623), source row, flip x, colour, width - 1}
    localparam int QW = 15 + 10 + 4 + 1 + 6 + 4;
    logic [QW-1:0] q [8];
    logic  [2:0] q_wp, q_rp;
    logic  [3:0] q_n;
    logic        q_push, q_pop;
    logic [QW-1:0] q_in;
    logic  [3:0] j_row;                         // the source row of the row being queued
    wire         q_full = (q_n >= 4'd7);

    always_ff @(posedge clk) begin
        q_push <= 1'b0;
        if (reset || start) begin
            sst <= start ? S_L1 : S_IDLE;
            if (start) begin
                ly <= yb; offs <= 10'd0; s_addr <= 10'd0; l_w <= 2'd0;
                lbank <= bank;
            end
        end else begin
            case (sst)
                S_IDLE: ;
                S_L1: sst <= S_L2;                      // the RAM takes the address at this edge; the entry is there in the next clock
                S_L2: begin lw_q <= lw; sst <= S_L3; end
                S_L3: begin
                    if (lw_q[14] || offs == 10'd512) sst <= S_DONE;
                    else if (lw_q[15]) begin
                        offs <= offs + 10'd1; s_addr <= {3'd0, offs[8:2] + 7'(offs[1:0] == 2'd3)}; l_w <= offs[1:0] + 2'd1;
                        sst <= S_L1;
                    end else begin
                        s_addr <= lw_q[9:0];
                        sst <= S_A1;
                    end
                end
                S_A1: sst <= S_A2;
                S_A2: begin
                    q_oy <= a0[8:0]; q_ys <= a0[11:9]; q_zy <= zy_a; q_hm1 <= hm1_a;
                    q_ox <= a1[8:0]; q_xs <= a1[11:9]; q_zx <= 6'd32 - {2'b00, a1[15:12]};
                    q_wm1 <= 4'(((6'd33 - {2'b00, a1[15:12]}) >> 1) - 6'd1);
                    q_fx <= a2[14]; q_fy <= a2[15]; q_col <= a2[13:8];
                    q_map <= {a2[0], a3};
                    q_hit <= hit_a; q_iy <= 3'd0;
                    // the next list word
                    offs <= offs + 10'd1; l_w <= offs[1:0] + 2'd1;
                    if (hit_a != 8'd0) sst <= S_ROWS;
                    else begin
                        s_addr <= {3'd0, offs[8:2] + 7'(offs[1:0] == 2'd3)};
                        sst <= S_L1;
                    end
                end
                S_ROWS: begin
                    // the row in drawing order: queued if it covers the line
                    if (q_hit[by]) begin
                        rj_q <= r_j[3:0]; sst <= S_R2;
                    end else if (q_iy == q_ys) begin
                        s_addr <= {3'd0, offs[8:2]}; sst <= S_L1;
                    end else begin
                        q_iy <= q_iy + 3'd1; q_map <= q_map + {14'd0, q_xs} + 17'd1;
                    end
                end
                S_R2: begin q_ix <= 3'd0; j_row <= r_src; sst <= S_JOBS; end
                S_JOBS: if (!q_full && !q_push) begin
                    q_push <= 1'b1;
                    q_in   <= {15'(q_map + {14'd0, q_ix}), b_x, j_row, q_fx, q_col, q_wm1};
                    if (q_ix == q_xs) begin
                        if (q_iy == q_ys) begin s_addr <= {3'd0, offs[8:2]}; sst <= S_L1; end
                        else begin q_iy <= q_iy + 3'd1; q_map <= q_map + {14'd0, q_xs} + 17'd1; sst <= S_ROWS; end
                    end else q_ix <= q_ix + 3'd1;
                end
                S_DONE: ;
                default: sst <= S_IDLE;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (reset || start) begin
            q_wp <= 3'd0; q_rp <= 3'd0; q_n <= 4'd0;
        end else begin
            if (q_push) begin q[q_wp] <= q_in; q_wp <= q_wp + 3'd1; end
            if (q_pop) q_rp <= q_rp + 3'd1;
            case ({q_push, q_pop})
                2'b10:   q_n <= q_n + 4'd1;
                2'b01:   q_n <= q_n - 4'd1;
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------------ the fetch: the tile table, then the tile's row
    typedef enum logic [2:0] { F_IDLE, F_T1, F_T2, F_REQ, F_WAIT } fst_e;
    fst_e        fst;
    logic  [1:0] f_n;
    logic [QW-1:0] f_job;
    logic  [1:0] f_tw;
    logic        rx_full;
    logic [63:0] rx;
    logic [QW-1:0] rx_job;
    logic        rx_take;
    wire  [QW-1:0] q_head = q[q_rp];
    wire  [14:0] t_code = t_q[16 * f_tw +: 15];
    assign q_pop = (fst == F_IDLE) && (q_n != 4'd0) && !(reset || start);

    always_ff @(posedge clk) begin
        if (reset || start) begin
            fst <= F_IDLE; m_req <= 1'b0; rx_full <= 1'b0;
        end else begin
            if (rx_take) rx_full <= 1'b0;
            case (fst)
                F_IDLE: if (q_pop) begin
                    f_job  <= q_head;
                    t_addr <= q_head[QW-1 -: 13];
                    f_tw   <= q_head[QW-14 -: 2];
                    fst    <= F_T1;
                end
                F_T1: fst <= F_T2;
                F_T2: fst <= F_REQ;
                F_REQ: if (!rx_full || rx_take) begin
                    m_req  <= 1'b1;
                    m_addr <= GFX_W + {3'd0, t_code, f_job[14:11], 2'b00};
                    m_len  <= 5'd4;
                    f_n    <= 2'd0;
                    fst    <= F_WAIT;
                end
                F_WAIT: begin
                    if (m_ack) m_req <= 1'b0;
                    if (m_valid) begin
                        rx  <= {rx[47:0], m_rdata};
                        f_n <= f_n + 2'd1;
                        if (f_n == 2'd3) begin fst <= F_IDLE; rx_full <= 1'b1; rx_job <= f_job; end
                    end
                end
                default: fst <= F_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------ the drawing
    logic        p_on;
    logic  [3:0] p_k, p_wm1;
    logic [20:0] p_acc;                         // k * dx, 16.16
    logic [16:0] p_dx;
    logic [63:0] p_w;                           // {w0, w1, w2, w3}
    logic  [9:0] p_x0;
    logic        p_fx;
    logic  [5:0] p_col;
    assign rx_take = rx_full && (!p_on || p_k == p_wm1);

    wire   [3:0] s    = p_acc[19:16];                               // the source pixel
    wire  [15:0] sw_  = p_w[63 - 16 * s[3:2] -: 16];
    wire   [7:0] sb_  = s[1] ? sw_[7:0] : sw_[15:8];
    wire   [3:0] pen  = s[0] ? sb_[7:4] : sb_[3:0];
    wire   [9:0] px   = p_x0 + {6'd0, p_fx ? p_wm1 - p_k : p_k};
    wire   [8:0] pxm  = px[8:0];                                    // modulo 512
    wire         p_in = (pxm < 9'd320);

    always_ff @(posedge clk) begin
        lb_we <= 1'b0;
        if (reset || start) begin
            p_on <= 1'b0; p_k <= 4'd0;
            if (start) begin                        // the new line's bits (the other bank's are the line on display)
                if (bank) have1 <= '0; else have0 <= '0;
            end
        end else begin
            if (p_on) begin
                if (pen != 4'hf && p_in) begin
                    lb_we   <= 1'b1;
                    lb_addr <= {lbank, pxm};
                    lb_data <= {p_col, pen};
                    if (lbank) have1[pxm] <= 1'b1; else have0[pxm] <= 1'b1;
                end
                p_k   <= p_k + 4'd1;
                p_acc <= p_acc + {4'd0, p_dx};
                if (p_k == p_wm1) p_on <= 1'b0;
            end
            if (rx_take) begin
                p_on  <= 1'b1;
                p_k   <= 4'd0;
                p_acc <= 21'd0;
                p_dx  <= f_dx(rx_job[3:0]);
                p_w   <= rx;
                p_wm1 <= rx_job[3:0];
                p_x0  <= rx_job[QW-16 -: 10];
                p_fx  <= rx_job[10];
                p_col <= rx_job[9:4];
            end
        end
    end

    always_ff @(posedge clk) d_have <= d_bank ? have1[d_x] : have0[d_x];

    assign busy = (sst != S_IDLE && sst != S_DONE) || (q_n != 4'd0) || q_push || (fst != F_IDLE) || rx_full || p_on;

    wire unused = &{1'b0, t_q[63], t_q[47], t_q[31], t_q[15], r_j[8:4], r_prod[20], p_acc[20], a2[7:1], f_job[QW-1:15]};
endmodule
`default_nettype wire
