//------------------------------------------------------------------------------
// The ROM image's way in: the HPS download (or the fast load) arrives a byte at a time at its image offset; this module puts each
// byte at its place in the SDRAM. Everything of this board's ROMs lives in the SDRAM (the CPUs read their programs through caches).
//
// The image (mra/*.mra, tools/crshrace_rom.py): MAME 0.289's regions in MAME's byte order (the ROM_LOAD16_WORD_SWAP files are
// swapped back by the MRA, so a 16-bit word's high byte is the even byte), the same layout for every set:
//   0x000000  maincpu    512 KB  1.ic10 / 01.ic10 (the 68000's program, big-endian words)
//   0x080000  user1        1 MB  w21.ic14 (the 68000's data ROM at 300000)
//   0x180000  user2        1 MB  w22.ic13 (the 68000's data ROM at 400000, mirrored at 500000)
//   0x280000  audiocpu   128 KB  2.ic58 (the Z80's program and its banks)
//   0x2A0000  chars        1 MB  h895.ic50 (8 x 8 x 8, 64 bytes a tile)
//   0x3A0000  tiles        3 MB  w18.rom-a, w19.rom-b, w20.rom-c (16 x 16 x 4 packed, 128 bytes a tile; MAME's region is 4 MB, the
//                                last quarter empty)
//   0x6A0000  sprites      4 MB  h897.ic29, h896.ic75 (16 x 16 x 4 packed, 128 bytes a tile)
//   0xAA0000  adpcmb       1 MB  h894.ic73 (the YM2610's ADPCM-B samples)
//   0xBA0000  adpcma       1 MB  h893.ic69 (its ADPCM-A samples)
//   0xCA0000  (end)
//
// The SDRAM (byte addresses): maincpu, user1, user2 and audiocpu at their image offsets; the chars at 0x400000, the tiles at 0x800000,
// the sprites at 0xC00000, ADPCM-A at 0x1000000 and ADPCM-B at 0x1100000. The tiles are stored in 4 x 4 pixel blocks, so the
// K053936 layer (rtl/crshrace_roz.sv) reads a block with one 4-word burst whichever way the layer is turned: within a tile's 128
// bytes, MAME's byte {row[3:0], word[1:0], byte} (row, the word of the row (4 pixels), its byte) goes to {row[3:2], word[1:0],
// row[1:0], byte}. Byte pairs (even, odd) stay pairs, in order, as the SDRAM's download FIFO wants them.
//------------------------------------------------------------------------------
`default_nettype none

module crshrace_loader (
    input  logic        clk,
    input  logic        dl_wr,                 // one clock per byte
    input  logic [23:0] dl_addr,               // image offset
    input  logic  [7:0] dl_data,
    output logic        o_wr,                  // to the SDRAM's download port
    output logic [24:0] o_addr,
    output logic  [7:0] o_data
);
    localparam logic [23:0] CHARS = 24'h2A0000, TILES = 24'h3A0000, SPR = 24'h6A0000, ADPB = 24'hAA0000, ADPA = 24'hBA0000,
                            END = 24'hCA0000;

    wire [23:0] bc = dl_addr - CHARS;
    wire [23:0] bt = dl_addr - TILES;
    wire [23:0] bs = dl_addr - SPR;
    wire [23:0] bb = dl_addr - ADPB;
    wire [23:0] ba = dl_addr - ADPA;
    wire unused = &{1'b0, bc[23:20], bt[23:22], bs[23:22], bb[23:20], ba[23:20]};
    always_ff @(posedge clk) begin
        o_wr   <= 1'b0;
        o_data <= dl_data;
        if (dl_wr && dl_addr < END) begin
            o_wr <= 1'b1;
            if      (dl_addr < CHARS) o_addr <= {1'b0, dl_addr};                                                   // the CPUs
            else if (dl_addr < TILES) o_addr <= 25'h0400000 + {5'd0, bc[19:0]};
            else if (dl_addr < SPR)   o_addr <= 25'h0800000 + {3'd0, bt[21:7], bt[6:5], bt[2:1], bt[4:3], bt[0]};  // 4 x 4 blocks
            else if (dl_addr < ADPB)  o_addr <= 25'h0C00000 + {3'd0, bs[21:0]};
            else if (dl_addr < ADPA)  o_addr <= 25'h1100000 + {5'd0, bb[19:0]};
            else                      o_addr <= 25'h1000000 + {5'd0, ba[19:0]};
        end
    end
endmodule
`default_nettype wire
