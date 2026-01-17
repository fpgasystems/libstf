`timescale 1ns / 1ps

`include "libstf_macros.svh"

// General de-muxing implementation that is used for AXI and metaInf streams below.
module Demultiplexer #(
    parameter integer N_STREAMS = 2,
    parameter type DATA_TYPE = logic[63:0],
    // Needs to be defined here because it is needed in the module definition
    // This should NOT be overwritten.
    parameter integer N_BITS = $clog2(N_STREAMS)
) (
    input logic         clk,
    input logic         rst_n,

    input DATA_TYPE     i_data,
    output logic        i_ready,
    input logic         i_valid,

    // The index of the stream the input should be assigned to
    input logic [N_BITS - 1: 0] stream_select,

    output DATA_TYPE    o_data [N_STREAMS],
    input logic         o_ready [N_STREAMS],
    output logic        o_valid [N_STREAMS]
);

`RESET_RESYNC // Reset pipelining

// Ready-chaining from the correct output stream
assign i_ready = o_ready[stream_select];

// Assign the input data to the right output stream
generate
    for(genvar out_stream = 0; out_stream < N_STREAMS; out_stream++) begin
        always_ff @(posedge clk) begin
            if (reset_synced == 1'b0) begin
                o_valid[out_stream] <= 0;
            end else if (i_ready & stream_select == out_stream) begin
                if (i_valid) begin
                    o_data[out_stream]   <= i_data;
                    o_valid[out_stream]  <= 1;
                end else begin 
                    o_valid[out_stream]  <= 0;
                end
            end else begin
                if (o_ready[out_stream] & stream_select != out_stream) begin
                    o_valid[out_stream]  <= 0;
                end
            end
        end
    end
endgenerate

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
generate
    for (genvar stream = 0; stream < N_STREAMS; stream++) begin : gen_de_mux_output_connections
        assign data_out[stream].data = o_data_packed[stream];
        assign data_out[stream].valid = o_valid_array[stream];
        assign o_ready_array[stream] = data_out[stream].ready;
    end
endgenerate

endmodule
