`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * The Duplicator creates NUM_STREAMS output streams based on one input stream. The ready signal of
 * the input is driven when all output ready signals are high. The valid signals of the output
 * streams are masked with their previous ready signal. The mask is reset when every output stream
 * has acknowledged the element with a ready.
 */
module TaggedDuplicator #(
    parameter type data_t,
    parameter type tag_t,
    parameter int NUM_STREAMS,
    parameter int NUM_SKID_STAGES = 1
) (
    input logic clk,
    input logic rst_n,

    tagged_i.s in,              // #(data_t, tag_t)
    tagged_i.m out[NUM_STREAMS] // #(data_t, tag_t)
);

`RESET_RESYNC // Reset pipelining

`ASSERT_ELAB(type(data_t) == type(in.data_t))
`ASSERT_ELAB(type(tag_t) == type(in.tag_t))

logic[NUM_STREAMS - 1:0] internal_ready;
logic[NUM_STREAMS - 1:0] seen, n_seen;

tagged_i #(data_t, tag_t) internal[NUM_STREAMS][NUM_SKID_STAGES + 1](clk, reset_synced);

assign in.ready = &(seen | internal_ready);

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        seen <= '0;
    end else begin
        seen <= n_seen;
    end
end

always_comb begin
    n_seen = seen;

    if (in.ready) begin
        n_seen = '0;
    end else if (in.valid) begin
        n_seen = seen | internal_ready;
    end
end

for (genvar I = 0; I < NUM_STREAMS; I++) begin : gen_streams
    assign internal_ready[I] = internal[I][0].ready;

    assign internal[I][0].data  = in.data;
    assign internal[I][0].tag   = in.tag;
    assign internal[I][0].keep  = in.keep;
    assign internal[I][0].last  = in.last;
    assign internal[I][0].valid = in.valid && !seen[I];

    for (genvar J = 0; J < NUM_SKID_STAGES; J++) begin : gen_stages
        TaggedSkidBuffer #(data_t, tag_t) inst_skid_buffer (
            .clk(clk),
            .rst_n(reset_synced),

            .in(internal[I][J]),
            .out(internal[I][J + 1])
        );
    end

    assign internal[I][NUM_SKID_STAGES].ready = out[I].ready;

    assign out[I].data  = internal[I][NUM_SKID_STAGES].data;
    assign out[I].tag   = internal[I][NUM_SKID_STAGES].tag;
    assign out[I].keep  = internal[I][NUM_SKID_STAGES].keep;
    assign out[I].last  = internal[I][NUM_SKID_STAGES].last;
    assign out[I].valid = internal[I][NUM_SKID_STAGES].valid;
end

endmodule
