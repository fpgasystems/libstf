`timescale 1ns / 1ps

`include "libstf_macros.svh"

module Crossbar #(
    parameter type data_t,
    parameter NUM_INPUTS,
    parameter NUM_OUTPUTS,
    parameter LAST_HANDLING   = 1, // Handling of the last signal by the Multiplexer
    parameter FILTER_KEEP     = 1, // If the Multiplexer filters by keep signal
    parameter NUM_SKID_STAGES = 4,
    parameter TAG_WIDTH       = $clog2(NUM_OUTPUTS)
) (
    input logic clk,
    input logic rst_n,

    tagged_i.s in[NUM_INPUTS],  // #(data_t, TAG_WIDTH)
    data_i.m   out[NUM_OUTPUTS] // #(data_t)
);

// We need this generate wrapper to fix some issue that we found in ParCore. 
// We did not find a good explanation why we need it though.
generate

`RESET_RESYNC // Reset pipelining

tagged_i #(data_t, TAG_WIDTH) skid_pipe[NUM_INPUTS][NUM_SKID_STAGES + 1]();
tagged_i #(data_t, TAG_WIDTH) duplicator_out[NUM_INPUTS][NUM_OUTPUTS]();
tagged_i #(data_t, TAG_WIDTH) mux_in[NUM_OUTPUTS][NUM_INPUTS]();

logic[NUM_INPUTS-1:0][NUM_OUTPUTS-1:0] mux_ready_transposed;
    
for (genvar I = 0; I < NUM_INPUTS; I++) begin
    assign in[I].ready = skid_pipe[I][0].ready;
    
    assign skid_pipe[I][0].data  = in[I].data;
    assign skid_pipe[I][0].tag   = in[I].tag;
    assign skid_pipe[I][0].keep  = in[I].keep;
    assign skid_pipe[I][0].last  = in[I].last;
    assign skid_pipe[I][0].valid = in[I].valid;
end

// SkidBuffer pipeline
for (genvar I = 0; I < NUM_INPUTS; I++) begin
    for (genvar J = 0; J < NUM_SKID_STAGES; J++) begin
        TaggedSkidBuffer #(data_t, TAG_WIDTH) inst_skid_buffer (.clk(clk), .rst_n(reset_synced), .in(skid_pipe[I][J]), .out(skid_pipe[I][J + 1]));
    end
end

// Multiplexers
for (genvar I = 0; I < NUM_INPUTS; I++) begin
    TaggedDuplicator #(
        .NUM_STREAMS(NUM_OUTPUTS)
    ) inst_duplicator (
        .clk(clk),
        .rst_n(reset_synced),

        .in(skid_pipe[I][NUM_SKID_STAGES]),
        .out(duplicator_out[I])
    );

    for(genvar O = 0; O < NUM_OUTPUTS; O++) begin
        assign duplicator_out[I][O].ready = mux_in[O][I].ready;

        assign mux_in[O][I].data  = duplicator_out[I][O].data;
        assign mux_in[O][I].tag   = duplicator_out[I][O].tag;
        assign mux_in[O][I].keep  = duplicator_out[I][O].keep;
        assign mux_in[O][I].last  = duplicator_out[I][O].last;
        assign mux_in[O][I].valid = duplicator_out[I][O].valid;
    end
end 

for (genvar O = 0; O < NUM_OUTPUTS; O++) begin
    TaggedMultiplexer #(
        .data_t(data_t),
        .ID(O),
        .NUM_INPUTS(NUM_INPUTS),
        .TAG_WIDTH(TAG_WIDTH),
        .LAST_HANDLING(LAST_HANDLING),
        .FILTER_KEEP(FILTER_KEEP)
    ) inst_mux (
        .clk(clk),
        .rst_n(reset_synced),

        .in(mux_in[O]),
        .out(out[O])
    );
end 

endgenerate

endmodule
