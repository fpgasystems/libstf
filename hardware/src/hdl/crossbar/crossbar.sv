`timescale 1ns / 1ps

`include "libstf_macros.svh"

module Crossbar #(
    parameter type data_t,
    parameter type tag_t,  // the tag type of the inputs
    parameter int NUM_INPUTS,
    parameter int NUM_OUTPUTS,
    parameter int LAST_HANDLING   = 1, // Handling of the last signal by the Multiplexer
    parameter int FILTER_KEEP     = 1, // If the Multiplexer filters by keep signal
    parameter int NUM_SKID_STAGES = 4
) (
    input logic clk,
    input logic rst_n,

    tagged_i.s in[NUM_INPUTS],  // #(data_t, tag_t)
    data_i.m   out[NUM_OUTPUTS] // #(data_t)
);

// We need this generate wrapper to fix some issue that we found in ParCore.
// We did not find a good explanation why we need it though.
generate

`RESET_RESYNC // Reset pipelining

// The tag selects the output
`ASSERT_ELAB($bits(tag_t) >= $clog2(NUM_OUTPUTS))

tagged_i #(data_t, tag_t) skid_pipe[NUM_INPUTS][NUM_SKID_STAGES + 1](clk, reset_synced);
tagged_i #(data_t, tag_t) duplicator_out[NUM_INPUTS][NUM_OUTPUTS](clk, reset_synced);
tagged_i #(data_t, logic) matched[NUM_INPUTS][NUM_OUTPUTS](clk, reset_synced);
tagged_i #(data_t, logic) mux_in[NUM_OUTPUTS][NUM_INPUTS](clk, reset_synced);

logic[NUM_INPUTS-1:0][NUM_OUTPUTS-1:0] mux_ready_transposed;

for (genvar I = 0; I < NUM_INPUTS; I++) begin : gen_inputs
    assign in[I].ready = skid_pipe[I][0].ready;

    assign skid_pipe[I][0].data  = in[I].data;
    assign skid_pipe[I][0].tag   = in[I].tag;
    assign skid_pipe[I][0].keep  = in[I].keep;
    assign skid_pipe[I][0].last  = in[I].last;
    assign skid_pipe[I][0].valid = in[I].valid;
end

// SkidBuffer pipeline
for (genvar I = 0; I < NUM_INPUTS; I++) begin : gen_skid_pipes
    for (genvar J = 0; J < NUM_SKID_STAGES; J++) begin : gen_stages
        TaggedSkidBuffer #(data_t, tag_t) inst_skid_buffer (
            .clk(clk),
            .rst_n(reset_synced),

            .in(skid_pipe[I][J]),
            .out(skid_pipe[I][J + 1])
        );
    end
end

// Duplicators
for (genvar I = 0; I < NUM_INPUTS; I++) begin : gen_duplicators
    // The copies are buffered after the tag matching below, so the duplicator has no skid buffers
    TaggedDuplicator #(
        .data_t(data_t),
        .tag_t(tag_t),
        .NUM_STREAMS(NUM_OUTPUTS),
        .NUM_SKID_STAGES(0)
    ) inst_duplicator (
        .clk(clk),
        .rst_n(reset_synced),

        .in(skid_pipe[I][NUM_SKID_STAGES]),
        .out(duplicator_out[I])
    );

    for (genvar O = 0; O < NUM_OUTPUTS; O++) begin : gen_tag_matchers
        logic tag_matches;
        assign tag_matches = duplicator_out[I][O].tag == O;

        always_comb begin
            duplicator_out[I][O].ready = 1'b1;

            matched[I][O].data  = duplicator_out[I][O].data;
            matched[I][O].tag   = tag_matches;
            matched[I][O].keep  = duplicator_out[I][O].keep;
            matched[I][O].last  = duplicator_out[I][O].last;
            matched[I][O].valid = 1'b0;

            if ((LAST_HANDLING == 0 && duplicator_out[I][O].last) || tag_matches) begin
                matched[I][O].valid = duplicator_out[I][O].valid;

                if (!matched[I][O].ready) begin
                    duplicator_out[I][O].ready = 1'b0;
                end
            end
        end

        TaggedSkidBuffer #(data_t, logic) inst_skid_buffer (
            .clk(clk),
            .rst_n(reset_synced),

            .in(matched[I][O]),
            .out(mux_in[O][I])
        );
    end
end

for (genvar O = 0; O < NUM_OUTPUTS; O++) begin : gen_outputs
    TaggedMultiplexer #(
        .data_t(data_t),
        .NUM_INPUTS(NUM_INPUTS),
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
