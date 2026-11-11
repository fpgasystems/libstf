`timescale 1ns / 1ps

`include "libstf_macros.svh"

module BarrelShifter #(
    parameter type data_t,
    parameter int NUM_ELEMENTS,
    parameter int REGISTER_LEVELS = 0,
    parameter int OFFSET_WIDTH = $clog2(NUM_ELEMENTS)
) (
    input logic clk,
    input logic rst_n,

    input logic[OFFSET_WIDTH - 1:0] offset,

    ndata_i.s in, // #(data_t, NUM_ELEMENTS)
    ndata_i.m out // #(data_t, NUM_ELEMENTS)
);

`ASSERT_ELAB(NUM_ELEMENTS == in.NUM_ELEMENTS)

localparam int NUM_STAGES = $clog2(NUM_ELEMENTS);
localparam int NUM_PIPES  = NUM_STAGES + 1;

ndata_i #(data_t, NUM_ELEMENTS) pipes[NUM_PIPES](clk, rst_n);
logic[OFFSET_WIDTH - 1:0]       offset_pipes[NUM_PIPES];

// Input assignments
`DATA_ASSIGN(in, pipes[0])
assign offset_pipes[0] = offset;

// Generate pipeline stages
for (genvar I = 0; I < NUM_STAGES; I++) begin : gen_stages
    ConstantShifter #(
        .SHIFT_INDEX(I),
        .data_t(data_t),
        .NUM_ELEMENTS(NUM_ELEMENTS),
        .REGISTER(libstf::PUT_REGISTER_AT(I + 1, NUM_STAGES, REGISTER_LEVELS))
    ) inst_shifter (
        .clk(clk),
        .rst_n(rst_n),

        .in(pipes[I]),
        .offset_in(offset_pipes[I]),

        .out(pipes[I + 1]),
        .offset_out(offset_pipes[I + 1])
    );
end

// Output assignment
`DATA_ASSIGN(pipes[NUM_PIPES - 1], out)

endmodule
