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

localparam int PIPELINE_STAGES = $clog2(NUM_ELEMENTS) + 1;
localparam int REGISTER_GAP = (REGISTER_LEVELS == 0 ? PIPELINE_STAGES + 2 : PIPELINE_STAGES / REGISTER_LEVELS);

ndata_i #(data_t, NUM_ELEMENTS) stages[PIPELINE_STAGES]();
logic[OFFSET_WIDTH - 1:0] offset_stages[PIPELINE_STAGES];

// Input assignments
`DATA_ASSIGN(in, stages[0])
assign offset_stages[0] = offset;

// Generate pipeline stages
for (genvar i = 0; i < PIPELINE_STAGES - 1; i++) begin
    ConstantShifter #(.SHIFT_INDEX(i), .data_t(data_t), .NUM_ELEMENTS(NUM_ELEMENTS), .REGISTER(((i + 1) % REGISTER_GAP) == 0)) inst_shifter (
        .clk(clk),
        .rst_n(rst_n),

        .in(stages[i]),
        .offset_in(offset_stages[i]),

        .out(stages[i + 1]),
        .offset_out(offset_stages[i + 1])
    );
end

// Output assignment
`DATA_ASSIGN(stages[PIPELINE_STAGES - 1], out)

endmodule
