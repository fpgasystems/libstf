`timescale 1ns / 1ps

`include "libstf_macros.svh"

module FIFOAXI #(
    parameter int DEPTH
) (
    input logic clk,
    input logic rst_n,

    AXI4S.s i_data,
    AXI4S.m o_data,

    output logic[$clog2(DEPTH):0] filling_level
);

localparam int DATA_WIDTH = o_data.AXI4S_DATA_BITS;

localparam int FIFO_WIDTH = DATA_WIDTH + DATA_WIDTH / 8 + 1;

`ASSERT_ELAB(i_data.AXI4S_DATA_BITS == DATA_WIDTH)

MehdiFIFO #(DEPTH, FIFO_WIDTH, "ultra") inst_fifo (
    .i_clk(clk),
    .i_rst_n(rst_n),

    .i_data({i_data.tdata, i_data.tkeep, i_data.tlast}),
    .i_valid(i_data.tvalid),
    .i_ready(i_data.tready),

    .o_data({o_data.tdata, o_data.tkeep, o_data.tlast}),
    .o_valid(o_data.tvalid),
    .o_ready(o_data.tready),

    .o_filling_level(filling_level)
);

endmodule
