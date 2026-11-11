`timescale 1ns / 1ps

`include "libstf_macros.svh"

module StreamHasher #(
    parameter type tuple_t,
    parameter int NUM_TUPLES,
    parameter int HASH_WIDTH
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s   in, // #(tuple_t, NUM_TUPLES)
    ntagged_i.m out // #(tuple_t, logic[HASH_WIDTH - 1:0], NUM_TUPLES)
);

tuple_t key_probe;
localparam int KEY_WIDTH = $bits(key_probe.key);
localparam int NUM_PIPE_STAGES = 6;
localparam int INTERNAL_HASH_WIDTH = HASH_WIDTH > 32 ? 64 : 32;

`ASSERT_ELAB(NUM_TUPLES == in.NUM_ELEMENTS)
`ASSERT_ELAB(NUM_TUPLES == out.NUM_ELEMENTS)
`ASSERT_ELAB(HASH_WIDTH * NUM_TUPLES == $bits(out.tag))
`ASSERT_ELAB(HASH_WIDTH > 0 && HASH_WIDTH <= 64)

logic[INTERNAL_HASH_WIDTH - 1:0] internal_hashes[NUM_TUPLES];

for (genvar I = 0; I < NUM_TUPLES; I++) begin : gen_hashers
    MurMurHasher #(
        .KEY_WIDTH(KEY_WIDTH),
        .HASH_WIDTH(INTERNAL_HASH_WIDTH)
    ) inst_hasher (
        .clk(clk),

        .in_data(in.data[I].key),
        .in_ready(),

        .out_data(internal_hashes[I]),
        .out_ready(out.ready)
    );

    assign out.tag[I] = internal_hashes[I][0+:HASH_WIDTH];
end

// Shift registers with depth matching that of the hasher pipeline for all other values that we need
// for the output
ReadyShiftRegister #($bits(tuple_t) * NUM_TUPLES, NUM_PIPE_STAGES) inst_data_sr (
    .clk(clk),
    .rst_n(rst_n),

    .in_data(in.data),
    .in_ready(),

    .out_data(out.data),
    .out_ready(out.ready)
);

ReadyShiftRegister #(NUM_TUPLES, NUM_PIPE_STAGES) inst_keep_sr (
    .clk(clk),
    .rst_n(rst_n),

    .in_data(in.keep),
    .in_ready(),

    .out_data(out.keep),
    .out_ready(out.ready)
);

ReadyShiftRegister #(1, NUM_PIPE_STAGES) inst_last_sr (
    .clk(clk),
    .rst_n(rst_n),

    .in_data(in.last),
    .in_ready(),

    .out_data(out.last),
    .out_ready(out.ready)
);

ReadyShiftRegister #(1, NUM_PIPE_STAGES) inst_valid_sr (
    .clk(clk),
    .rst_n(rst_n),

    .in_data(in.valid),
    .in_ready(),

    .out_data(out.valid),
    .out_ready(out.ready)
);

assign in.ready = out.ready;

endmodule
