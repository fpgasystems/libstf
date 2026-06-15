`timescale 1ns / 1ps

import lynxTypes::*;

`include "libstf_macros.svh"

module BarrelShifter #(
    parameter type data_t,
    parameter NUM_ELEMENTS,
    parameter REGISTER_LEVELS = 0,
    parameter OFFSET_WIDTH = $clog2(NUM_ELEMENTS)
) (
    input logic clk,
    input logic rst_n,

    input logic[OFFSET_WIDTH - 1:0] offset,

    ndata_i.s in, // #(data_t, NUM_ELEMENTS)
    ndata_i.m out // #(data_t, NUM_ELEMENTS)
);

localparam int NUM_STAGES = $clog2(NUM_ELEMENTS);
localparam int NUM_PIPES  = NUM_STAGES + 1;

ndata_i #(data_t, NUM_ELEMENTS) pipes[NUM_PIPES](clk, rst_n);
logic[OFFSET_WIDTH - 1:0]       offset_pipes[NUM_PIPES];

// Input assignments
`DATA_ASSIGN(in, pipes[0])
assign offset_pipes[0] = offset;

// Generate pipeline stages
for (genvar i = 0; i < NUM_STAGES; i++) begin
    ConstantShifter #(
        .SHIFT_INDEX(i),
        .data_t(data_t),
        .NUM_ELEMENTS(NUM_ELEMENTS),
        .REGISTER(libstf::PUT_REGISTER_AT(i + 1, NUM_STAGES, REGISTER_LEVELS))
    ) inst_shifter (
        .clk(clk),
        .rst_n(rst_n),

        .in(pipes[i]),
        .offset_in(offset_pipes[i]),

        .out(pipes[i + 1]),
        .offset_out(offset_pipes[i + 1])
    );
end

// Output assignment
`DATA_ASSIGN(pipes[NUM_PIPES - 1], out)

endmodule
