//------------------------------------------------------------------------------
// Lethal Crash Race's char layer (MAME's m_tilemap[1], "bg"), a line at a time into a line buffer: MAME 0.289's tilemap for one
// bitmap row (src/mame/vsystem/crshrace.cpp get_bgtile_info, src/emu/tilemap.cpp).
//
// 64 x 64 tiles of 8 x 8, scanned by rows, never scrolled: MAME's bitmap pixel (x, y) is the layer's pixel (x, y), so only the top
// left 40 x 28 tiles are ever seen (VRAM 1 holds 2 K words: rows 0..31). A tile is one VRAM word, its code (the 1 MB region holds
// 16,384 tiles: the code modulo that), colour 0; the gfx is 8 x 8 x 8 raw (gfx_8x8x8_raw: a pixel a byte, 64 bytes a tile), the pen
// the palette entry itself (colour base 0); pen 0xff is transparent (set_transparent_pen(0xff)).
//
// The gfx in the SDRAM (rtl/crshrace_loader.sv): a tile row is a 4-word burst at GFX_W + code * 32 + row * 4 (pixel 0 in bits 15:8
// of word 0). The line: 40 tiles; one tile's VRAM read and SDRAM burst while the one before is written to the line buffer, a pixel a
// clock. Every x 0..319 is written (the clear pixels with pen 0xff), so the buffer needs no clearing.
//------------------------------------------------------------------------------
`default_nettype none

module crshrace_chars #(
    parameter logic [23:0] GFX_W = 24'h200000
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        start,          // one clock: render bitmap row `yb` into line buffer bank `bank` (aborts a render under way)
    input  logic  [7:0] yb,
    input  logic        bank,
    output logic        busy,

    // the display copy of VRAM 1 (a word, two clocks after its address)
    output logic [10:0] v_addr,
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
    output logic  [7:0] lb_data
);
    // ------------------------------------------------------------------ stage A: the VRAM read and the SDRAM burst
    typedef enum logic [2:0] { A_IDLE, A_VRD, A_VQ, A_REQ, A_WAIT } ast_e;
    ast_e        ast;
    logic        lbank;
    logic  [7:0] ty;
    logic  [5:0] t, a_t;                        // the tile being fetched (0..39)
    logic  [1:0] rx_n;
    logic        rx_full;                       // a whole tile row is waiting for stage B
    logic [63:0] rx;                            // the words, word 0 in bits 63:48
    logic  [5:0] rx_t;
    logic        rx_take;                       // stage B takes it (this clock)

    always_ff @(posedge clk) begin
        if (reset || start) begin
            ast <= start ? A_VRD : A_IDLE;
            m_req <= 1'b0; rx_n <= 2'd0; rx_full <= 1'b0;
            t <= 6'd0;
            if (start) begin lbank <= bank; ty <= yb; end
        end else begin
            if (rx_take) rx_full <= 1'b0;
            case (ast)
                A_IDLE: ;
                A_VRD: begin v_addr <= {ty[7:3], t}; ast <= A_VQ; end
                A_VQ: ast <= A_REQ;                     // the RAM takes the address at this edge; its word is there in the next clock
                A_REQ: begin
                    // the next burst only once the last one's words have gone on to stage B
                    if (!rx_full || rx_take) begin
                        m_req  <= 1'b1;
                        m_addr <= GFX_W + {5'd0, v_q[13:0], ty[2:0], 2'b00};
                        m_len  <= 5'd4;
                        a_t    <= t;
                        rx_n   <= 2'd0;
                        ast    <= A_WAIT;
                    end
                end
                A_WAIT: begin
                    if (m_ack) m_req <= 1'b0;
                    if (m_valid) begin
                        rx <= {rx[47:0], m_rdata};
                        rx_n <= rx_n + 2'd1;
                        if (rx_n == 2'd3) begin
                            rx_full <= 1'b1; rx_t <= a_t;
                            if (t == 6'd39) ast <= A_IDLE;
                            else begin t <= t + 6'd1; ast <= A_VRD; end
                        end
                    end
                end
                default: ast <= A_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------ stage B: the pixels into the line buffer
    logic        b_on;
    logic  [2:0] b_i;
    logic [63:0] b_w;
    logic  [8:0] b_x0;
    assign rx_take = rx_full && (!b_on || b_i == 3'd7);

    always_ff @(posedge clk) begin
        lb_we <= 1'b0;
        if (reset || start) begin
            b_on <= 1'b0; b_i <= 3'd0;
        end else begin
            if (b_on) begin
                lb_we   <= 1'b1;
                lb_addr <= {lbank, b_x0 + {6'd0, b_i}};
                lb_data <= b_w[63 - 8 * b_i -: 8];
                b_i <= b_i + 3'd1;
                if (b_i == 3'd7) b_on <= 1'b0;
            end
            if (rx_take) begin
                b_on <= 1'b1;
                b_i  <= 3'd0;
                b_w  <= rx;
                b_x0 <= {rx_t, 3'b000};
            end
        end
    end

    assign busy = (ast != A_IDLE) || rx_full || b_on;

    wire unused = &{1'b0, v_q[15:14]};
endmodule
`default_nettype wire
