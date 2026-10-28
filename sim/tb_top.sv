// The whole-machine bench: crshrace_core behind crshrace_sdram and the behavioural SDRAM (sim/sdram_model.sv). The ROM image
// (+IMAGE=<file>, tools/crshrace_rom.py) is downloaded first through crshrace_loader, a byte a clock while the SDRAM's download FIFO
// takes them, with the machine held in reset, as CrashRace.sv does it; then the machine runs. +FLIP turns the picture. Driven by
// sim/tb_crshrace.cpp.
`default_nettype none
module tb_top (
    input  logic        clk,
    input  logic        reset_in,
    input  logic [15:0] in_p1,
    input  logic  [7:0] in_p2,
    output logic        ce_pix,
    output logic        hblank,
    output logic        vblank,
    output logic        hs,
    output logic        vs,
    output logic  [7:0] r,
    output logic  [7:0] g,
    output logic  [7:0] b,
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,
    output logic        frame_tick,
    output logic        running,
    output logic        loaded,
    output logic [23:0] dbg_pc
);
    // ------------------------------------------------------------------ the image
    logic [7:0] img [1 << 24];
    int         img_len = 0;
    logic       flip = 1'b0;
    initial begin
        string f;
        int fd;
        if ($value$plusargs("IMAGE=%s", f)) begin
            fd = $fopen(f, "rb");
            if (fd == 0) begin $display("tb: cannot open %s", f); $finish; end
            img_len = $fread(img, fd);
            $fclose(fd);
            $display("tb: image %0d bytes from %s", img_len, f);
        end else begin
            $display("tb: no +IMAGE=<file>"); $finish;
        end
        flip = $test$plusargs("FLIP");
    end

    // ------------------------------------------------------------------ the SDRAM
    localparam int NC = 7;
    logic        m_req [NC], m_ack [NC], m_valid [NC];
    logic [23:0] m_addr [NC];
    logic  [4:0] m_len [NC];
    logic [15:0] m_rdata;
    logic        sd_ready, dl_busy;
    wire  [15:0] SDRAM_DQ;
    logic [12:0] SDRAM_A;
    logic  [1:0] SDRAM_BA;
    logic        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, SDRAM_CKE;

    logic        ld_wr;
    logic [24:0] ld_addr;
    logic  [7:0] ld_data;

    crshrace_sdram #(.P_SHORT_INIT(1'b1), .NC(NC)) u_sdram (
        .clk(clk), .rst_n(!reset_in), .o_ready(sd_ready), .i_rd_late(1'b0),
        .i_dl_wr(ld_wr), .i_dl_addr(ld_addr), .i_dl_data(ld_data), .o_dl_busy(dl_busy),
        .c_req(m_req), .c_addr(m_addr), .c_len(m_len), .c_ack(m_ack), .c_valid(m_valid), .o_rdata(m_rdata),
        .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE)
    );
    sdram_model u_sdr (
        .clk(clk), .A(SDRAM_A), .BA(SDRAM_BA), .DQ(SDRAM_DQ), .DQML(SDRAM_DQML), .DQMH(SDRAM_DQMH),
        .nCS(SDRAM_nCS), .nRAS(SDRAM_nRAS), .nCAS(SDRAM_nCAS), .nWE(SDRAM_nWE), .CKE(SDRAM_CKE)
    );

    // ------------------------------------------------------------------ the download
    int          dl_i = 0;
    logic        dl_wr;
    logic [23:0] dl_addr;
    logic  [7:0] dl_data;
    wire         dl_on = (dl_i < img_len);
    always_ff @(posedge clk) begin
        dl_wr <= 1'b0;
        if (!reset_in && sd_ready && dl_on && !dl_busy && !dl_wr) begin
            dl_wr <= 1'b1; dl_addr <= 24'(dl_i); dl_data <= img[dl_i];
            dl_i <= dl_i + 1;
        end
    end

    crshrace_loader u_loader (
        .clk(clk), .dl_wr(dl_wr), .dl_addr(dl_addr), .dl_data(dl_data),
        .o_wr(ld_wr), .o_addr(ld_addr), .o_data(ld_data)
    );

    // ------------------------------------------------------------------ the machine
    logic mc_reset;
    logic [9:0] tail;           // after the last byte, for the loader's and the FIFO's last writes
    always_ff @(posedge clk) begin
        if (reset_in || dl_on || dl_wr || dl_busy) tail <= 10'd0;
        else if (tail != 10'h3ff) tail <= tail + 10'd1;
        mc_reset <= reset_in || !sd_ready || (tail != 10'h3ff);
    end
    assign loaded = !mc_reset;

    logic vblank_next_unused;
    crshrace_core u_core (
        .clk(clk), .rst_raster(reset_in), .reset(mc_reset), .flip(flip),
        .m_req(m_req), .m_addr(m_addr), .m_len(m_len), .m_ack(m_ack), .m_valid(m_valid), .m_rdata(m_rdata),
        .in_p1(in_p1), .in_p2(in_p2), .in_p3(8'hff), .dsw0(16'hffff), .dsw1(8'hff), .region(4'd1),
        .ce_pix(ce_pix), .hs(hs), .vs(vs), .hblank(hblank), .vblank(vblank), .vblank_next(vblank_next_unused), .r(r), .g(g), .b(b),
        .audio_l(audio_l), .audio_r(audio_r), .running(running), .frame_tick(frame_tick), .dbg_pc(dbg_pc)
    );

    // +IRQLOG: "Q <frame> <event>" at the IRQ line rising and at its acknowledge; the 68000's mask
    logic irq_d = 1'b0;
    always_ff @(posedge clk) if ($test$plusargs("IRQLOG") && running) begin
        irq_d <= u_core.irq1;
        if (u_core.irq1 && !irq_d) $display("Q %0d rise pc %06x", frame, dbg_pc);
        if (u_core.cs && u_core.iack) $display("Q %0d iack A=%06x", frame, u_core.A);
        if (frame_tick) $display("Q %0d vbl irq1=%0d pend=%0d owed=%0d", frame, u_core.irq1, u_core.irq_pend, u_core.owed);
    end

    // +VLOG: "V <frame> <address> <data> <lanes>" at each write to fff000-fff03f
    always_ff @(posedge clk) if ($test$plusargs("VLOG") && running && u_core.wr_go && u_core.A[23:6] == 18'h3ffc0)
        $display("V %0d %06x %04x %b", frame, u_core.A, u_core.cpu_dout, u_core.wr_be);

    // +SNDLOG: "L <frame> <byte>" at each sound command
    int frame = 0;
    always_ff @(posedge clk) begin
        if (frame_tick) frame <= frame + 1;
        if ($test$plusargs("SNDLOG") && running && u_core.latch_wr) $display("L %0d %02x", frame, u_core.latch_din);
    end
endmodule
`default_nettype wire
