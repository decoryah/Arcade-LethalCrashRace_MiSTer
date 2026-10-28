//------------------------------------------------------------------------------
// Block RAMs of the Crash Race core, written in the forms Quartus infers as M10K (registered address, registered output).
//   crshrace_spram: one port, read and write
//   crshrace_dpram: port A read and write, port B read only
//   crshrace_bram:  NB byte lanes (each its own crshrace_dpram), port A read and write with a byte enable per lane, port B read
//                   only: the 68000's memories (a 16-bit word with its UDS / LDS lanes) and the video's 64-bit wide ones
//------------------------------------------------------------------------------
`default_nettype none

module crshrace_spram #(
    parameter int AW = 13,
    parameter int DW = 8
) (
    input  logic          clk,
    input  logic [AW-1:0] addr,
    input  logic [DW-1:0] wdata,
    input  logic          we,
    output logic [DW-1:0] q
);
    logic [DW-1:0] mem [1 << AW];
    always_ff @(posedge clk) begin
        if (we) mem[addr] <= wdata;
        q <= mem[addr];
    end
endmodule

module crshrace_dpram #(
    parameter int AW = 11,
    parameter int DW = 8
) (
    input  logic          clk,
    input  logic [AW-1:0] a_addr,
    input  logic [DW-1:0] a_wdata,
    input  logic          a_we,
    output logic [DW-1:0] a_q,
    input  logic [AW-1:0] b_addr,
    output logic [DW-1:0] b_q
);
    logic [DW-1:0] mem [1 << AW];
`ifdef VERILATOR
    initial for (int i = 0; i < (1 << AW); i++) mem[i] = '0;     // the bench's (a block RAM powers up 0, as MAME's memory)
`endif
    always_ff @(posedge clk) begin
        if (a_we) mem[a_addr] <= a_wdata;
        a_q <= mem[a_addr];
    end
    always_ff @(posedge clk) b_q <= mem[b_addr];
endmodule

// one byte lane of crshrace_bram: a true dual-port block (port A read and write, port B read). Quartus does not infer one from
// crshrace_dpram's form (it builds two simple dual-port copies, one per read port: twice the blocks), so it is instantiated
// for the build; the benches use crshrace_dpram
module crshrace_tdpram #(
    parameter int AW = 11
) (
    input  logic          clk,
    input  logic [AW-1:0] a_addr,
    input  logic    [7:0] a_wdata,
    input  logic          a_we,
    output logic    [7:0] a_q,
    input  logic [AW-1:0] b_addr,
    output logic    [7:0] b_q
);
`ifdef VERILATOR
    crshrace_dpram #(.AW(AW), .DW(8)) u_m (.clk(clk), .a_addr(a_addr), .a_wdata(a_wdata), .a_we(a_we), .a_q(a_q),
                                          .b_addr(b_addr), .b_q(b_q));
`else
    altsyncram #(
        .operation_mode("BIDIR_DUAL_PORT"), .intended_device_family("Cyclone V"), .lpm_type("altsyncram"),
        .ram_block_type("M10K"), .power_up_uninitialized("FALSE"),
        .width_a(8), .widthad_a(AW), .numwords_a(1 << AW), .width_b(8), .widthad_b(AW), .numwords_b(1 << AW),
        .width_byteena_a(1), .width_byteena_b(1),
        .outdata_reg_a("UNREGISTERED"), .outdata_reg_b("UNREGISTERED"),
        .address_reg_b("CLOCK0"), .indata_reg_b("CLOCK0"), .wrcontrol_wraddress_reg_b("CLOCK0"),
        .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"), .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_mixed_ports("DONT_CARE")
    ) u_m (
        .clock0(clk), .address_a(a_addr), .data_a(a_wdata), .wren_a(a_we), .q_a(a_q),
        .address_b(b_addr), .data_b(8'd0), .wren_b(1'b0), .q_b(b_q),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0), .byteena_a(1'b1), .byteena_b(1'b1),
        .clock1(1'b1), .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(1'b1),
        .rden_b(1'b1)
    );
`endif
endmodule

module crshrace_bram #(
    parameter int AW = 9,
    parameter int NB = 8                // byte lanes: lane i is bits 8i+7:8i
) (
    input  logic            clk,
    input  logic [AW-1:0]   a_addr,
    input  logic [NB*8-1:0] a_wdata,
    input  logic [NB-1:0]   a_be,       // the lanes written (with a_we)
    input  logic            a_we,
    output logic [NB*8-1:0] a_q,
    input  logic [AW-1:0]   b_addr,
    output logic [NB*8-1:0] b_q
);
    genvar i;
    generate
        for (i = 0; i < NB; i++) begin : g_lane
            crshrace_tdpram #(.AW(AW)) u_l (
                .clk(clk), .a_addr(a_addr), .a_wdata(a_wdata[i*8 +: 8]), .a_we(a_we && a_be[i]), .a_q(a_q[i*8 +: 8]),
                .b_addr(b_addr), .b_q(b_q[i*8 +: 8])
            );
        end
    endgenerate
endmodule
`default_nettype wire
