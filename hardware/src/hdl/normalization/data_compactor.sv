`timescale 1ns / 1ps

`include "libstf_macros.svh"

module DataCompactor #(
    parameter type data_t,
    parameter NUM_ELEMENTS,
    parameter REGISTER_LEVELS = 8
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in, // #(data_t, NUM_ELEMENTS)
    ndata_i.m out // #(data_t, NUM_ELEMENTS)
);

localparam PIPELINE_STAGES = NUM_ELEMENTS + 1;
localparam COUNTER_WIDTH = $clog2(NUM_ELEMENTS);
localparam REGISTER_GAP = (REGISTER_LEVELS == 0 ? PIPELINE_STAGES + 2 : PIPELINE_STAGES / REGISTER_LEVELS);

ndata_i #(data_t, NUM_ELEMENTS) stages[PIPELINE_STAGES]();
logic[COUNTER_WIDTH - 1:0] counter_stages[PIPELINE_STAGES];

// Input assignments
`DATA_ASSIGN(in, stages[0])
assign counter_stages[0] = 0;

// Generate pipeline stages
for (genvar i = 0; i < PIPELINE_STAGES - 1; i++) begin
    DataCompactorLevel #(
        .ID(i), 
        .data_t(data_t), 
        .NUM_ELEMENTS(NUM_ELEMENTS), 
        .REGISTER(((i + 1) % REGISTER_GAP) == 0)
    ) inst_compactor_level (
        .clk(clk),
        .rst_n(rst_n),

        .in(stages[i]),
        .counter_in(counter_stages[i]),

        .out(stages[i + 1]),
        .counter_out(counter_stages[i + 1])
    );
end

// Output assignment
`DATA_ASSIGN(stages[PIPELINE_STAGES - 1], out)

endmodule
