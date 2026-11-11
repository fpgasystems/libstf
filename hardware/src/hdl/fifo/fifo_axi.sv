`timescale 1ns / 1ps

`include "libstf_macros.svh"

module FIFOAXI #(
    parameter int DEPTH,
    parameter int DATA_WIDTH = 512
) (
    input logic clk,
    input logic rst_n,

    AXI4S.s in,  // #(DATA_WIDTH)
    AXI4S.m out, // #(DATA_WIDTH)

    output logic[$clog2(DEPTH):0] filling_level
);

localparam int FIFO_WIDTH = DATA_WIDTH + DATA_WIDTH / 8 + 1;

`ASSERT_ELAB(DATA_WIDTH == in.AXI4S_DATA_BITS)
`ASSERT_ELAB(DATA_WIDTH == out.AXI4S_DATA_BITS)

MehdiFIFO #(DEPTH, FIFO_WIDTH, "ultra") inst_fifo (
    .clk(clk),
    .rst_n(rst_n),

    .in_data({in.tdata, in.tkeep, in.tlast}),
    .in_valid(in.tvalid),
    .in_ready(in.tready),

    .out_data({out.tdata, out.tkeep, out.tlast}),
    .out_valid(out.tvalid),
    .out_ready(out.tready),

    .filling_level(filling_level)
);

endmodule
