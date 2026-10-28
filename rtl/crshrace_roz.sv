//------------------------------------------------------------------------------
// Lethal Crash Race's K053936 layer (MAME's m_tilemap[0], "fg", drawn by k053936_device::zoom_draw), a line at a time into a line
// buffer: MAME 0.289's src/devices/video/k053936.cpp (its "simple" mode, the only one the game uses: it writes control word 7 with 0)
// and tilemap_t::draw_roz with wraparound (src/emu/tilemap.cpp), for one bitmap row.
//
// The tilemap: 64 x 64 tiles of 16 x 16 (1,024 x 1,024 pixels), scanned by rows; a tile is one VRAM 0 word: bits 11:0 the code,
// plus the tile bank (ffc001) * 0x1000 (get_fgtile_info; the 4 MB region holds 32,768 tiles: the sum modulo that), bits 15:12 the
// colour (palette 0x100 + colour * 16); 16 x 16 x 4 packed, msb first (gfx_16x16x4_packed_msb); pen 15 is transparent. MAME's region
// is 4 MB and the ROMs fill 3: tiles from 0x6000 on are zero there (pen 0).
//
// The walk (with the control words ctrl[0..6] as signed 16-bit values; set_offsets(-48, -21); set_wrap(1)):
//   incyx = ctrl[2], incyy = ctrl[3] (times 256 with ctrl[6] bit 14), incxx = ctrl[4], incxy = ctrl[5] (times 256 with bit 6)
//   cx(x, y) = 256 * ctrl[0] + 21 * incyx + 48 * incxx + y * incyx + x * incxx
//   cy(x, y) = 256 * ctrl[1] + 21 * incyy + 48 * incxy + y * incyy + x * incxy
//   MAME's bitmap pixel (x, y) is the tilemap's pixel ((cx >> 11) & 1023, (cy >> 11) & 1023)
// (MAME shifts the values left by 5 and takes bits 25:16 of the 32-bit sums: bits 20:11 of these; 21 bits are enough).
//
// The gfx in the SDRAM (rtl/crshrace_loader.sv) is stored in 4 x 4 pixel blocks: block {row[3:2], col[3:2]} of a tile is a 4-word
// burst at GFX_W + tile * 64 + block * 4, word i its row i (pixel 0 in bits 15:12). Blocks are kept in a 512-entry direct-mapped
// cache (indexed by the block's place in the tilemap, tagged with its place in the ROM), which serves the layer at any angle: a line
// at scale 1 crosses about 80 blocks, and the lines after it mostly the same ones.
//
// The work: a pipeline of four clocks (the pixel's tilemap position and its VRAM word, the tile and the cache's entry, the pen), a
// pixel a clock while the cache hits; a miss empties the pipeline, fetches the block and starts again from that pixel. Every x
// 0..319 is written ({colour, pen}; pen 15 is transparent), so the buffer needs no clearing.
//------------------------------------------------------------------------------
`default_nettype none

module crshrace_roz #(
    parameter logic [23:0] GFX_W = 24'h400000
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        start,          // one clock: render bitmap row `yb` into line buffer bank `bank` (aborts a render under way)
    input  logic  [7:0] yb,
    input  logic        bank,
    output logic        busy,

    input  logic [15:0] ctrl0, ctrl1, ctrl2, ctrl3, ctrl4, ctrl5, ctrl6,   // the frame's K053936 control words
    input  logic  [7:0] tbank,                                             // the frame's tile bank

    // the display copy of VRAM 0 (a word, two clocks after its address)
    output logic [11:0] v_addr,
    input  logic [15:0] v_q,

    // the SDRAM client
    output logic        m_req,
    output logic [23:0] m_addr,
    output logic  [4:0] m_len,
    input  logic        m_ack,
    input  logic        m_valid,
    input  logic [15:0] m_rdata,

    // the line buffer
    output logic        lb_we,
    output logic  [9:0] lb_addr,        // {bank, x}
    output logic  [7:0] lb_data         // {colour, pen}
);
    // ------------------------------------------------------------------ the line's set-up
    function automatic logic [20:0] inc(input logic [15:0] c, input logic big);
        inc = big ? {c[12:0], 8'd0} : {{5{c[15]}}, c};
    endfunction
    wire [20:0] ixx = inc(ctrl4, ctrl6[6]);
    wire [20:0] ixy = inc(ctrl5, ctrl6[6]);
    wire [20:0] iyx = inc(ctrl2, ctrl6[14]);
    wire [20:0] iyy = inc(ctrl3, ctrl6[14]);
    wire [20:0] s0  = {ctrl0[12:0], 8'd0} + (iyx << 4) + (iyx << 2) + iyx + (ixx << 5) + (ixx << 4);
    wire [20:0] s1  = {ctrl1[12:0], 8'd0} + (iyy << 4) + (iyy << 2) + iyy + (ixy << 5) + (ixy << 4);

    typedef enum logic [2:0] { R_IDLE, R_SET, R_SET2, R_RUN, R_FILL } rst_e;
    rst_e        rs;
    logic        lbank;
    logic  [7:0] ly;
    logic [20:0] dxx, dxy;                      // the per-pixel steps of the line
    logic [20:0] cx, cy;                        // the next pixel to issue
    logic [20:0] s0_q, s1_q, my_x, my_y;          // the line's set-up, registered (R_SET to R_SET2)
    logic  [8:0] ix;                            // its x (320: the line is issued)
    logic        issue;                         // a pixel enters the pipeline this clock

    // ------------------------------------------------------------------ the pipeline
    // issue: the VRAM address (registered); stage 2: VRAM 0's word is there: the tile, the cache index (registered); stage 4: the
    // cache's entry is there: the hit and the pen
    logic        p1_v, p2_v, p3_v, p4_v;
    logic  [8:0] p1_x, p2_x, p3_x, p4_x;
    logic [20:0] p1_cx, p2_cx, p3_cx, p4_cx;
    logic [20:0] p1_cy, p2_cy, p3_cy, p4_cy;
    logic  [3:0] p3_col, p4_col;                // the tile's colour
    logic [14:0] p3_tile, p4_tile;
    logic        p3_zero, p4_zero;              // past the ROMs: pen 0
    logic  [8:0] c_idx;

    // the cache: {valid, tile, block, the block's rows 0..3}
    (* ramstyle = "M10K,no_rw_check" *) logic [83:0] cmem [512];
    logic [83:0] c_q;
    logic        c_we;
    logic  [8:0] c_wa;
    logic [83:0] c_wd;
    always_ff @(posedge clk) begin
        if (c_we) cmem[c_wa] <= c_wd;
        c_q <= cmem[c_idx];
    end

    // the cache index of a pixel: its block's place in the tilemap, {block row[6:0], 00} ^ {00, block column[6:0]}
    function automatic logic [8:0] c_idx_of(input logic [20:0] fx, input logic [20:0] fy);
        c_idx_of = {fy[19:13], 2'b00} ^ {2'b00, fx[19:13]};
    endfunction

    // stage 2: the tile
    wire [14:0] p2_tile = {tbank[2:0], 12'd0} + {3'd0, v_q[11:0]};
    // stage 4: the hit and the pen
    wire  [9:0] p4_col_t = p4_cx[20:11], p4_row_t = p4_cy[20:11];
    wire  [3:0] p4_blk   = {p4_row_t[3:2], p4_col_t[3:2]};
    wire        hit      = p4_zero || (c_q[83] && c_q[82:64] == {p4_tile, p4_blk});
    wire [15:0] c_row    = c_q[16 * (2'd3 - p4_row_t[1:0]) +: 16];
    wire  [3:0] pen      = p4_zero ? 4'd0 : c_row[15 - 4 * p4_col_t[1:0] -: 4];
    wire        miss     = p4_v && !hit;

    logic  [8:0] sw;                            // the cache's sweep while the machine is in reset (a new image)
    logic  [1:0] f_n;
    logic [47:0] f_w;

    assign issue = (rs == R_RUN) && !miss && (ix != 9'd320);

    always_ff @(posedge clk) begin
        lb_we <= 1'b0;
        c_we  <= 1'b0;
        if (reset) begin
            rs <= R_IDLE; m_req <= 1'b0; ix <= 9'd320;
            p1_v <= 1'b0; p2_v <= 1'b0; p3_v <= 1'b0; p4_v <= 1'b0;
            c_we <= 1'b1; c_wa <= sw; c_wd <= 84'd0; sw <= sw + 9'd1;
        end else if (start) begin
            rs <= R_SET; m_req <= 1'b0; lbank <= bank; ly <= yb; ix <= 9'd320;
            p1_v <= 1'b0; p2_v <= 1'b0; p3_v <= 1'b0; p4_v <= 1'b0;
        end else begin
            // the stages (a miss empties them, below)
            p1_v <= issue; p1_x <= ix; p1_cx <= cx; p1_cy <= cy;
            v_addr <= {cy[20:15], cx[20:15]};
            p2_v <= p1_v; p2_x <= p1_x; p2_cx <= p1_cx; p2_cy <= p1_cy;
            p3_v <= p2_v; p3_x <= p2_x; p3_cx <= p2_cx; p3_cy <= p2_cy;
            p3_col <= v_q[15:12]; p3_tile <= p2_tile; p3_zero <= (p2_tile >= 15'h6000);
            c_idx <= c_idx_of(p2_cx, p2_cy);
            p4_v <= p3_v; p4_x <= p3_x; p4_cx <= p3_cx; p4_cy <= p3_cy;
            p4_col <= p3_col; p4_tile <= p3_tile; p4_zero <= p3_zero;

            if (p4_v && hit) begin
                lb_we   <= 1'b1;
                lb_addr <= {lbank, p4_x};
                lb_data <= {p4_col, pen};
            end

            case (rs)
                R_IDLE: ;
                R_SET: begin
                    // the line's first pixel, in two clocks
                    dxx <= ixx; dxy <= ixy;
                    s0_q <= s0; s1_q <= s1;
                    my_x <= 21'({13'd0, ly} * iyx);
                    my_y <= 21'({13'd0, ly} * iyy);
                    rs <= R_SET2;
                end
                R_SET2: begin
                    ix <= 9'd0;
                    cx <= s0_q + my_x;
                    cy <= s1_q + my_y;
                    rs <= R_RUN;
                end
                R_RUN: begin
                    if (miss) begin
                        // empty the pipeline, fetch the block, then start again from the missed pixel
                        p1_v <= 1'b0; p2_v <= 1'b0; p3_v <= 1'b0; p4_v <= 1'b0;
                        ix <= p4_x; cx <= p4_cx; cy <= p4_cy;
                        m_req  <= 1'b1;
                        m_addr <= GFX_W + {3'd0, p4_tile, p4_blk, 2'b00};
                        m_len  <= 5'd4;
                        c_wa   <= c_idx_of(p4_cx, p4_cy);
                        c_wd[83:64] <= {1'b1, p4_tile, p4_blk};
                        f_n    <= 2'd0;
                        rs     <= R_FILL;
                    end else if (issue) begin
                        ix <= ix + 9'd1; cx <= cx + dxx; cy <= cy + dxy;
                    end
                end
                R_FILL: begin
                    if (m_ack) m_req <= 1'b0;
                    if (m_valid) begin
                        f_w <= {f_w[31:0], m_rdata};
                        f_n <= f_n + 2'd1;
                        if (f_n == 2'd3) begin
                            c_we <= 1'b1;
                            c_wd[63:0] <= {f_w, m_rdata};
                            rs   <= R_RUN;
                        end
                    end
                end
                default: rs <= R_IDLE;
            endcase
        end
    end

    assign busy = (rs == R_SET) || (rs == R_SET2) || (rs == R_FILL) || (ix != 9'd320) || p1_v || p2_v || p3_v || p4_v;

    wire unused = &{1'b0, tbank[7:3], p3_cx[10:0], p3_cy[10:0], p4_cx[10:0], p4_cy[10:0]};
endmodule
`default_nettype wire
