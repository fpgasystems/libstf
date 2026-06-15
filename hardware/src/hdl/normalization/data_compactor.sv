`timescale 1ns / 1ps

`include "libstf_macros.svh"

module DataCompactor #(
    parameter type data_t,
    parameter NUM_ELEMENTS,
    parameter REGISTER_LEVELS = 1
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in, // #(data_t, NUM_ELEMENTS)
    ndata_i.m out // #(data_t, NUM_ELEMENTS)
);

localparam NUM_STAGES = NUM_ELEMENTS;
localparam NUM_PIPES  = NUM_STAGES + 1;

localparam COUNTER_WIDTH = $clog2(NUM_ELEMENTS);

ndata_i #(data_t, NUM_ELEMENTS) pipes[NUM_PIPES](clk, rst_n);
logic[COUNTER_WIDTH - 1:0]      counter_pipes[NUM_PIPES];

// Input assignments
`DATA_ASSIGN(in, pipes[0])
assign counter_pipes[0] = 0;

// Generate pipeline stages
for (genvar i = 0; i < NUM_STAGES; i++) begin
    DataCompactorLevel #(
        .ID(i),
        .data_t(data_t),
        .NUM_ELEMENTS(NUM_ELEMENTS),
        .REGISTER(libstf::PUT_REGISTER_AT(i + 1, NUM_STAGES, REGISTER_LEVELS))
    ) inst_compactor_level (
        .clk(clk),
        .rst_n(rst_n),

        .in(pipes[i]),
        .counter_in(counter_pipes[i]),

        .out(pipes[i + 1]),
        .counter_out(counter_pipes[i + 1])
    );
end

// Output assignment
`DATA_ASSIGN(pipes[NUM_PIPES - 1], out)

endmodule
