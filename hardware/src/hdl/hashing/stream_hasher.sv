`timescale 1ns / 1ps

import lynxTypes::*;

module StreamHasher #(
    parameter type tuple_t,
    parameter NUM_TUPLES,
    parameter HASH_WIDTH
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s   in, // #(tuple_t, NUM_TUPLES)
    ntagged_i.m out // #(tuple_t, NUM_TUPLES, HASH_WIDTH) 
);

localparam KEY_WIDTH = $bits(tuple_t.key);
localparam NUM_PIPE_STAGES = 6;
localparam INTERNAL_HASH_WIDTH = HASH_WIDTH > 32 ? 64 : 32;

logic[INTERNAL_HASH_WIDTH - 1:0] internal_hashes[NUM_TUPLES];

for (genvar I = 0; I < NUM_TUPLES; I++) begin
    MurMurHasher #(
        .KEY_WIDTH(KEY_WIDTH),
        .HASH_WIDTH(INTERNAL_HASH_WIDTH)
    ) inst_hasher (
        .clk(clk),

        .i_data(in.data[I].key),
        .o_data_ready(),

        .o_data(internal_hashes[I]),
        .i_data_ready(out.ready)
    );

    assign out.tag[I] = internal_hashes[I][0+:HASH_WIDTH];
end

// Shift registers with depth matching that of the hasher pipeline for all other values that we need for the output
ReadyShiftRegister #($bits(tuple_t) * NUM_TUPLES, NUM_PIPE_STAGES) inst_data_sr (
    .i_clk(clk),
    .i_rst_n(rst_n),

    .i_data(in.data),
    .o_ready(),

    .o_data(out.data),
    .i_ready(out.ready)
);

ReadyShiftRegister #(NUM_TUPLES, NUM_PIPE_STAGES) inst_keep_sr (
    .i_clk(clk),
    .i_rst_n(rst_n),

    .i_data(in.keep),
    .o_ready(),

    .o_data(out.keep),
    .i_ready(out.ready)
);

ReadyShiftRegister #(1, NUM_PIPE_STAGES) inst_last_sr (
    .i_clk(clk),
    .i_rst_n(rst_n),

    .i_data(in.last),
    .o_ready(),

    .o_data(out.last),
    .i_ready(out.ready)
);

ReadyShiftRegister #(1, NUM_PIPE_STAGES) inst_valid_sr (
    .i_clk(clk),
    .i_rst_n(rst_n),

    .i_data(in.valid),
    .o_ready(),

    .o_data(out.valid),
    .i_ready(out.ready)
);

assign in.ready = out.ready;

endmodule
