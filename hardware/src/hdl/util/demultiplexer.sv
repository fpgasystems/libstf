`timescale 1ns / 1ps

`include "libstf_macros.svh"

// General de-muxing implementation that is used for AXI and metaIntf streams below.
module Demultiplexer #(
    parameter int N_STREAMS = 2,
    parameter type data_t = logic[63:0],
    // Needs to be defined here because it is needed in the module definition
    // This should NOT be overwritten.
    parameter int N_BITS = $clog2(N_STREAMS)
) (
    input logic clk,
    input logic rst_n,

    input  data_t in_data,
    output logic  in_ready,
    input  logic  in_valid,

    // The index of the stream the input should be assigned to
    input logic [N_BITS - 1: 0] stream_select,

    output data_t out_data [N_STREAMS],
    input  logic  out_ready[N_STREAMS],
    output logic  out_valid[N_STREAMS]
);

`ASSERT_ELAB(N_STREAMS >= 2)
`ASSERT_ELAB(N_BITS == $clog2(N_STREAMS), "N_BITS must not be overwritten")

`RESET_RESYNC // Reset pipelining

// The vector is padded because stream_select can in theory go out of range. An out-of-range select
// then yields in_ready = 0 (well-defined) rather than undefined behavior.
logic[2**N_BITS - 1:0] can_load_padded;

data_t n_out_data [N_STREAMS];
logic  n_out_valid[N_STREAMS];

always_comb begin
    can_load_padded = '0;

    for (int i = 0; i < N_STREAMS; i++) begin
        can_load_padded[i] = ~out_valid[i] | out_ready[i];
    end
end

// Ready-chaining from the correct output stream
assign in_ready = can_load_padded[stream_select];

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        for (int s = 0; s < N_STREAMS; s++) begin
            out_data[s]  <= 'X;
            out_valid[s] <= 1'b0;
        end
    end else begin
        for (int s = 0; s < N_STREAMS; s++) begin
            out_data[s]  <= n_out_data[s];
            out_valid[s] <= n_out_valid[s];
        end
    end
end

always_comb begin
    for (int s = 0; s < N_STREAMS; s++) begin
        n_out_data[s]  = out_data[s];
        n_out_valid[s] = out_valid[s];

        if (in_valid && in_ready && stream_select == s) begin
            n_out_data[s]  = in_data;
            n_out_valid[s] = 1'b1;
        end else if (out_valid[s] && out_ready[s]) begin
            n_out_valid[s] = 1'b0;
        end
    end
end

endmodule

// This module provides a de-mux implementation for the read/write completion
// queue. Both in and out should be metaIntf instances that use the ack_t as their data type.
//
// The de muxing in this module is done based on the data.dest field in the input
// metaIntf. In other words, the output interfaces will get data, based on the
// id of the dest value of the input interface.
module CQDemultiplexer
    import lynxTypes::*;
#(
    parameter int N_STREAMS = 2
) (
    input logic         clk,
    input logic         rst_n,

    // The input interface to demux
    metaIntf.s          in, // #(ack_t)

    // The output stream to assign the data to
    metaIntf.m          out[N_STREAMS] // #(ack_t)
);

`ASSERT_ELAB(N_STREAMS > 0)

generate if (N_STREAMS == 1) begin : gen_single_stream
    `READY_VALID_ASSIGN(in, out[0])
end else begin : gen_demux
    // Intermediate signals for de_mux outputs
    ack_t out_data_packed [N_STREAMS];
    logic out_ready_array [N_STREAMS];
    logic out_valid_array [N_STREAMS];

    // Use the de-muxing implementation from above
    Demultiplexer #(
        .N_STREAMS(N_STREAMS),
        .data_t(ack_t)
    ) inst_de_mux (
        .clk(clk),
        .rst_n(rst_n),

        .in_data(in.data),
        .in_ready(in.ready),
        .in_valid(in.valid),

        // Use the dest field of the data to control the de mux!
        .stream_select(in.data.dest[$clog2(N_STREAMS) - 1:0]),

        .out_data(out_data_packed),
        .out_ready(out_ready_array),
        .out_valid(out_valid_array)
    );

    // Unpack the outputs and connect to cq instances
    for (genvar STREAM = 0; STREAM < N_STREAMS; STREAM++) begin : gen_streams
        assign out[STREAM].data = out_data_packed[STREAM];
        assign out[STREAM].valid = out_valid_array[STREAM];
        assign out_ready_array[STREAM] = out[STREAM].ready;
    end
end endgenerate

endmodule
