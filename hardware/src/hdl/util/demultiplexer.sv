`timescale 1ns / 1ps

`include "libstf_macros.svh"

// General de-muxing implementation that is used for AXI and metaIntf streams below.
module Demultiplexer #(
    parameter integer N_STREAMS = 2,
    parameter type DATA_TYPE = logic[63:0],
    // Needs to be defined here because it is needed in the module definition
    // This should NOT be overwritten.
    parameter integer N_BITS = $clog2(N_STREAMS)
) (
    input logic clk,
    input logic rst_n,

    input  DATA_TYPE i_data,
    output logic     i_ready,
    input  logic     i_valid,

    // The index of the stream the input should be assigned to
    input logic [N_BITS - 1: 0] stream_select,

    output DATA_TYPE o_data [N_STREAMS],
    input  logic     o_ready[N_STREAMS],
    output logic     o_valid[N_STREAMS]
);

`RESET_RESYNC // Reset pipelining

// The vector is padded because stream_select can in theory go out of range. An out-of-range select
// then yields i_ready = 0 (well-defined) rather than undefined behavior.
logic[2**N_BITS - 1:0] can_load_padded;

DATA_TYPE n_o_data [N_STREAMS];
logic     n_o_valid[N_STREAMS];

always_comb begin
    can_load_padded = '0;

    for (int i = 0; i < N_STREAMS; i++) begin
        can_load_padded[i] = ~o_valid[i] | o_ready[i];
    end
end

// Ready-chaining from the correct output stream
assign i_ready = can_load_padded[stream_select];

always_ff @(posedge clk) begin
    if (reset_synced == 1'b0) begin
        for (int s = 0; s < N_STREAMS; s++) begin
            o_valid[s] <= 1'b0;
        end
    end else begin
        for (int s = 0; s < N_STREAMS; s++) begin
            o_data[s]  <= n_o_data[s];
            o_valid[s] <= n_o_valid[s];
        end
    end
end

always_comb begin
    for (int s = 0; s < N_STREAMS; s++) begin
        n_o_data[s]  = o_data[s];
        n_o_valid[s] = o_valid[s];

        if (i_valid && i_ready && stream_select == s) begin
            n_o_data[s]  = i_data;
            n_o_valid[s] = 1'b1;
        end else if (o_valid[s] && o_ready[s]) begin
            n_o_valid[s] = 1'b0;
        end
    end
end

endmodule

// This module provides a de-mux implementation for the read/write completion
// queue. Both data_in, and data_out should be metaIntf instances that
// use the ack_t as their STYPE.
//
// The de muxing in this module is done based on the data.dest field in the input
// metaIntf. In other words, the output interfaces will get data, based on the
// id of the dest value of the input interface.
module CQDemultiplexer #(
    parameter integer N_STREAMS = 2
) (
    input logic         clk,
    input logic         rst_n,

    // The input interface to demux
    metaIntf.s          data_in,

    // The output stream to assign the data to
    metaIntf.m          data_out[N_STREAMS]
);

`ASSERT_ELAB(N_STREAMS > 0)

generate if (N_STREAMS == 1) begin
    `READY_VALID_ASSIGN(data_in, data_out[0])
end else begin : gen_demux
    // Intermediate signals for de_mux outputs
    ack_t o_data_packed [N_STREAMS];
    logic o_ready_array [N_STREAMS];
    logic o_valid_array [N_STREAMS];

    // Use the de-muxing implementation from above
    Demultiplexer #(
        .N_STREAMS(N_STREAMS),
        .DATA_TYPE(ack_t)
    ) inst_de_mux (
        .clk(clk),
        .rst_n(rst_n),

        .i_data(data_in.data),
        .i_ready(data_in.ready),
        .i_valid(data_in.valid),

        // Use the dest field of the data to control the de mux!
        .stream_select(data_in.data.dest[$clog2(N_STREAMS) - 1:0]),

        .o_data(o_data_packed),
        .o_ready(o_ready_array),
        .o_valid(o_valid_array)
    );

    // Unpack the outputs and connect to cq instances
    for (genvar stream = 0; stream < N_STREAMS; stream++) begin
        assign data_out[stream].data = o_data_packed[stream];
        assign data_out[stream].valid = o_valid_array[stream];
        assign o_ready_array[stream] = data_out[stream].ready;
    end
end endgenerate

endmodule
